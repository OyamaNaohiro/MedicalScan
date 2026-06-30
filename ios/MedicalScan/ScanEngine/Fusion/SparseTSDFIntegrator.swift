//
//  SparseTSDFIntegrator.swift
//  ScanEngine / Fusion
//
//  ブロックスパース TSDF 統合の統括。1 つの command buffer に
//  clear → markBlocks → compactBlocks → writeSparseArgs → sparseIntegrate(indirect)
//  を積む。表面近傍ブロックのみ処理するため密版より大幅に高速。
//  DepthFrame 入力（深度単体は受けない）・Mesh は知らない（責務分離）は密版と同じ。
//

import Metal
import simd

final class SparseTSDFIntegrator {

    // metal SparseUniforms とレイアウト一致。
    private struct Uniforms {
        var worldToCamera: simd_float4x4
        var cameraToWorld: simd_float4x4
        var dimX: Int32; var dimY: Int32; var dimZ: Int32
        var bX: Int32; var bY: Int32; var bZ: Int32
        var ox: Float; var oy: Float; var oz: Float
        var voxelSize: Float
        var fx: Float; var fy: Float; var cx: Float; var cy: Float
        var depthW: UInt32; var depthH: UInt32
        var markStride: UInt32
        var truncation: Float
        var maxWeight: Float
        var depthMin: Float; var depthMax: Float
        var hasMask: UInt32
    }

    private let markStride: UInt32 = 2

    func integrate(_ frame: DepthFrame, volume: TSDFVolume, config: ScanConfig,
                   commandBuffer cb: MTLCommandBuffer, context: MetalContext) {
        guard let markPso = context.computePipelineState(named: "markBlocksKernel"),
              let compactPso = context.computePipelineState(named: "compactBlocksKernel"),
              let argsPso = context.computePipelineState(named: "writeSparseArgsKernel"),
              let integPso = context.computePipelineState(named: "sparseIntegrateKernel") else { return }

        let blockCount = volume.blockCount

        // 0) クリア: blockFlags=0, activeCount=0, updated カウンタ=0（active 合計は保持）。
        if let blit = cb.makeBlitCommandEncoder() {
            blit.fill(buffer: volume.blockFlags, range: 0..<(blockCount * 4), value: 0)
            blit.fill(buffer: volume.activeCountBuffer, range: 0..<4, value: 0)
            blit.fill(buffer: volume.countersBuffer, range: 0..<4, value: 0)
            blit.endEncoding()
        }

        var u = Uniforms(
            worldToCamera: frame.cameraToWorld.inverse,
            cameraToWorld: frame.cameraToWorld,
            dimX: volume.dims.x, dimY: volume.dims.y, dimZ: volume.dims.z,
            bX: volume.blocksDim.x, bY: volume.blocksDim.y, bZ: volume.blocksDim.z,
            ox: volume.origin.x, oy: volume.origin.y, oz: volume.origin.z,
            voxelSize: volume.voxelSize,
            fx: frame.intrinsics.fx, fy: frame.intrinsics.fy,
            cx: frame.intrinsics.cx, cy: frame.intrinsics.cy,
            depthW: UInt32(frame.width), depthH: UInt32(frame.height),
            markStride: markStride,
            truncation: config.truncation, maxWeight: config.maxWeight,
            depthMin: config.depthMin, depthMax: config.depthMax,
            hasMask: frame.validMask != nil ? 1 : 0)
        var blockCountU = UInt32(blockCount)

        // 1) markBlocks（深度を間引いて表面ブロックに印）
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(markPso)
            enc.setTexture(frame.depth, index: 0)
            enc.setTexture(frame.validMask ?? frame.depth, index: 1)
            enc.setBuffer(volume.blockFlags, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            let gw = (frame.width + Int(markStride) - 1) / Int(markStride)
            let gh = (frame.height + Int(markStride) - 1) / Int(markStride)
            let tg = MTLSize(width: 8, height: 8, depth: 1)
            let groups = MTLSize(width: (gw + 7) / 8, height: (gh + 7) / 8, depth: 1)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        // 2) compactBlocks（active ブロック収集）
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(compactPso)
            enc.setBuffer(volume.blockFlags, offset: 0, index: 0)
            enc.setBuffer(volume.activeBlockList, offset: 0, index: 1)
            enc.setBuffer(volume.activeCountBuffer, offset: 0, index: 2)
            enc.setBytes(&blockCountU, length: MemoryLayout<UInt32>.stride, index: 3)
            let w = min(64, max(1, compactPso.maxTotalThreadsPerThreadgroup))
            let tg = MTLSize(width: w, height: 1, depth: 1)
            let groups = MTLSize(width: (blockCount + w - 1) / w, height: 1, depth: 1)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        // 3) writeSparseArgs（indirect 引数）
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(argsPso)
            enc.setBuffer(volume.activeCountBuffer, offset: 0, index: 0)
            enc.setBuffer(volume.indirectArgsBuffer, offset: 0, index: 1)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            enc.endEncoding()
        }

        // 4) sparseIntegrate（active ブロックのみ・indirect dispatch, 1 group = 1 block = 8^3）
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(integPso)
            enc.setBuffer(volume.voxelBuffer, offset: 0, index: 0)
            enc.setBuffer(volume.countersBuffer, offset: 0, index: 1)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
            enc.setBuffer(volume.activeBlockList, offset: 0, index: 3)
            enc.setTexture(frame.depth, index: 0)
            enc.setTexture(frame.validMask ?? frame.depth, index: 1)
            enc.dispatchThreadgroups(indirectBuffer: volume.indirectArgsBuffer,
                                     indirectBufferOffset: 0,
                                     threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 8))
            enc.endEncoding()
        }
    }
}
