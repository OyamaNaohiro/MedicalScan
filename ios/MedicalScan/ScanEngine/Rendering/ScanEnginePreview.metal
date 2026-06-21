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
    uint  mode;         // 0:raw 1:validMask 2:filtered
    uint  orientation;  // 0,1,2,3 = 90度回転ステップ
    uint  mirror;       // 0/1 水平反転
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
                                     texture2d<float, access::sample> depthTex [[texture(0)]],
                                     constant PreviewUniforms& u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float2 uv = orientUV(in.uv, u.orientation, u.mirror);
    float d = depthTex.sample(s, uv).r;

    bool valid = isfinite(d) && d >= u.depthMin && d <= u.depthMax;
    float t = (d - u.depthMin) / max(1e-4, (u.depthMax - u.depthMin));

    if (u.mode == 1) {
        // Valid Mask: 有効=緑, 無効=暗色
        return valid ? float4(0.1, 0.9, 0.3, 1.0) : float4(0.08, 0.08, 0.10, 1.0);
    } else if (u.mode == 2) {
        // Filtered: 有効画素のみカラーマップ、無効は黒
        return valid ? float4(colormap(t), 1.0) : float4(0.0, 0.0, 0.0, 1.0);
    } else {
        // Raw: NaN/Inf のみ黒。レンジ外も含めカラーマップ表示
        if (!isfinite(d)) { return float4(0.0, 0.0, 0.0, 1.0); }
        return float4(colormap(t), 1.0);
    }
}
