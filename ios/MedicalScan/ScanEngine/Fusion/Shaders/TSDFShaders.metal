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
};

// 符号付き距離: sdf = 計測深度 - ボクセル深度。
//   sdf > 0 : 表面より手前（空き空間）→ +側
//   sdf < 0 : 表面より奥（occlusion）。-truncation より奥は更新しない
// 正規化 tsdf = min(1, sdf/trunc)。重み付き移動平均で統合する。
kernel void tsdfIntegrateKernel(
        device TSDFVoxel*               voxels   [[buffer(0)]],
        device atomic_uint*             counters [[buffer(1)]],  // [0]=updated(毎フレーム), [1]=activeTotal
        constant TSDFUniforms&          u        [[buffer(2)]],
        texture2d<float, access::read>  depthTex [[texture(0)]],
        texture2d<float, access::read>  maskTex  [[texture(1)]],
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

    atomic_fetch_add_explicit(&counters[0], 1u, memory_order_relaxed);     // updated this frame
    if (wOld == 0.0) {
        atomic_fetch_add_explicit(&counters[1], 1u, memory_order_relaxed); // newly active
    }
}
