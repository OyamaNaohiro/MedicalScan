//
//  MarchingCubes.metal
//  ScanEngine / Meshing / Shaders
//
//  TSDF ボリュームのゼロ交差面を Marching Cubes で抽出する（1 cell = 1 thread）。
//  出力は非インデックスの三角形リスト（vertex soup）。
//  法線は SDF 勾配（スムースシェーディング）。バウンディングボックスも同時に求める。
//  Voxel 更新は一切しない（責務分離: Mesh Generator は Voxel 更新を知らない）。
//

#include <metal_stdlib>
using namespace metal;

struct TSDFVoxel { float distance; float weight; };

struct MCVertex {
    float4 position;  // xyz, w=1
    float4 normal;    // xyz, w=0
    float4 color;     // rgb, a=1(色あり)/0(色なし→グレー表示)
};

struct MCUniforms {
    int   dimX; int dimY; int dimZ;
    float ox; float oy; float oz;
    float voxelSize;
    float iso;
    float minWeight;
    uint  maxVerts;
    uint  hasColor;   // カラー焼き込みが有効か
};

constant int3 kCornerOffset[8] = {
    int3(0,0,0), int3(1,0,0), int3(1,1,0), int3(0,1,0),
    int3(0,0,1), int3(1,0,1), int3(1,1,1), int3(0,1,1)
};
constant int kEdgeA[12] = {0,1,2,3, 4,5,6,7, 0,1,2,3};
constant int kEdgeB[12] = {1,2,3,0, 5,6,7,4, 4,5,6,7};

// 距離をクランプ付きで読む（勾配の中心差分用）。
static float sdfAt(device const TSDFVoxel* v, int x, int y, int z, constant MCUniforms& u) {
    x = clamp(x, 0, u.dimX - 1);
    y = clamp(y, 0, u.dimY - 1);
    z = clamp(z, 0, u.dimZ - 1);
    return v[(uint(z) * uint(u.dimY) + uint(y)) * uint(u.dimX) + uint(x)].distance;
}

// SDF 勾配（中心差分）＝表面法線方向。
static float3 gradAt(device const TSDFVoxel* v, int3 c, constant MCUniforms& u) {
    return float3(sdfAt(v, c.x + 1, c.y, c.z, u) - sdfAt(v, c.x - 1, c.y, c.z, u),
                  sdfAt(v, c.x, c.y + 1, c.z, u) - sdfAt(v, c.x, c.y - 1, c.z, u),
                  sdfAt(v, c.x, c.y, c.z + 1, u) - sdfAt(v, c.x, c.y, c.z - 1, u));
}

// ボクセルカラー（RGBA8 packed）を float3 で読む。
static float3 colorAt(device const uint* colors, int3 c, constant MCUniforms& u) {
    int x = clamp(c.x, 0, u.dimX - 1);
    int y = clamp(c.y, 0, u.dimY - 1);
    int z = clamp(c.z, 0, u.dimZ - 1);
    uint packed = colors[(uint(z) * uint(u.dimY) + uint(y)) * uint(u.dimX) + uint(x)];
    return float3(float(packed & 0xFFu), float((packed >> 8) & 0xFFu),
                  float((packed >> 16) & 0xFFu)) / 255.0;
}

// float を順序保存 uint へ（atomic min/max でバウンディング計算）。
static uint floatFlip(float f) {
    uint u = as_type<uint>(f);
    uint mask = uint(-int(u >> 31)) | 0x80000000u;
    return u ^ mask;
}
static void updateBounds(device atomic_uint* b, float3 p) {
    atomic_fetch_min_explicit(&b[0], floatFlip(p.x), memory_order_relaxed);
    atomic_fetch_min_explicit(&b[1], floatFlip(p.y), memory_order_relaxed);
    atomic_fetch_min_explicit(&b[2], floatFlip(p.z), memory_order_relaxed);
    atomic_fetch_max_explicit(&b[3], floatFlip(p.x), memory_order_relaxed);
    atomic_fetch_max_explicit(&b[4], floatFlip(p.y), memory_order_relaxed);
    atomic_fetch_max_explicit(&b[5], floatFlip(p.z), memory_order_relaxed);
}

