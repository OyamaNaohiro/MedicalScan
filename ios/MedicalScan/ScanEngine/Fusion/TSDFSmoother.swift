//
//  TSDFSmoother.swift
//  ScanEngine / Fusion
//
//  ボリューム空間で TSDF 距離場を平滑化する（リアルタイム品質優先）。
//  マスターボリュームは破壊せず、別バッファに平滑化結果を書き出して MC へ渡す
//  （蓄積パイプラインと平滑化を分離）。weight 考慮・穴埋め・孤立ノイズ抑制を含む。
//

import Metal

final class TSDFSmoother {

    private struct Uniforms {
        var dimX: Int32; var dimY: Int32; var dimZ: Int32
        var radius: Int32
        var amount: Float
        var noiseMinNeighbors: Int32
        var holeFillMinNeighbors: Int32
    }

    // ping-pong バッファ（iterations>1 のときのみ 2 枚使う）。
    private var bufA: MTLBuffer?
    private var bufB: MTLBuffer?
    private var allocBytes = 0

    /// 平滑化を実行し、MC が読む最終バッファ（TSDFVoxel レイアウト）を返す。
    func smooth(volume: TSDFVolume, config: ScanConfig,
                commandBuffer: MTLCommandBuffer, context: MetalContext) -> MTLBuffer? {
        let iterations = max(1, config.sdfSmoothIterations)
        guard let pso = context.computePipelineState(named: "sdfSmoothKernel"),
              ensureBuffers(byteCount: volume.byteCount, needTwo: iterations > 1,
                            device: context.device),
              let bufA else { return nil }

        var u = Uniforms(dimX: volume.dims.x, dimY: volume.dims.y, dimZ: volume.dims.z,
                         radius: Int32(max(1, config.sdfSmoothRadius)),
                         amount: config.sdfSmoothAmount,
                         noiseMinNeighbors: Int32(config.sdfNoiseMinNeighbors),
                         holeFillMinNeighbors: Int32(config.sdfHoleFillMinNeighbors))

        let (groups, tpg) = dispatchSize(for: pso, dims: volume.dims, context: context)

        var src = volume.voxelBuffer
        var dst = bufA
        for i in 0..<iterations {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(pso)
            encoder.setBuffer(src, offset: 0, index: 0)
            encoder.setBuffer(dst, offset: 0, index: 1)
            encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tpg)
            encoder.endEncoding()

            if i < iterations - 1 {
                src = dst
                dst = (dst === bufA) ? (bufB ?? bufA) : bufA
            }
        }
        return dst
    }

    private func dispatchSize(for pso: MTLComputePipelineState, dims: SIMD3<Int32>,
                              context: MetalContext) -> (MTLSize, MTLSize) {
        let tg = MTLSize(width: 4, height: 4, depth: 4)
        let groups = MTLSize(width: (Int(dims.x) + 3) / 4,
                             height: (Int(dims.y) + 3) / 4,
                             depth: (Int(dims.z) + 3) / 4)
        return (groups, tg)
    }

    private func ensureBuffers(byteCount: Int, needTwo: Bool, device: MTLDevice) -> Bool {
        if bufA != nil, allocBytes == byteCount, (!needTwo || bufB != nil) { return true }
        guard let a = device.makeBuffer(length: byteCount, options: .storageModePrivate) else {
            return false
        }
        bufA = a
        a.label = "TSDF.smoothA"
        if needTwo {
            guard let b = device.makeBuffer(length: byteCount, options: .storageModePrivate) else {
                return false
            }
            bufB = b
            b.label = "TSDF.smoothB"
        }
        allocBytes = byteCount
        return true
    }
}
