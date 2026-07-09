//
//  TSDFShaders.metal
//  ScanEngine / Fusion / Shaders
//
//  KinectFusion 型 TSDF 統合カーネル（1 voxel = 1 thread）。
//  各ボクセルをワールド→カメラへ変換し、深度マップへ投影して符号付き距離を求め、
//  重み付き平均で distance / weight を更新する。Mesh 生成は一切行わない（責務分離）。
//

#include <metal_stdlib>
using namespace metal;

// ボクセル基本構造（将来 color を追加できるよう末尾に余地）。
struct TSDFVoxel {
    float distance;   // 切り詰め符号付き距離（正規化 [-1,1]）
    float weight;     // 観測重み
};

struct TSDFUniforms {
    float4x4 worldToCamera;   // ワールド→カメラ（cameraToWorld の逆）
    int   dimX; int dimY; int dimZ;
    float ox; float oy; float oz;   // ボリューム原点（ワールド, ボクセル(0,0,0)の角）
    float voxelSize;
    float fx; float fy; float cx; float cy;
    uint  depthW; uint depthH;
    float truncation;          // 切り詰め距離 [m]
    float maxWeight;           // 重みクランプ
    float depthMin; float depthMax;
    uint  hasMask;             // validMask が有効か
    uint  hasColor;            // カラー焼き込みが有効か
};

// RGBA8 packed(uint) ↔ float3 のヘルパー（カラー焼き込み用）。
static float3 unpackColor(uint c) {
    return float3(float(c & 0xFFu), float((c >> 8) & 0xFFu), float((c >> 16) & 0xFFu)) / 255.0;
}
static uint packColor(float3 c) {
    c = clamp(c, 0.0, 1.0) * 255.0;
    return uint(c.r) | (uint(c.g) << 8) | (uint(c.b) << 16) | 0xFF000000u;
}

// 符号付き距離: sdf = 計測深度 - ボクセル深度。
//   sdf > 0 : 表面より手前（空き空間）→ +側
//   sdf < 0 : 表面より奥（occlusion）。-truncation より奥は更新しない
// 正規化 tsdf = min(1, sdf/trunc)。重み付き移動平均で統合する。
kernel void tsdfIntegrateKernel(
        device TSDFVoxel*                 voxels   [[buffer(0)]],
        device atomic_uint*               counters [[buffer(1)]],  // [0]=updated(毎フレーム), [1]=activeTotal
        constant TSDFUniforms&            u        [[buffer(2)]],
        device uint*                      colors   [[buffer(3)]],  // RGBA8 packed / voxel
        texture2d<float, access::read>    depthTex [[texture(0)]],
        texture2d<float, access::read>    maskTex  [[texture(1)]],
        texture2d<float, access::sample>  colorTex [[texture(2)]],
        uint3 gid [[thread_position_in_grid]]) {

    if (int(gid.x) >= u.dimX || int(gid.y) >= u.dimY || int(gid.z) >= u.dimZ) return;
    uint idx = (gid.z * uint(u.dimY) + gid.y) * uint(u.dimX) + gid.x;

    // ボクセル中心のワールド座標。
    float3 world = float3(u.ox, u.oy, u.oz) + (float3(gid) + 0.5) * u.voxelSize;

    // カメラ系へ（ARKit: X右 Y上 -Z前）→ CV系へ Y,Z 反転。
    float4 pc = u.worldToCamera * float4(world, 1.0);
    float Xcv = pc.x, Ycv = -pc.y, Zcv = -pc.z;
    if (Zcv <= 0.01) return;   // カメラ背後

    int px = int(round(u.fx * Xcv / Zcv + u.cx));
    int py = int(round(u.fy * Ycv / Zcv + u.cy));
    if (px < 0 || px >= int(u.depthW) || py < 0 || py >= int(u.depthH)) return;

    float dmeas = depthTex.read(uint2(px, py)).r;
    if (!isfinite(dmeas) || dmeas < u.depthMin || dmeas > u.depthMax) return;
    if (u.hasMask != 0 && maskTex.read(uint2(px, py)).r < 0.5) return;

    float sdf = dmeas - Zcv;
    if (sdf < -u.truncation) return;          // occlusion（奥すぎ）
    float tsdf = min(1.0, sdf / u.truncation);

    // 重み付き移動平均。
    TSDFVoxel v = voxels[idx];
    float wOld = v.weight;
    float wNew = min(wOld + 1.0, u.maxWeight);
    voxels[idx].distance = (v.distance * wOld + tsdf) / (wOld + 1.0);
    voxels[idx].weight = wNew;

    // カラー焼き込み: カメラ映像を正規化座標でサンプルし重み付き移動平均。
    if (u.hasColor != 0) {
        constexpr sampler cs(address::clamp_to_edge, filter::linear);
        float2 uv = float2((float(px) + 0.5) / float(u.depthW),
                           (float(py) + 0.5) / float(u.depthH));
        float3 sc = colorTex.sample(cs, uv).rgb;
        float3 blended = (unpackColor(colors[idx]) * wOld + sc) / (wOld + 1.0);
        colors[idx] = packColor(blended);
    }

    atomic_fetch_add_explicit(&counters[0], 1u, memory_order_relaxed);     // updated this frame
    if (wOld == 0.0) {
        atomic_fetch_add_explicit(&counters[1], 1u, memory_order_relaxed); // newly active
    }
}