kernel void marchingCubesKernel(
        device const TSDFVoxel*  voxels   [[buffer(0)]],
        device const int*        triTable [[buffer(1)]],
        device MCVertex*         outVerts [[buffer(2)]],
        device atomic_uint*      counter  [[buffer(3)]],
        constant MCUniforms&     u        [[buffer(4)]],
        device atomic_uint*      bounds   [[buffer(5)]],
        device const uint*       colors   [[buffer(6)]],
        uint3 gid [[thread_position_in_grid]]) {

    if (int(gid.x) >= u.dimX - 1 || int(gid.y) >= u.dimY - 1 || int(gid.z) >= u.dimZ - 1) return;

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

    // 8 角の勾配（法線）。
    float3 grad[8];
    for (int i = 0; i < 8; i++) grad[i] = gradAt(voxels, int3(gid) + kCornerOffset[i], u);

    // 8 角のカラー（焼き込み有効時のみ）。
    float3 col[8];
    if (u.hasColor != 0)
        for (int i = 0; i < 8; i++) col[i] = colorAt(colors, int3(gid) + kCornerOffset[i], u);

    float3 edgePos[12];
    float3 edgeNrm[12];
    float3 edgeCol[12];
    for (int e = 0; e < 12; e++) {
        int a = kEdgeA[e], b = kEdgeB[e];
        bool ina = val[a] < u.iso, inb = val[b] < u.iso;
        if (ina != inb) {
            float denom = val[b] - val[a];
            float t = (abs(denom) > 1e-8) ? (u.iso - val[a]) / denom : 0.5;
            float3 pa = float3(u.ox, u.oy, u.oz) + (float3(gid) + float3(kCornerOffset[a])) * u.voxelSize;
            float3 pb = float3(u.ox, u.oy, u.oz) + (float3(gid) + float3(kCornerOffset[b])) * u.voxelSize;
            edgePos[e] = mix(pa, pb, t);
            edgeNrm[e] = mix(grad[a], grad[b], t);
            if (u.hasColor != 0) edgeCol[e] = mix(col[a], col[b], t);
        }
    }

    for (int i = 0; i < 16; i += 3) {
        int e0 = triTable[cubeIndex * 16 + i];
        if (e0 < 0) break;
        int e1 = triTable[cubeIndex * 16 + i + 1];
        int e2 = triTable[cubeIndex * 16 + i + 2];

        float3 v0 = edgePos[e0], v1 = edgePos[e1], v2 = edgePos[e2];
        float3 faceN = normalize(cross(v1 - v0, v2 - v0));

        // SDF 勾配の頂点法線（縮退時は面法線）。
        float3 n0 = (length(edgeNrm[e0]) > 1e-6) ? normalize(edgeNrm[e0]) : faceN;
        float3 n1 = (length(edgeNrm[e1]) > 1e-6) ? normalize(edgeNrm[e1]) : faceN;
        float3 n2 = (length(edgeNrm[e2]) > 1e-6) ? normalize(edgeNrm[e2]) : faceN;

        // 頂点カラー（焼き込み有効時は a=1、無効時は a=0＝レンダラでグレー表示）。
        float4 c0 = (u.hasColor != 0) ? float4(edgeCol[e0], 1.0) : float4(0.0);
        float4 c1 = (u.hasColor != 0) ? float4(edgeCol[e1], 1.0) : float4(0.0);
        float4 c2 = (u.hasColor != 0) ? float4(edgeCol[e2], 1.0) : float4(0.0);

        uint base = atomic_fetch_add_explicit(counter, 3u, memory_order_relaxed);
        if (base + 3 > u.maxVerts) return;
        // 巻き順を反転（v0, v2, v1）して面法線を外向きにする（STL の表裏を正す）。
        outVerts[base]     = MCVertex{ float4(v0, 1.0), float4(n0, 0.0), c0 };
        outVerts[base + 1] = MCVertex{ float4(v2, 1.0), float4(n2, 0.0), c2 };
        outVerts[base + 2] = MCVertex{ float4(v1, 1.0), float4(n1, 0.0), c1 };

        updateBounds(bounds, v0);
        updateBounds(bounds, v1);
        updateBounds(bounds, v2);
    }
}
