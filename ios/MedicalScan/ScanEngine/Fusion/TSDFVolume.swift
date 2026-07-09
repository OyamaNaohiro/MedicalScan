//
//  TSDFVolume.swift
//  ScanEngine / Fusion
//
//  GPU 上に保持する TSDF ボクセルボリューム。CPU へ毎フレームコピーしない。
//  voxelSize と extent から異方性 dims を逆算する（対象 ~1m / 128MB 上限に収まる解像度）。
//
//  責務: ボクセルメモリの保持・初期化・配置・カウンタ読み出しのみ。
//  統合ロジック（distance/weight 更新）は TSDFIntegrator が担当する。
//

import Metal
import simd

final class TSDFVolume {

    /// 1 ボクセルのバイト数（distance + weight）。将来 color 追加時はここを更新。
    static let voxelStride = 8

    let dims: SIMD3<Int32>
    let voxelSize: Float
    /// ボリューム全体のワールドサイズ [m]。
    var extent: SIMD3<Float> {
        SIMD3(Float(dims.x), Float(dims.y), Float(dims.z)) * voxelSize
    }

    private(set) var origin = SIMD3<Float>(repeating: 0)   // voxel(0,0,0) の角（ワールド）
    private(set) var isPositioned = false

    /// distance/weight を保持する GPU バッファ（private）。
    let voxelBuffer: MTLBuffer
    /// ボクセルごとのカラー（RGBA8 packed uint, R=下位バイト）。カラー焼き込み用（private）。
    let colorBuffer: MTLBuffer
    /// [0]=updated(毎フレーム), [1]=activeTotal（CPU が metrics 用に読む, shared）。
    let countersBuffer: MTLBuffer

    // --- Sparse 統合用（ブロックスパース） ---
    static let blockEdge = 8
    let blocksDim: SIMD3<Int32>           // 各軸のブロック数
    var blockCount: Int { Int(blocksDim.x) * Int(blocksDim.y) * Int(blocksDim.z) }
    let blockFlags: MTLBuffer             // uint × blockCount（private）
    let activeBlockList: MTLBuffer        // uint × blockCount（private）
    let activeCountBuffer: MTLBuffer      // uint ×1（shared）
    let indirectArgsBuffer: MTLBuffer     // MTLDispatchThreadgroupsIndirectArguments（private）

    var voxelCount: Int { Int(dims.x) * Int(dims.y) * Int(dims.z) }
    var byteCount: Int { voxelCount * Self.voxelStride }

    /// - Parameters:
    ///   - voxelSize: 1 ボクセルの一辺 [m]
    ///   - extent: 対象を覆うワールドサイズ [m]
    ///   - maxVoxels: メモリ上限（128MB / 8B ≒ 16.7M に余裕を見て既定 24M）
    init?(device: MTLDevice, voxelSize: Float, extent: SIMD3<Float>,
          maxVoxels: Int = 24_000_000) {
        let dx = max(1, Int((extent.x / voxelSize).rounded(.up)))
        let dy = max(1, Int((extent.y / voxelSize).rounded(.up)))
        let dz = max(1, Int((extent.z / voxelSize).rounded(.up)))
        let count = dx * dy * dz
        guard count <= maxVoxels else { return nil }

        let be = Self.blockEdge
        let bx = (dx + be - 1) / be, by = (dy + be - 1) / be, bz = (dz + be - 1) / be
        let blockN = bx * by * bz

        guard let vb = device.makeBuffer(length: count * Self.voxelStride,
                                         options: .storageModePrivate),
              let colorB = device.makeBuffer(length: count * 4, options: .storageModePrivate),
              let cb = device.makeBuffer(length: 16, options: .storageModeShared),
              let bf = device.makeBuffer(length: blockN * 4, options: .storageModePrivate),
              let al = device.makeBuffer(length: blockN * 4, options: .storageModePrivate),
              let ac = device.makeBuffer(length: 4, options: .storageModeShared),
              let ia = device.makeBuffer(length: 16, options: .storageModePrivate) else {
            return nil
        }
        self.dims = SIMD3(Int32(dx), Int32(dy), Int32(dz))
        self.blocksDim = SIMD3(Int32(bx), Int32(by), Int32(bz))
        self.voxelSize = voxelSize
        self.voxelBuffer = vb
        self.colorBuffer = colorB
        self.countersBuffer = cb
        self.blockFlags = bf
        self.activeBlockList = al
        self.activeCountBuffer = ac
        self.indirectArgsBuffer = ia
        vb.label = "TSDF.voxels"
        colorB.label = "TSDF.colors"
        cb.label = "TSDF.counters"
        bf.label = "TSDF.blockFlags"
    }

    /// カメラ前方にボリュームを配置する（スキャン中は固定）。
    func position(frontOf cameraToWorld: simd_float4x4, distance: Float) {
        let camPos = SIMD3<Float>(cameraToWorld.columns.3.x,
                                  cameraToWorld.columns.3.y,
                                  cameraToWorld.columns.3.z)
        let forward = -SIMD3<Float>(cameraToWorld.columns.2.x,
                                    cameraToWorld.columns.2.y,
                                    cameraToWorld.columns.2.z)
        let center = camPos + forward * distance
        origin = center - extent * 0.5
        isPositioned = true
    }

    /// ボリューム全体とカウンタを 0 クリアする（weight=0 が未観測）。配置もリセット。
    func clear(commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.fill(buffer: voxelBuffer, range: 0..<byteCount, value: 0)
        blit.fill(buffer: colorBuffer, range: 0..<(voxelCount * 4), value: 0)
        blit.fill(buffer: countersBuffer, range: 0..<16, value: 0)
        blit.endEncoding()
        isPositioned = false
    }

    /// 毎フレームの updated カウンタ（先頭 4B）だけ 0 に戻す。
    func resetUpdatedCounter(commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.fill(buffer: countersBuffer, range: 0..<4, value: 0)
        blit.endEncoding()
    }

    /// カウンタ読み出し（GPU 完了後に呼ぶ）。
    func readCounters() -> (updated: UInt32, active: UInt32) {
        let p = countersBuffer.contents().bindMemory(to: UInt32.self, capacity: 2)
        return (p[0], p[1])
    }
}
