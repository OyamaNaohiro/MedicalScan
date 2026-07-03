//
//  ScanEnginePreview.metal
//  ScanEngine / Rendering
//
//  深度マップをフルスクリーンに可視化するシェーダ。
//  フルスクリーン三角形を vertex_id から生成し、フラグメントで深度をサンプルして
//  表示モード（Raw / ValidMask / Filtered）に応じた色に変換する。
//
//  これが ScanEngine 初の .metal ファイル。これによりターゲットに default.metallib が
//  生成され、MetalContext.library が以降のフェーズ（TSDF/MC の compute kernel）でも使える。
//

#include <metal_stdlib>
using namespace metal;

// MARK: - 頂点段（フルスクリーン三角形）

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// MARK: - Mesh 3D 描画（Marching Cubes 出力を法線シェーディング）

struct MeshVertexIn {
    float4 position;   // MCVertex と一致（xyz, w=1）
    float4 normal;     // xyz, w=0
};

struct MeshVOut {
    float4 position [[position]];
    float3 normal;
};

vertex MeshVOut meshVertex(uint vid [[vertex_id]],
                           device const MeshVertexIn* verts [[buffer(0)]],
                           constant float4x4& mvp [[buffer(1)]]) {
    MeshVOut o;
    o.position = mvp * float4(verts[vid].position.xyz, 1.0);
    o.normal = verts[vid].normal.xyz;
    return o;
}

fragment float4 meshFragment(MeshVOut in [[stage_in]]) {
    float3 n = normalize(in.normal);
    float3 L = normalize(float3(0.4, 0.7, 0.6));
    // 両面ライティング（vertex soup の向き不定に対応）。
    float diff = abs(dot(n, L)) * 0.8 + 0.2;
    return float4(float3(0.70, 0.76, 0.85) * diff, 1.0);
}

// MARK: - カメラ映像（AR オーバーレイ背景）

