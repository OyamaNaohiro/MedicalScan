//
//  ICP.metal
//  ScanEngine / Tracking / Shaders
//
//  SDF ベースの frame-to-model ICP（KinectFusion 系の直接トラッキング）。
//  VIO 姿勢を初期値に、各深度点をワールドへ投影 → TSDF 距離場(=モデル)からの符号付き距離を
//  残差、勾配を法線として point-to-plane の正規方程式 (A ξ = b) への寄与を点ごとに出力する。
//  CPU 側で総和・6x6 求解・姿勢更新・反復を行う。位置合わせは VIO の微調整に限定。
//

#include <metal_stdlib>
using namespace metal;

struct TSDFVoxelRO { float distance; float weight; };

struct ICPUniforms {
    float4x4 cameraToWorld;   // 候補姿勢 T（VIO 初期 → 反復更新）
    float fx; float fy; float cx; float cy;
    uint depthW; uint depthH;
    uint stride;              // 間引き
    int  dimX; int dimY; int dimZ;
    float ox; float oy; float oz;
    float voxelSize;
    float truncation;
    float minWeight;
    float depthMin; float depthMax;
};

static TSDFVoxelRO fetchVoxel(device const TSDFVoxelRO* v, int x, int y, int z, constant ICPUniforms& u) {
    x = clamp(x, 0, u.dimX - 1); y = clamp(y, 0, u.dimY - 1); z = clamp(z, 0, u.dimZ - 1);
    return v[(uint(z) * uint(u.dimY) + uint(y)) * uint(u.dimX) + uint(x)];
}

// トリリニア距離サンプル。8 角すべてが観測済み(weight>=minWeight)なら valid。
static bool sampleDistance(device const TSDFVoxelRO* v, float3 f, constant ICPUniforms& u, thread float& outDist) {
    int x0 = int(floor(f.x)), y0 = int(floor(f.y)), z0 = int(floor(f.z));
    float tx = f.x - float(x0), ty = f.y - float(y0), tz = f.z - float(z0);
    float d[8];
    int xi[2] = {x0, x0 + 1}, yi[2] = {y0, y0 + 1}, zi[2] = {z0, z0 + 1};
    int n = 0;
    for (int dz = 0; dz < 2; dz++)
    for (int dy = 0; dy < 2; dy++)
    for (int dx = 0; dx < 2; dx++) {
        TSDFVoxelRO vox = fetchVoxel(v, xi[dx], yi[dy], zi[dz], u);
        if (vox.weight < u.minWeight) return false;
        d[n++] = vox.distance;
    }
    // d index order: dz,dy,dx → (dx + 2*dy + 4*dz)
    float c00 = mix(d[0], d[1], tx), c10 = mix(d[2], d[3], tx);
    float c01 = mix(d[4], d[5], tx), c11 = mix(d[6], d[7], tx);
    float c0 = mix(c00, c10, ty), c1 = mix(c01, c11, ty);
    outDist = mix(c0, c1, tz);
    return true;
}

