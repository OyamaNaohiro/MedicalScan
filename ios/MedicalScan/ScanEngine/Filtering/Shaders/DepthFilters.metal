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
