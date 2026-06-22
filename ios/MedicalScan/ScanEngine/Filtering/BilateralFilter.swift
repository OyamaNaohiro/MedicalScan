//
//  BilateralFilter.swift
//  ScanEngine / Filtering
//
//  エッジ保持平滑化（bilateral）。threadgroup memory タイルでテクスチャ読み回数を削減する。
//  kernel size（3/5/7 = radius 1/2/3）, sigmaSpace, sigmaDepth を設定可能。
//
//  出力テクスチャは解像度変化時のみ確保して使い回す（毎フレーム生成しない）。
//

import Metal

final class BilateralFilter: DepthFilter {

    let name = "Bilateral"
    var isEnabled = true
    let priority = 20

    /// kernel size: 3/5/7 → radius 1/2/3。
    var radius: Int
    var sigmaSpace: Float
    var sigmaDepth: Float

    // metal の BilateralUniforms と一致（int + float + float）。
    private struct Uniforms {
        var radius: Int32
        var sigmaSpace: Float
        var sigmaDepth: Float
    }

    private static let threadgroupSize = 16  // metal の BL_TG と一致

    private var outDepth: MTLTexture?
    private var allocW = 0
    private var allocH = 0

    init(config: ScanConfig) {
        self.radius = 2
        self.sigmaSpace = config.bilateralSigmaSpace
        self.sigmaDepth = config.bilateralSigmaDepth
    }

    func encode(_ frame: DepthFrame,
                commandBuffer: MTLCommandBuffer,
                context: MetalContext) -> DepthFrame {
        guard let pso = context.computePipelineState(named: "bilateralFilterKernel"),
              ensureOutput(width: frame.width, height: frame.height, device: context.device),
              let outDepth,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return frame
        }

        var u = Uniforms(radius: Int32(radius), sigmaSpace: sigmaSpace, sigmaDepth: sigmaDepth)
        encoder.setComputePipelineState(pso)
        encoder.setTexture(frame.depth, index: 0)
        encoder.setTexture(outDepth, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)

        // threadgroup memory タイルのため固定 16x16 でディスパッチ。
        let tg = MTLSize(width: Self.threadgroupSize, height: Self.threadgroupSize, depth: 1)
        let groups = MTLSize(width: (frame.width + Self.threadgroupSize - 1) / Self.threadgroupSize,
                             height: (frame.height + Self.threadgroupSize - 1) / Self.threadgroupSize,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        var out = frame
        out.depth = outDepth
        out.filterFlags |= FilterFlag.bilateral
        return out
    }

    private func ensureOutput(width: Int, height: Int, device: MTLDevice) -> Bool {
        if outDepth != nil, allocW == width, allocH == height { return true }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let tex = device.makeTexture(descriptor: d) else { return false }
        outDepth = tex
        allocW = width
        allocH = height
        return true
    }
}
