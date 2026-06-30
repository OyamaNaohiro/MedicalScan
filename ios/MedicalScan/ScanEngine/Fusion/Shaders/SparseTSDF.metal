//
//  SparseTSDF.metal
//  ScanEngine / Fusion / Shaders
//
//  ブロックスパース TSDF 統合。毎フレーム全ボクセルを走査する密版に対し、
//  深度の当たった表面近傍ブロックだけを統合する（速度最適化）。
//
//  パイプライン: markBlocks（表面ブロックに印）→ compactBlocks（active ブロック収集）
//   → writeSparseArgs（indirect dispatch 引数）→ sparseIntegrate（active ブロックのみ統合）。
//  ボリュームは有界なのでハッシュ表は使わず、ブロック数ぶんの密フラグ配列で管理する。
//  表面の ±truncation シェルのみ更新（遠方の自由空間カービングは省略：静的対象では十分）。
//

#include <metal_stdlib>
using namespace metal;

constant int kBlock = 8;   // 1 ブロック = 8^3 ボクセル

struct TSDFVoxelS { float distance; float weight; };

struct SparseUniforms {
    float4x4 worldToCamera;   // 統合用（voxel world → camera）
    float4x4 cameraToWorld;   // マーク用（depth → world）
    int dimX; int dimY; int dimZ;
    int bX; int bY; int bZ;   // 各軸のブロック数
    float ox; float oy; float oz;
    float voxelSize;
    float fx; float fy; float cx; float cy;
    uint depthW; uint depthH;
    uint markStride;
    float truncation;
    float maxWeight;
    float depthMin; float depthMax;
    uint hasMask;
};

// MARK: - 1) 表面ブロックに印（自ブロック＋6面隣接で truncation 帯を覆う）
kernel void markBlocksKernel(
        texture2d<float, access::read> depthTex [[texture(0)]],
        texture2d<float, access::read> maskTex  [[texture(1)]],
        device uint*                   blockFlags [[buffer(0)]],
        constant SparseUniforms&       u        [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]) {

    uint gw = (u.depthW + u.markStride - 1) / u.markStride;
    uint gh = (u.depthH + u.markStride - 1) / u.markStride;
    if (gid.x >= gw || gid.y >= gh) return;
    uint px = gid.x * u.markStride, py = gid.y * u.markStride;
    if (px >= u.depthW || py >= u.depthH) return;

    float d = depthTex.read(uint2(px, py)).r;
    if (!isfinite(d) || d < u.depthMin || d > u.depthMax) return;
    if (u.hasMask != 0 && maskTex.read(uint2(px, py)).r < 0.5) return;

    float3 pcv = float3((float(px) - u.cx) * d / u.fx, (float(py) - u.cy) * d / u.fy, d);
    float3 pak = float3(pcv.x, -pcv.y, -pcv.z);
    float3 pw = (u.cameraToWorld * float4(pak, 1.0)).xyz;
    float3 f = (pw - float3(u.ox, u.oy, u.oz)) / u.voxelSize;
    int vx = int(floor(f.x)), vy = int(floor(f.y)), vz = int(floor(f.z));
    if (vx < 0 || vx >= u.dimX || vy < 0 || vy >= u.dimY || vz < 0 || vz >= u.dimZ) return;

    int bx = vx / kBlock, by = vy / kBlock, bz = vz / kBlock;
    // 3x3x3 の全 1 リングをマーク（truncation 帯が斜めのブロックへ及ぶ取りこぼしを防ぐ）。
    for (int dz = -1; dz <= 1; dz++)
    for (int dy = -1; dy <= 1; dy++)
    for (int dx = -1; dx <= 1; dx++) {
        int nx = bx + dx, ny = by + dy, nz = bz + dz;
        if (nx < 0 || nx >= u.bX || ny < 0 || ny >= u.bY || nz < 0 || nz >= u.bZ) continue;
        blockFlags[(uint(nz) * uint(u.bY) + uint(ny)) * uint(u.bX) + uint(nx)] = 1;
    }
}