// MARK: - SDF Smoothing（ボリューム空間。weight 考慮 + 穴埋め + 孤立ノイズ抑制）

struct SDFSmoothUniforms {
    int  dimX; int dimY; int dimZ;
    int  radius;              // 近傍半径
    float amount;            // 自距離→近傍平均ブレンド 0..1
    int  noiseMinNeighbors;  // 観測近傍がこれ未満なら除去
    int  holeFillMinNeighbors; // 観測近傍がこれ以上なら未観測を補完
    float holeFillWeight;    // 穴埋めボクセルに与える重み（MC しきい値以上にする）
};

// weight を重みにした近傍平均。観測の少ない領域では形状を崩しすぎない。
//   観測ボクセル: 近傍平均へブレンド。近傍が少なければ孤立ノイズとして除去。
//   未観測ボクセル: 十分囲まれていれば補完（穴埋め）、そうでなければ未観測のまま。
kernel void sdfSmoothKernel(
        device const TSDFVoxel*    src [[buffer(0)]],
        device TSDFVoxel*          dst [[buffer(1)]],
        constant SDFSmoothUniforms& u  [[buffer(2)]],
        uint3 gid [[thread_position_in_grid]]) {

    if (int(gid.x) >= u.dimX || int(gid.y) >= u.dimY || int(gid.z) >= u.dimZ) return;
    uint idx = (gid.z * uint(u.dimY) + gid.y) * uint(u.dimX) + gid.x;
    TSDFVoxel self = src[idx];

    float sumWD = 0.0, sumW = 0.0;
    int observed = 0;
    int r = u.radius;
    for (int dz = -r; dz <= r; ++dz)
    for (int dy = -r; dy <= r; ++dy)
    for (int dx = -r; dx <= r; ++dx) {
        int nx = int(gid.x) + dx, ny = int(gid.y) + dy, nz = int(gid.z) + dz;
        if (nx < 0 || nx >= u.dimX || ny < 0 || ny >= u.dimY || nz < 0 || nz >= u.dimZ) continue;
        uint nidx = (uint(nz) * uint(u.dimY) + uint(ny)) * uint(u.dimX) + uint(nx);
        TSDFVoxel n = src[nidx];
        if (n.weight > 0.0) { sumWD += n.weight * n.distance; sumW += n.weight; observed++; }
    }

    if (self.weight > 0.0) {
        if (observed < u.noiseMinNeighbors) {   // 孤立ノイズ → 除去
            dst[idx] = TSDFVoxel{ 0.0, 0.0 };
            return;
        }
        float avg = (sumW > 0.0) ? sumWD / sumW : self.distance;
        dst[idx].distance = mix(self.distance, avg, u.amount);
        dst[idx].weight = self.weight;
    } else {
        if (observed >= u.holeFillMinNeighbors && sumW > 0.0) {   // 穴埋め
            dst[idx].distance = sumWD / sumW;
            dst[idx].weight = u.holeFillWeight;   // MC しきい値以上にして表面化させる
        } else {
            dst[idx] = TSDFVoxel{ 0.0, 0.0 };
        }
    }
}

