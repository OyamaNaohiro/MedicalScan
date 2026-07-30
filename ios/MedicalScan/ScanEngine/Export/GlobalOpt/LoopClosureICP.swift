//
//  LoopClosureICP.swift
//  ScanEngine / Export / GlobalOpt
//
//  ループ拘束の幾何推定（フレーム間 ICP）。GlobalOptimizationPipeline のフック
//  （DefaultLoopClosureDetector.featureMatch / estimateRelative）の実体。
//
//  仕組み: キーフレーム i の深度から小さな TSDF（i のカメラ座標系）を作り、
//  キーフレーム j の深度を frame-to-model ICP でそこへ合わせる。得られた姿勢が
//  「i→j の幾何的相対姿勢」。VIO 相対（ドリフト込み）との食い違いが PGO により
//  分配され、周回の継ぎ目が閉じる。
//
//  エクスポート専用・同期実行（リアルタイムから呼ばれない）。既存の ICPRefiner /
//  TSDFIntegrator を再利用するため新規の数学は無い。
//

import Metal
import simd

final class LoopClosureICP {

    private let context: MetalContext
    private let config: ScanConfig
    private let refiner = ICPRefiner()
    private let integrator = TSDFIntegrator()

    // キーフレーム i の mini-TSDF をキャッシュ（detect は i 外側・j 内側ループなので連続 j で再利用）。
    private var cachedFromId = -1
    private var cachedVolume: TSDFVolume?

    // 直近 solve のキャッシュ（featureMatch と estimateRelative が同一対で二重に ICP しないよう）。
    private var lastKey = (-1, -1)
    private var lastResult: (rel: simd_float4x4, confidence: Float)?

    // ループ拘束として信頼する最小対応点数。
    private let minCorrespondences = 300

    init(context: MetalContext, config: ScanConfig) {
        self.context = context
        self.config = config
    }

    /// i→j の相対姿勢と信頼度を返す。ICP が破綻したら nil。
    func solve(_ fi: Keyframe, _ fj: Keyframe) -> (rel: simd_float4x4, confidence: Float)? {
        if lastKey == (fi.id, fj.id) { return lastResult }
        lastKey = (fi.id, fj.id)
        lastResult = compute(fi, fj)
        return lastResult
    }

    private func compute(_ fi: Keyframe, _ fj: Keyframe) -> (simd_float4x4, Float)? {
        guard let volume = volumeFor(fi) else { return nil }
        // VIO 相対（i の座標系での j の姿勢）を初期値に ICP で精緻化。
        let relInit = fi.pose.inverse * fj.pose
        let r = refiner.refine(
            depth: fj.depth, mask: nil, volume: volume,
            intrinsics: fj.intrinsics, width: fj.width, height: fj.height,
            vioPose: relInit, config: config, context: context)

        guard r.status == .ok, r.correspondences >= minCorrespondences else { return nil }
        // 信頼度: 残差 RMS を truncation で正規化（小さいほど高信頼）。
        let t = max(1e-4, config.truncation)
        let conf = max(0, min(1, 1 - r.rms / t))
        return (r.pose, conf)
    }

    /// キーフレーム i の mini-TSDF を用意する（i の変化時のみ clear→配置→統合）。
    /// ボリュームは 1 個を確保して使い回す（毎回の巨大バッファ確保を避ける）。
    private func volumeFor(_ fi: Keyframe) -> TSDFVolume? {
        if cachedFromId == fi.id, let v = cachedVolume { return v }
        if cachedVolume == nil {
            cachedVolume = TSDFVolume(device: context.device,
                                      voxelSize: config.voxelSize, extent: config.volumeExtent)
        }
        guard let v = cachedVolume else { return nil }

        if let cb = context.commandQueue.makeCommandBuffer() {
            v.clear(commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }
        // i のカメラ座標系（＝原点 identity）に配置して i の深度だけ統合する。
        v.position(frontOf: matrix_identity_float4x4,
                   distance: (config.depthMin + config.depthMax) * 0.5)
        let frame = DepthFrame(
            depth: fi.depth, validMask: nil, confidence: nil, color: nil,
            intrinsics: fi.intrinsics, cameraToWorld: matrix_identity_float4x4,
            width: fi.width, height: fi.height,
            quality: 1, timestamp: fi.timestamp, sensor: .trueDepth)
        if let cb = context.commandQueue.makeCommandBuffer() {
            integrator.integrate(frame, volume: v, config: config,
                                  commandBuffer: cb, context: context)
            cb.commit()
            cb.waitUntilCompleted()
        }
        cachedFromId = fi.id
        return v
    }
}
