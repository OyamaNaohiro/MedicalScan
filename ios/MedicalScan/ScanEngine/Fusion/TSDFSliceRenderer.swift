//
//  TSDFSliceRenderer.swift
//  ScanEngine / Fusion
//
//  TSDF ボリュームの 1 断面を 2D テクスチャへ色付けするデバッグ用レンダラ。
//  Mesh は作らない（責務分離）。出力テクスチャは軸サイズ変化時のみ確保して使い回す。
//

import Metal

final class TSDFSliceRenderer {

    enum Axis: Int { case xy = 0, xz = 1, yz = 2 }
    enum Mode: Int { case distance = 1, weight = 2, occupancy = 3 }

    private struct Uniforms {
        var dimX: Int32; var dimY: Int32; var dimZ: Int32
        var axis: Int32
        var sliceIndex: Int32
        var mode: Int32
        var maxWeight: Float
    }

    private var outTexture: MTLTexture?
    private var texW = 0
    private var texH = 0

    /// 軸ごとの出力テクスチャ平面サイズ。
    private func planeSize(axis: Axis, dims: SIMD3<Int32>) -> (Int, Int) {
        switch axis {
        case .xy: return (Int(dims.x), Int(dims.y))
        case .xz: return (Int(dims.x), Int(dims.z))
        case .yz: return (Int(dims.y), Int(dims.z))
        }
    }

    /// 断面を描画して出力テクスチャを返す（commandBuffer に encode）。
    /// - Parameter slice: 0..1 の正規化スライス位置。
    func encode(volume: TSDFVolume, mode: Mode, axis: Axis, slice: Float,
                commandBuffer: MTLCommandBuffer, context: MetalContext) -> MTLTexture? {
        guard let pso = context.computePipelineState(named: "tsdfSliceKernel") else { return nil }

        let (w, h) = planeSize(axis: axis, dims: volume.dims)
        guard ensureOutput(width: w, height: h, device: context.device),
              let outTexture,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        // 固定軸のインデックス。
        let axisDim: Int32 = (axis == .xy) ? volume.dims.z
                            : (axis == .xz) ? volume.dims.y : volume.dims.x
        let sliceIndex = Int32((slice * Float(max(1, axisDim - 1))).rounded())

        var u = Uniforms(dimX: volume.dims.x, dimY: volume.dims.y, dimZ: volume.dims.z,
                         axis: Int32(axis.rawValue), sliceIndex: sliceIndex,
                         mode: Int32(mode.rawValue), maxWeight: 64)

        encoder.setComputePipelineState(pso)
        encoder.setBuffer(volume.voxelBuffer, offset: 0, index: 0)
        encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setTexture(outTexture, index: 0)
        let (groups, tpg) = context.threadgroup2D(for: pso, width: w, height: h)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tpg)
        encoder.endEncoding()
        return outTexture
    }

    private func ensureOutput(width: Int, height: Int, device: MTLDevice) -> Bool {
        if outTexture != nil, texW == width, texH == height { return true }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let tex = device.makeTexture(descriptor: d) else { return false }
        outTexture = tex
        texW = width
        texH = height
        return true
    }
}
