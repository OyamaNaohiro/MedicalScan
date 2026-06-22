//
//  DepthFilters.metal
//  ScanEngine / Filtering / Shaders
//
//  深度フィルタの compute kernel 群。Phase 3a は ConfidenceFilter のみ。
//  （Bilateral / Temporal は Phase 3b で追加予定）
//

#include <metal_stdlib>
using namespace metal;

// NaN ビットパターン（無効画素の穴を表す）。
inline float nanValue() { return as_type<float>(0x7fc00000u); }

// MARK: - Confidence Filter

struct ConfidenceUniforms {
    float fx; float fy; float cx; float cy;   // 深度解像度に整合した内部パラメータ
    float depthMin; float depthMax;           // 有効レンジ [m]
    float qualityMin;                          // フレーム品質の足切り
    float frameQuality;                        // このフレームの品質 0..1
    float grazingCosMin;                       // |法線・視線| の下限（斜め縁を除外）
};

// 深度画素 (x,y,d) をカメラ座標へ逆投影する。
inline float3 backproject(uint x, uint y, float d, constant ConfidenceUniforms& u) {
    return float3((float(x) - u.cx) * d / u.fx,
                  (float(y) - u.cy) * d / u.fy,
                  d);
}

// TrueDepth の有効性マスクを作る。confidenceMap が無いので
//   finite ∧ レンジ内 ∧ フレーム品質 ∧ 非 grazing
// で判定し、無効画素は深度を NaN（穴）に落とす。
kernel void confidenceFilterKernel(
        texture2d<float, access::read>  inDepth  [[texture(0)]],
        texture2d<float, access::write> outDepth [[texture(1)]],
        texture2d<float, access::write> outMask  [[texture(2)]],
        constant ConfidenceUniforms&    u        [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]) {

    const uint w = inDepth.get_width();
    const uint h = inDepth.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float d = inDepth.read(gid).r;
    bool valid = isfinite(d) && d >= u.depthMin && d <= u.depthMax
                 && u.frameQuality >= u.qualityMin;

    // grazing angle: 隣接画素から法線を推定し、視線とのなす角が浅い縁を除外。
    if (valid && gid.x + 1 < w && gid.y + 1 < h) {
        float dr = inDepth.read(uint2(gid.x + 1, gid.y)).r;
        float dd = inDepth.read(uint2(gid.x, gid.y + 1)).r;
        if (isfinite(dr) && isfinite(dd)) {
            float3 p  = backproject(gid.x,     gid.y,     d,  u);
            float3 pr = backproject(gid.x + 1, gid.y,     dr, u);
            float3 pd = backproject(gid.x,     gid.y + 1, dd, u);
            float3 n  = normalize(cross(pr - p, pd - p));
            float3 view = normalize(-p);             // 表面点→カメラ(原点) 方向
            if (abs(dot(n, view)) < u.grazingCosMin) {
                valid = false;
            }
        }
    }

    outDepth.write(float4(valid ? d : nanValue()), gid);
    outMask.write(float4(valid ? 1.0 : 0.0), gid);
}

// MARK: - Bilateral Filter（エッジ保持平滑化, threadgroup memory タイル）

// 16x16 スレッドグループ + 半径3 のハロ → 22x22 タイルを共有メモリに読み込む。
#define BL_TG   16
#define BL_R    3
#define BL_TILE 22   // BL_TG + 2*BL_R

struct BilateralUniforms {
    int   radius;       // 1..3（kernel 3/5/7）
    float sigmaSpace;   // 空間ガウスの広がり[画素]
    float sigmaDepth;   // 深度ガウスの広がり[m]
};

// out[p] = Σ_q exp(-||p-q||²/2σs²)·exp(-(d_p-d_q)²/2σd²)·d_q / Σ w
// 無効(NaN)画素は重みに含めず、中心が NaN なら穴を維持する。エッジ（深度差大）は
// 深度ガウスが小さくなるため平滑化されず保持される。
kernel void bilateralFilterKernel(
        texture2d<float, access::read>  inDepth  [[texture(0)]],
        texture2d<float, access::write> outDepth [[texture(1)]],
        constant BilateralUniforms&     u        [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]],
        uint2 lid [[thread_position_in_threadgroup]]) {

    const int W = inDepth.get_width();
    const int H = inDepth.get_height();

    threadgroup float tile[BL_TILE][BL_TILE];

    // タイル原点（グローバル座標）= グループ原点 - ハロ。
    int2 origin = int2(gid) - int2(lid) - int2(BL_R, BL_R);
    for (int ty = int(lid.y); ty < BL_TILE; ty += BL_TG) {
        for (int tx = int(lid.x); tx < BL_TILE; tx += BL_TG) {
            int gx = clamp(origin.x + tx, 0, W - 1);
            int gy = clamp(origin.y + ty, 0, H - 1);
            tile[ty][tx] = inDepth.read(uint2(gx, gy)).r;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (int(gid.x) >= W || int(gid.y) >= H) return;

    const int cx = int(lid.x) + BL_R;
    const int cy = int(lid.y) + BL_R;
    float dc = tile[cy][cx];
    if (!isfinite(dc)) { outDepth.write(float4(dc), gid); return; }  // 穴は維持

    const int r = clamp(u.radius, 1, BL_R);
    const float invS = 1.0 / (2.0 * u.sigmaSpace * u.sigmaSpace);
    const float invD = 1.0 / (2.0 * u.sigmaDepth * u.sigmaDepth);

    float sum = 0.0, wsum = 0.0;
    for (int dy = -r; dy <= r; ++dy) {
        for (int dx = -r; dx <= r; ++dx) {
            float dq = tile[cy + dy][cx + dx];
            if (!isfinite(dq)) continue;
            float ws = exp(-float(dx * dx + dy * dy) * invS);
            float dd = dq - dc;
            float wd = exp(-dd * dd * invD);
            float w = ws * wd;
            sum += w * dq;
            wsum += w;
        }
    }
    outDepth.write(float4(wsum > 0.0 ? sum / wsum : dc), gid);
}

// MARK: - Temporal Filter（EMA + 深度差ゲート、α はモーションゲートで CPU 側調整）

struct TemporalUniforms {
    float alpha;       // 実効 EMA 係数（モーションゲート適用後）
    float diffThresh;  // |cur-prev| がこれを超えたら混ぜない[m]（ゴースト防止）
    uint  hasHistory;  // 0:履歴なし（current をそのまま）
};

// out = (|dc-dp|>thr) ? dc : α·dc + (1-α)·dp
kernel void temporalFilterKernel(
        texture2d<float, access::read>  curTex  [[texture(0)]],
        texture2d<float, access::read>  prevTex [[texture(1)]],
        texture2d<float, access::write> outTex  [[texture(2)]],
        constant TemporalUniforms&      u       [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]) {

    const uint W = curTex.get_width();
    const uint H = curTex.get_height();
    if (gid.x >= W || gid.y >= H) return;

    float dc = curTex.read(gid).r;
    if (!isfinite(dc) || u.hasHistory == 0) { outTex.write(float4(dc), gid); return; }

    float dp = prevTex.read(gid).r;
    if (!isfinite(dp)) { outTex.write(float4(dc), gid); return; }

    float out = (abs(dc - dp) > u.diffThresh) ? dc : (u.alpha * dc + (1.0 - u.alpha) * dp);
    outTex.write(float4(out), gid);
}