kernel void icpReduceKernel(
        texture2d<float, access::read>  depthTex [[texture(0)]],
        texture2d<float, access::read>  maskTex  [[texture(1)]],
        device const TSDFVoxelRO*       voxels   [[buffer(0)]],
        constant ICPUniforms&           u        [[buffer(1)]],
        device float*                   partial  [[buffer(2)]],  // [thread*39]
        constant uint&                  hasMask  [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]]) {

    uint gw = (u.depthW + u.stride - 1) / u.stride;
    uint gh = (u.depthH + u.stride - 1) / u.stride;
    if (gid.x >= gw || gid.y >= gh) return;
    // 39値: A上三角(21)+b(6)+err(1)+agree(1)+observed(1) + 一致点モーメント[Σp(3)+Σp⊗p上三角(6)]
    uint outBase = (gid.y * gw + gid.x) * 39u;
    for (uint k = 0; k < 39; k++) partial[outBase + k] = 0.0;

    uint px = gid.x * u.stride, py = gid.y * u.stride;
    if (px >= u.depthW || py >= u.depthH) return;

    float dmeas = depthTex.read(uint2(px, py)).r;
    if (!isfinite(dmeas) || dmeas < u.depthMin || dmeas > u.depthMax) return;
    if (hasMask != 0 && maskTex.read(uint2(px, py)).r < 0.5) return;

    // 深度画素 → カメラ(CV) → ARKit カメラ → ワールド。
    float3 pcv = float3((float(px) - u.cx) * dmeas / u.fx,
                        (float(py) - u.cy) * dmeas / u.fy,
                        dmeas);
    float3 pak = float3(pcv.x, -pcv.y, -pcv.z);
    float4 pw4 = u.cameraToWorld * float4(pak, 1.0);
    float3 pw = pw4.xyz;

    // ワールド → ボクセル座標。
    float3 f = (pw - float3(u.ox, u.oy, u.oz)) / u.voxelSize;
    if (f.x < 1 || f.y < 1 || f.z < 1 ||
        f.x > float(u.dimX - 2) || f.y > float(u.dimY - 2) || f.z > float(u.dimZ - 2)) return;

    float distN;
    if (!sampleDistance(voxels, f, u, distN)) return;   // 非観測領域→重なり無し（寄与なし）
    partial[outBase + 29] = 1.0;                        // observed（既存モデルと重なる点）
    if (abs(distN) > 0.6) return;   // 観測済だが表面から遠い＝不一致（agree でない）

    // 勾配（中心差分・最近傍）＝法線方向。
    float gx = fetchVoxel(voxels, int(f.x) + 1, int(f.y), int(f.z), u).distance
             - fetchVoxel(voxels, int(f.x) - 1, int(f.y), int(f.z), u).distance;
    float gy = fetchVoxel(voxels, int(f.x), int(f.y) + 1, int(f.z), u).distance
             - fetchVoxel(voxels, int(f.x), int(f.y) - 1, int(f.z), u).distance;
    float gz = fetchVoxel(voxels, int(f.x), int(f.y), int(f.z) + 1, u).distance
             - fetchVoxel(voxels, int(f.x), int(f.y), int(f.z) - 1, u).distance;
    float3 grad = float3(gx, gy, gz);
    float glen = length(grad);
    if (glen < 1e-6) return;
    float3 nrm = grad / glen;

    float r = distN * u.truncation;             // 点→表面の符号付き距離[m]
    // 外れ値の重み下げ（Geman-McClure 風）。残差が大きい対応ほど寄与を小さく。
    float cc = max(1e-8, u.truncation * 0.4); cc = cc * cc;
    float w = cc / (cc + r * r);

    // point-to-plane ヤコビアン J = [ p×n , n ]（6）。
    float3 pxn = cross(pw, nrm);
    float J[6] = { pxn.x, pxn.y, pxn.z, nrm.x, nrm.y, nrm.z };

    // A 上三角(21) + b(6) + err(1) + count(1)。A,b は重み付き、err は重み無し(RMS 用)。
    uint o = outBase;
    for (int j = 0; j < 6; j++)
        for (int k = j; k < 6; k++)
            partial[o++] = w * J[j] * J[k];
    for (int j = 0; j < 6; j++)
        partial[o++] = -w * J[j] * r;
    partial[o++] = r * r;
    partial[o++] = 1.0;

    // 立体性ゲート用: 一致点(world)の1次・2次モーメント。CPU で共分散→最小固有値を評価し、
    // 平面・直線的な退化領域での誤った再ローカライズ（壁同士の誤接続）を弾く。
    partial[outBase + 30] = pw.x;
    partial[outBase + 31] = pw.y;
    partial[outBase + 32] = pw.z;
    partial[outBase + 33] = pw.x * pw.x;
    partial[outBase + 34] = pw.x * pw.y;
    partial[outBase + 35] = pw.x * pw.z;
    partial[outBase + 36] = pw.y * pw.y;
    partial[outBase + 37] = pw.y * pw.z;
    partial[outBase + 38] = pw.z * pw.z;
}
