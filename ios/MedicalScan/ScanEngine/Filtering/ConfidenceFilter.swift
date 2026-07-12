//
//  ConfidenceFilter.swift
//  ScanEngine / Filtering
//
//  TrueDepth の有効性マスクを生成するフィルタ（confidenceMap の代替）。
//  finite ∧ レンジ ∧ frameQuality ∧ 非grazing で valid を判定し、
//  無効画素の深度を NaN（穴）に落とし、validMask（r8）を生成する。
//
//  出力テクスチャは「解像度が変わったときだけ」確保して使い回す（毎フレーム生成しない）。
//

import Metal

final class ConfidenceFilter: DepthFilter {

    let name = "Confidence"
    var isEnabled = true
    let priority = 10

    /// しきい値類（ScanEngine と共有）。
    var config: ScanConfig

    // metal の ConfidenceUniforms とレイアウト一致。
    private struct Uniforms {
        var fx: Float; var fy: Float; var cx: Float; var cy: Float
        var depthMin: Float; var depthMax: Float
        var qualityMin: Float; var frameQuality: Float; var grazingCosMin: Float
        var confidenceMin: Float; var hasConfidence: UInt32
    }

    // 使い回す出力テクスチャ（解像度変化時のみ再確保）。
    private var outDepth: MTLTexture?
    private var outMask: MTLTexture?
    private var allocW = 0
    private var allocH = 0

    init(config: ScanConfig) { self.config = config }

    /// モード切替で depthMin/Max 等が変わったら反映する。
    func updateConfig(_ config: ScanConfig) { self.config = config }

    func encode(_ frame: DepthFrame,
                commandBuffer: MTLCommandBuffer,
                context: MetalContext) -> DepthFrame {
        guard let pso = context.computePipelineState(named: "confidenceFilterKernel"),
              ensureOutputs(width: frame.width, height: frame.height, device: context.device),
              let outDepth, let outMask,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return frame
        }

        var u = Uniforms(fx: frame.intrinsics.fx, fy: frame.intrinsics.fy,
                         cx: frame.intrinsics.cx, cy: frame.intrinsics.cy,
                         depthMin: config.depthMin, depthMax: config.depthMax,
                         qualityMin: config.qualityMin, frameQuality: frame.quality,
                         grazingCosMin: config.grazingCosMin,
                         confidenceMin: config.confidenceMin,
                         hasConfidence: frame.confidence != nil ? 1 : 0)

        encoder.setComputePipelineState(pso)
        encoder.setTexture(frame.depth, index: 0)
        encoder.setTexture(outDepth, index: 1)
        encoder.setTexture(outMask, index: 2)
        encoder.setTexture(frame.confidence ?? frame.depth, index: 3)  // 無い時はダミー(hasConfidence=0で無視)
        encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        let (groups, tpg) = context.threadgroup2D(for: pso, width: frame.width, height: frame.height)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tpg)
        encoder.endEncoding()

        var out = frame
        out.depth = outDepth
        out.validMask = outMask
        out.filterFlags |= FilterFlag.confidence
        return out
    }

    /// 解像度に合わせて出力テクスチャを用意（変化時のみ確保）。
    private func ensureOutputs(width: Int, height: Int, device: MTLDevice) -> Bool {
        if outDepth != nil, allocW == width, allocH == height { return true }

        func make(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let depth = make(.r32Float), let mask = make(.r8Unorm) else { return false }
        outDepth = depth
        outMask = mask
        allocW = width
        allocH = height
        return true
    }
}

/// 適用済みフィルタのビットフラグ（DepthFrame.filterFlags 用）。
struct FilterFlag {
    static let confidence: UInt32 = 1 << 0
    static let bilateral: UInt32  = 1 << 1
    static let temporal: UInt32   = 1 << 2
}
