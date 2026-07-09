//
//  TSDFIntegrator.swift
//  ScanEngine / Fusion
//
//  DepthFrame を TSDF ボリュームへ統合する（GPU compute, 1 voxel = 1 thread）。
//  入力は必ず DepthFrame（depthTexture 単体は受け取らない）。
//  Mesh を一切知らない（責務分離: Mesh 生成は Phase 5 の別コンポーネント）。
//

import Metal
import simd

final class TSDFIntegrator {

    // metal の TSDFUniforms とレイアウト一致（先頭に float4x4、以降スカラ）。
    private struct Uniforms {
        var worldToCamera: simd_float4x4
        var dimX: Int32; var dimY: Int32; var dimZ: Int32
        var ox: Float; var oy: Float; var oz: Float
        var voxelSize: Float
        var fx: Float; var fy: Float; var cx: Float; var cy: Float
        var depthW: UInt32; var depthH: UInt32
        var truncation: Float
        var maxWeight: Float
        var depthMin: Float; var depthMax: Float
        var hasMask: UInt32
        var hasColor: UInt32
    }

    /// DepthFrame をボリュームへ統合（与えられた commandBuffer に encode）。
    func integrate(_ frame: DepthFrame,
                   volume: TSDFVolume,
                   config: ScanConfig,
                   commandBuffer: MTLCommandBuffer,
                   context: MetalContext) {
        guard let pso = context.computePipelineState(named: "tsdfIntegrateKernel") else { return }

        // 毎フレームの updated カウンタをリセット（同一 command buffer 内、blit→compute 順序保証）。
        volume.resetUpdatedCounter(commandBuffer: commandBuffer)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        var u = Uniforms(
            worldToCamera: frame.cameraToWorld.inverse,
            dimX: volume.dims.x, dimY: volume.dims.y, dimZ: volume.dims.z,
            ox: volume.origin.x, oy: volume.origin.y, oz: volume.origin.z,
            voxelSize: volume.voxelSize,
            fx: frame.intrinsics.fx, fy: frame.intrinsics.fy,
            cx: frame.intrinsics.cx, cy: frame.intrinsics.cy,
            depthW: UInt32(frame.width), depthH: UInt32(frame.height),
            truncation: config.truncation, maxWeight: config.maxWeight,
            depthMin: config.depthMin, depthMax: config.depthMax,
            hasMask: frame.validMask != nil ? 1 : 0,
            hasColor: frame.color != nil ? 1 : 0)

        encoder.setComputePipelineState(pso)
        encoder.setBuffer(volume.voxelBuffer, offset: 0, index: 0)
        encoder.setBuffer(volume.countersBuffer, offset: 0, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        encoder.setBuffer(volume.colorBuffer, offset: 0, index: 3)
        encoder.setTexture(frame.depth, index: 0)
        encoder.setTexture(frame.validMask ?? frame.depth, index: 1)
        encoder.setTexture(frame.color ?? frame.depth, index: 2)

        // 3D ディスパッチ（1 voxel = 1 thread）。8x8x8 スレッドグループ。
        let tg = MTLSize(width: 8, height: 8, depth: 8)
        let groups = MTLSize(
            width:  (Int(volume.dims.x) + 7) / 8,
            height: (Int(volume.dims.y) + 7) / 8,
            depth:  (Int(volume.dims.z) + 7) / 8)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()
    }
}

/// TSDF 統合の計測値（HUD 用）。
struct TSDFStats {
    var gpuMs: Double = 0
    var updated: UInt32 = 0
    var active: UInt32 = 0
    var total: Int = 0
    var bytes: Int = 0

    var occupancy: Double { total > 0 ? Double(active) / Double(total) : 0 }
    var megabytes: Double { Double(bytes) / (1024 * 1024) }
}
