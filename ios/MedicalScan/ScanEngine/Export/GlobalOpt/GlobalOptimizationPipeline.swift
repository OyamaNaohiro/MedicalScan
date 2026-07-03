//
//  GlobalOptimizationPipeline.swift
//  ScanEngine / Export / GlobalOpt
//
//  エクスポート専用の大域最適化パイプライン（リアルタイムからは呼ばれない）:
//    キーフレーム → ループ候補検出 → Pose Graph Optimization → TSDF 再統合 → 再メッシュ。
//
//  戻り値は再生成した頂点スープ（CPUMesh）。以降は既存の ExportMeshPipeline
//  （Weld→HoleFilling→Taubin→QEM）へそのまま流す。
//

import Metal
import simd

// MARK: - 既定のループ候補検出

/// 姿勢距離・姿勢角度で粗くゲートし、特徴一致率で確定する既定実装。
/// 特徴一致・相対姿勢推定はフックで差し替え可能（未設定なら姿勢ゲートのみ＋VIO 相対姿勢）。
final class DefaultLoopClosureDetector: LoopClosureDetector {

    /// 特徴一致率を返すフック（0..1）。実装拡張点（深度/法線/学習特徴など）。
    var featureMatch: ((Keyframe, Keyframe) -> Float)?
    /// 相対姿勢の推定フック（例: フレーム間 ICP）。未設定なら VIO 相対姿勢を使う。
    var estimateRelative: ((Keyframe, Keyframe) -> simd_float4x4)?

    func detect(_ frames: [Keyframe], config: GlobalOptConfig) -> [LoopCandidate] {
        var out: [LoopCandidate] = []
        let n = frames.count
        guard n > config.minFrameGap + 1 else { return out }

        for i in 0..<n {
            let fi = frames[i]
            var j = i + config.minFrameGap
            while j < n {
                let fj = frames[j]
                defer { j += 1 }
                // 1) 姿勢ゲート（安価）: 位置・角度が近いフレーム対のみ候補にする。
                if PoseMath.distance(fi.pose, fj.pose) > config.maxPoseDistance { continue }
                if PoseMath.angle(fi.pose, fj.pose) > config.maxPoseAngle { continue }

                // 2) 特徴一致率（フックがあれば確定判定に使う）。
                var conf: Float = 1
                if let fm = featureMatch {
                    conf = fm(fi, fj)
                    if conf < config.minFeatureMatch { continue }
                }

                // 3) 相対姿勢（フックがあれば ICP 等、無ければ VIO 相対）。
                let rel = estimateRelative?(fi, fj) ?? (fi.pose.inverse * fj.pose)
                out.append(LoopCandidate(from: i, to: j, relativePose: rel, confidence: conf))
            }
        }
        return out
    }
}

// MARK: - 既定の Pose Graph Optimization（安全な恒等・実装拡張点）

/// 既定は「補正なし（恒等）」を返す安全実装。
/// ループ拘束を用いた実 SE(3) 最適化（Gauss-Newton / LM, se(3) 上の残差最小化）は
/// ここに実装する。誤った最適化で悪化させないため、未実装時は入力姿勢をそのまま返す。
final class DefaultPoseGraphOptimizer: PoseGraphOptimizer {
    func optimize(nodes: [simd_float4x4], edges: [PoseGraphEdge],
                  config: GlobalOptConfig) -> [simd_float4x4] {
        // TODO(実装拡張点): edges（odometry + loop）から情報行列付き残差を組み、
        //   ノード姿勢を se(3) 上で反復最適化する。node[0] をアンカー固定。
        return nodes
    }
}

// MARK: - TSDF 再統合

/// 補正済みキーフレームで TSDF を新規に再統合する（エクスポート専用・同期実行）。
final class TSDFReintegrator {

    private let integrator = TSDFIntegrator()

    /// volume をクリアし、frames[0] を基準に配置してから全キーフレームを統合する。
    func reintegrate(_ frames: [Keyframe], into volume: TSDFVolume,
                     config: ScanConfig, context: MetalContext) {
        guard let first = frames.first else { return }

        if let cb = context.commandQueue.makeCommandBuffer() {
            volume.clear(commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }
        volume.position(frontOf: first.pose,
                        distance: (config.depthMin + config.depthMax) * 0.5)

        for kf in frames {
            let frame = DepthFrame(
                depth: kf.depth, validMask: nil, confidence: nil, color: nil,
                intrinsics: kf.intrinsics, cameraToWorld: kf.pose,
                width: kf.width, height: kf.height,
                quality: 1, timestamp: kf.timestamp, sensor: .trueDepth)
            guard let cb = context.commandQueue.makeCommandBuffer() else { continue }
            integrator.integrate(frame, volume: volume, config: config,
                                  commandBuffer: cb, context: context)
            cb.commit()
            cb.waitUntilCompleted()
        }
    }
}

// MARK: - オーケストレータ

/// 検出→最適化→再統合→再メッシュを束ねる。差し替え可能な detector / optimizer を保持。
final class GlobalOptimizationPipeline {

    var detector: LoopClosureDetector = DefaultLoopClosureDetector()
    var optimizer: PoseGraphOptimizer = DefaultPoseGraphOptimizer()
    private let reintegrator = TSDFReintegrator()

    /// - Returns: 再生成した頂点スープ（CPUMesh）。失敗時は nil（呼び出し側は従来メッシュにフォールバック）。
    func run(frames: [Keyframe], config: ScanConfig, gConfig: GlobalOptConfig,
             context: MetalContext) -> CPUMesh? {
        guard frames.count >= 2 else { return nil }

        // 1) エッジ構築: オドメトリ（連続キーフレーム）＋ ループ拘束。
        var edges: [PoseGraphEdge] = []
        edges.reserveCapacity(frames.count)
        for i in 1..<frames.count {
            let rel = frames[i - 1].pose.inverse * frames[i].pose
            edges.append(PoseGraphEdge(from: i - 1, to: i, relativePose: rel,
                                       weight: 1, kind: .odometry))
        }
        let candidates = detector.detect(frames, config: gConfig)
        for c in candidates {
            edges.append(PoseGraphEdge(from: c.from, to: c.to, relativePose: c.relativePose,
                                       weight: c.confidence, kind: .loop))
        }

        // 2) 大域最適化 → 補正姿勢を書き戻す。
        let nodes = frames.map { $0.pose }
        let corrected = optimizer.optimize(nodes: nodes, edges: edges, config: gConfig)
        if corrected.count == frames.count {
            for i in 0..<frames.count { frames[i].pose = corrected[i] }
        }

        // 3) 新規ボリュームへ再統合（補正姿勢で）。
        guard let volume = TSDFVolume(device: context.device,
                                      voxelSize: config.voxelSize, extent: config.volumeExtent) else {
            return nil
        }
        reintegrator.reintegrate(frames, into: volume, config: config, context: context)

        // 4) 再メッシュ（Marching Cubes）→ 頂点スープを読み戻す。
        guard let extractor = MarchingCubesExtractor(device: context.device),
              let cb = context.commandQueue.makeCommandBuffer() else { return nil }
        _ = extractor.extract(volume: volume, sourceBuffer: volume.voxelBuffer, config: config,
                              commandBuffer: cb, context: context)
        cb.commit()
        cb.waitUntilCompleted()

        let soup = extractor.readbackPositions(context: context)
        guard soup.count >= 3 else { return nil }
        return CPUMesh(positions: soup)
    }
}