/// YCbCr(420, biplanar) → BGRA 変換（BT.601 full-range）。Y は全解像度・CbCr は半解像度。
kernel void ycbcrToBGRA(texture2d<float, access::read>  yTex    [[texture(0)]],
                        texture2d<float, access::read>  cbcrTex [[texture(1)]],
                        texture2d<float, access::write> outTex  [[texture(2)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
    float  y    = yTex.read(gid).r;
    float2 cbcr = cbcrTex.read(gid / 2).rg - float2(0.5, 0.5);
    float3 rgb;
    rgb.r = y + 1.402   * cbcr.y;
    rgb.g = y - 0.344136 * cbcr.x - 0.714136 * cbcr.y;
    rgb.b = y + 1.772   * cbcr.x;
    outTex.write(float4(clamp(rgb, 0.0, 1.0), 1.0), gid);
}

struct CameraBGUniforms {
    float3x3 uvTransform;   // displayTransform の逆（view uv → image uv）
};

/// カメラ映像をフルスクリーン背景として表示（displayTransform で向き・アスペクトを補正）。
fragment float4 cameraBGFragment(VertexOut in [[stage_in]],
                                 texture2d<float, access::sample> colorTex [[texture(0)]],
                                 constant CameraBGUniforms& u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    // フルスクリーン頂点の uv は Y 上向き（uv.y=0 が画面下）だが、
    // displayTransform は Y 下向き（画像座標, 原点=左上）前提。Y を反転して整合させる。
    float2 vc = float2(in.uv.x, 1.0 - in.uv.y);
    float3 t = u.uvTransform * float3(vc, 1.0);
    return float4(colorTex.sample(s, t.xy).rgb, 1.0);
}

// TSDF スライス（BGRA8）をそのまま表示するフラグメント。
fragment float4 tsdfSlicePreviewFragment(VertexOut in [[stage_in]],
                                         texture2d<float, access::sample> tex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    return tex.sample(s, float2(in.uv.x, 1.0 - in.uv.y));
}

vertex VertexOut depthPreviewVertex(uint vid [[vertex_id]]) {
    // (0,0) (2,0) (0,2) の三角形で画面全体を覆う。
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = p;                 // 0..1（向きは uniforms で補正）
    return out;
}

// MARK: - フラグメント段

struct PreviewUniforms {
    float depthMin;     // 有効レンジ下限 [m]
    float depthMax;     // 有効レンジ上限 [m]
    uint  mode;         // 0:raw 1:validMask 2:filtered 3:difference
    uint  orientation;  // 0,1,2,3 = 90度回転ステップ
    uint  mirror;       // 0/1 水平反転
    uint  hasFiltered;  // filtered テクスチャが有効か
    uint  hasMask;      // validMask テクスチャが有効か
};

// 深度センサー（横長）→ ポートレート表示のための uv 補正。
static float2 orientUV(float2 uv, uint orientation, uint mirror) {
    float2 r = uv;
    switch (orientation) {
        case 1: r = float2(uv.y, 1.0 - uv.x); break;  // 90° CW
        case 2: r = float2(1.0 - uv.x, 1.0 - uv.y); break;  // 180°
        case 3: r = float2(1.0 - uv.y, uv.x); break;  // 270°
        default: break;
    }
    if (mirror != 0) { r.x = 1.0 - r.x; }
    return r;
}

// 簡易 turbo 風カラーマップ（青→水→緑→黄→赤）。t は 0..1。
static float3 colormap(float t) {
    t = clamp(t, 0.0, 1.0);
    float3 c;
    c.r = clamp(1.5 - abs(4.0 * t - 3.0), 0.0, 1.0);
    c.g = clamp(1.5 - abs(4.0 * t - 2.0), 0.0, 1.0);
    c.b = clamp(1.5 - abs(4.0 * t - 1.0), 0.0, 1.0);
    return c;
}

fragment float4 depthPreviewFragment(VertexOut in [[stage_in]],
                                     texture2d<float, access::sample> rawTex      [[texture(0)]],
                                     texture2d<float, access::sample> filteredTex [[texture(1)]],
                                     texture2d<float, access::sample> maskTex     [[texture(2)]],
                                     constant PreviewUniforms& u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float2 uv = orientUV(in.uv, u.orientation, u.mirror);

    float dr = rawTex.sample(s, uv).r;
    float df = (u.hasFiltered != 0) ? filteredTex.sample(s, uv).r : dr;
    float invRange = 1.0 / max(1e-4, (u.depthMax - u.depthMin));

    if (u.mode == 1) {
        // Valid Mask: validMask があればそれを、無ければレンジ判定を使う
        bool valid = (u.hasMask != 0)
            ? (maskTex.sample(s, uv).r > 0.5)
            : (isfinite(dr) && dr >= u.depthMin && dr <= u.depthMax);
        return valid ? float4(0.1, 0.9, 0.3, 1.0) : float4(0.08, 0.08, 0.10, 1.0);
    } else if (u.mode == 2) {
        // Filtered: 有効画素のみカラーマップ、無効(NaN)は黒
        if (!isfinite(df)) { return float4(0.0, 0.0, 0.0, 1.0); }
        float t = (df - u.depthMin) * invRange;
        return float4(colormap(t), 1.0);
    } else if (u.mode == 3) {
        // Difference: |raw - filtered| を強調表示（mm 単位の差をスケール）
        if (!isfinite(dr) || !isfinite(df)) { return float4(0.0, 0.0, 0.0, 1.0); }
        float diff = fabs(dr - df);
        float t = clamp(diff / 0.01, 0.0, 1.0);   // 0〜10mm を 0..1 に
        return float4(colormap(t), 1.0);
    } else {
        // Raw: NaN/Inf のみ黒。レンジ外も含めカラーマップ表示
        if (!isfinite(dr)) { return float4(0.0, 0.0, 0.0, 1.0); }
        float t = (dr - u.depthMin) * invRange;
        return float4(colormap(t), 1.0);
    }
}
