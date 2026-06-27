//
//  MarchingCubes.metal
//  ScanEngine / Meshing / Shaders
//
//  TSDF ボリュームのゼロ交差面を Marching Cubes で抽出する（1 cell = 1 thread）。
//  出力は非インデックスの三角形リスト（vertex soup）。法線は面法線。
//  Voxel 更新は一切しない（責務分離: Mesh Generator は Voxel 更新を知らない）。
//

#include <metal_stdlib>
using namespace metal;

struct TSDFVoxel { float distance; float weight; };

struct MCVertex {
    float4 position;  // xyz, w=1
    float4 normal;    // xyz, w=0
};

struct MCUniforms {
    int   dimX; int dimY; int dimZ;
    float ox; float oy; float oz;
    float voxelSize;
    float iso;        // 等値面（0）
    float minWeight;  // この重み未満の角がある cell は無視（未観測境界の偽面を防ぐ）
    uint  maxVerts;   // 出力上限
};

constant int3 kCornerOffset[8] = {
    int3(0,0,0), int3(1,0,0), int3(1,1,0), int3(0,1,0),
    int3(0,0,1), int3(1,0,1), int3(1,1,1), int3(0,1,1)
};
constant int kEdgeA[12] = {0,1,2,3, 4,5,6,7, 0,1,2,3};
constant int kEdgeB[12] = {1,2,3,0, 5,6,7,4, 4,5,6,7};

kernel void marchingCubesKernel(
        device const TSDFVoxel*  voxels   [[buffer(0)]],
        device const int*        triTable [[buffer(1)]],   // [256*16]
        device MCVertex*         outVerts [[buffer(2)]],
        device atomic_uint*      counter  [[buffer(3)]],
        constant MCUniforms&     u        [[buffer(4)]],
        uint3 gid [[thread_position_in_grid]]) {

    if (int(gid.x) >= u.dimX - 1 || int(gid.y) >= u.dimY - 1 || int(gid.z) >= u.dimZ - 1) return;

    // 8 角の距離を読む。未観測角があれば cell ごとスキップ。
    float val[8];
    for (int i = 0; i < 8; i++) {
        int3 c = int3(gid) + kCornerOffset[i];
        uint idx = (uint(c.z) * uint(u.dimY) + uint(c.y)) * uint(u.dimX) + uint(c.x);
        TSDFVoxel v = voxels[idx];
        if (v.weight < u.minWeight) return;
        val[i] = v.distance;
    }

    int cubeIndex = 0;
    for (int i = 0; i < 8; i++) if (val[i] < u.iso) cubeIndex |= (1 << i);
    if (cubeIndex == 0 || cubeIndex == 255) return;

    // 符号が変わる辺で交点を線形補間。
    float3 edge[12];
    for (int e = 0; e < 12; e++) {
        int a = kEdgeA[e], b = kEdgeB[e];
        bool ina = val[a] < u.iso, inb = val[b] < u.iso;
        if (ina != inb) {
            float denom = val[b] - val[a];
            float t = (abs(denom) > 1e-8) ? (u.iso - val[a]) / denom : 0.5;
            float3 pa = float3(u.ox, u.oy, u.oz) + (float3(gid) + float3(kCornerOffset[a])) * u.voxelSize;
            float3 pb = float3(u.ox, u.oy, u.oz) + (float3(gid) + float3(kCornerOffset[b])) * u.voxelSize;
            edge[e] = mix(pa, pb, t);
        }
    }

    // 三角形を出力（atomic で領域確保。上限超過は破棄）。
    for (int i = 0; i < 16; i += 3) {
        int e0 = triTable[cubeIndex * 16 + i];
        if (e0 < 0) break;
        int e1 = triTable[cubeIndex * 16 + i + 1];
        int e2 = triTable[cubeIndex * 16 + i + 2];

        float3 v0 = edge[e0], v1 = edge[e1], v2 = edge[e2];
        float3 n = normalize(cross(v1 - v0, v2 - v0));

        uint base = atomic_fetch_add_explicit(counter, 3u, memory_order_relaxed);
        if (base + 3 > u.maxVerts) return;
        outVerts[base]     = MCVertex{ float4(v0, 1.0), float4(n, 0.0) };
        outVerts[base + 1] = MCVertex{ float4(v1, 1.0), float4(n, 0.0) };
        outVerts[base + 2] = MCVertex{ float4(v2, 1.0), float4(n, 0.0) };
    }
}