// MARK: - TSDF Slice Visualization（デバッグ表示。Mesh は作らない）

struct TSDFSliceUniforms {
    int  dimX; int dimY; int dimZ;
    int  axis;        // 0:XY(z固定) 1:XZ(y固定) 2:YZ(x固定)
    int  sliceIndex;  // 固定軸のインデックス
    int  mode;        // 1:distance 2:weight 3:occupancy
    float maxWeight;
};

// 簡易カラーマップ（青→水→緑→黄→赤）。
static float3 sliceColormap(float t) {
    t = clamp(t, 0.0, 1.0);
    return float3(clamp(1.5 - abs(4.0 * t - 3.0), 0.0, 1.0),
                  clamp(1.5 - abs(4.0 * t - 2.0), 0.0, 1.0),
                  clamp(1.5 - abs(4.0 * t - 1.0), 0.0, 1.0));
}

// ボリュームの 1 断面を 2D テクスチャへ色付けして書き出す。
kernel void tsdfSliceKernel(
        device const TSDFVoxel*         voxels [[buffer(0)]],
        constant TSDFSliceUniforms&     u      [[buffer(1)]],
        texture2d<float, access::write> outTex [[texture(0)]],
        uint2 gid [[thread_position_in_grid]]) {

    uint ow = outTex.get_width();
    uint oh = outTex.get_height();
    if (gid.x >= ow || gid.y >= oh) return;

    // 出力 (gid) → ボクセル (vx,vy,vz)。
    int vx, vy, vz;
    if (u.axis == 0)      { vx = int(gid.x); vy = int(gid.y); vz = u.sliceIndex; }
    else if (u.axis == 1) { vx = int(gid.x); vy = u.sliceIndex; vz = int(gid.y); }
    else                  { vx = u.sliceIndex; vy = int(gid.x); vz = int(gid.y); }

    if (vx < 0 || vx >= u.dimX || vy < 0 || vy >= u.dimY || vz < 0 || vz >= u.dimZ) {
        outTex.write(float4(0, 0, 0, 1), gid);
        return;
    }

    uint idx = (uint(vz) * uint(u.dimY) + uint(vy)) * uint(u.dimX) + uint(vx);
    TSDFVoxel v = voxels[idx];

    float4 color = float4(0.04, 0.04, 0.05, 1.0);  // 未観測 = 暗色
    if (v.weight > 0.0) {
        if (u.mode == 2) {
            // weight: 0..maxWeight → カラーマップ
            color = float4(sliceColormap(v.weight / max(1.0, u.maxWeight)), 1.0);
        } else if (u.mode == 3) {
            // occupancy: 観測済み = 緑
            color = float4(0.1, 0.9, 0.3, 1.0);
        } else {
            // distance: ゼロ交差(表面)付近を明るく、自由空間(+1)/奥を暗く → 輪郭が線で見える。
            float a = clamp(1.0 - abs(v.distance), 0.0, 1.0);
            a = a * a;   // 表面付近をさらに強調
            float3 c = (v.distance < 0.0) ? float3(0.3, 0.5, 1.0)    // 表面より奥 = 青
                                          : float3(1.0, 0.55, 0.2);  // 手前 = 橙
            color = float4(c * a, 1.0);
        }
    }
    outTex.write(color, gid);
}