// MARK: - 2) active ブロックを収集
kernel void compactBlocksKernel(
        device const uint*   blockFlags  [[buffer(0)]],
        device uint*         activeList  [[buffer(1)]],
        device atomic_uint*  activeCount [[buffer(2)]],
        constant uint&       blockCount  [[buffer(3)]],
        uint gid [[thread_position_in_grid]]) {
    if (gid >= blockCount) return;
    if (blockFlags[gid] != 0) {
        uint idx = atomic_fetch_add_explicit(activeCount, 1u, memory_order_relaxed);
        activeList[idx] = gid;   // capacity == blockCount なので安全
    }
}

// MARK: - 3) indirect dispatch 引数を書く（threadgroups = activeCount,1,1）
kernel void writeSparseArgsKernel(
        device const uint* activeCount [[buffer(0)]],
        device uint*       args        [[buffer(1)]],
        uint gid [[thread_position_in_grid]]) {
    if (gid != 0) return;
    args[0] = activeCount[0];
    args[1] = 1;
    args[2] = 1;
}

// MARK: - 4) active ブロックのみ統合（1 threadgroup = 1 ブロック = 8^3）
kernel void sparseIntegrateKernel(
        device TSDFVoxelS*             voxels   [[buffer(0)]],
        device atomic_uint*            counters [[buffer(1)]],
        constant SparseUniforms&       u        [[buffer(2)]],
        device const uint*             activeList [[buffer(3)]],
        texture2d<float, access::read> depthTex [[texture(0)]],
        texture2d<float, access::read> maskTex  [[texture(1)]],
        uint3 blockTG [[threadgroup_position_in_grid]],
        uint3 lid     [[thread_position_in_threadgroup]]) {

    uint blockId = activeList[blockTG.x];
    int bx = int(blockId % uint(u.bX));
    int by = int((blockId / uint(u.bX)) % uint(u.bY));
    int bz = int(blockId / (uint(u.bX) * uint(u.bY)));
    int vx = bx * kBlock + int(lid.x);
    int vy = by * kBlock + int(lid.y);
    int vz = bz * kBlock + int(lid.z);
    if (vx >= u.dimX || vy >= u.dimY || vz >= u.dimZ) return;
    uint idx = (uint(vz) * uint(u.dimY) + uint(vy)) * uint(u.dimX) + uint(vx);

    float3 world = float3(u.ox, u.oy, u.oz) + (float3(vx, vy, vz) + 0.5) * u.voxelSize;
    float4 pc = u.worldToCamera * float4(world, 1.0);
    float Xcv = pc.x, Ycv = -pc.y, Zcv = -pc.z;
    if (Zcv <= 0.01) return;
    int px = int(round(u.fx * Xcv / Zcv + u.cx));
    int py = int(round(u.fy * Ycv / Zcv + u.cy));
    if (px < 0 || px >= int(u.depthW) || py < 0 || py >= int(u.depthH)) return;

    float dmeas = depthTex.read(uint2(px, py)).r;
    if (!isfinite(dmeas) || dmeas < u.depthMin || dmeas > u.depthMax) return;
    if (u.hasMask != 0 && maskTex.read(uint2(px, py)).r < 0.5) return;

    float sdf = dmeas - Zcv;
    if (sdf < -u.truncation || sdf > u.truncation) return;   // シェルのみ
    float tsdf = sdf / u.truncation;                          // [-1,1]

    TSDFVoxelS v = voxels[idx];
    float wOld = v.weight;
    float wNew = min(wOld + 1.0, u.maxWeight);
    voxels[idx].distance = (v.distance * wOld + tsdf) / (wOld + 1.0);
    voxels[idx].weight = wNew;

    atomic_fetch_add_explicit(&counters[0], 1u, memory_order_relaxed);
    if (wOld == 0.0) atomic_fetch_add_explicit(&counters[1], 1u, memory_order_relaxed);
}
