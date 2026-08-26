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

/// ポーズグラフを SE(3) 上で反復緩和（Gauss-Seidel 型）する既定実装。
/// 各エッジについて「i から予測した j」「j から予測した i」へ姿勢を少しずつ寄せ、
/// オドメトリとループ拘束の食い違い（ドリフト）を全体へ分配する。node[0] はアンカー固定。
///
/// 安全ガード: 反復後にエッジ総残差が減っていなければ入力姿勢をそのまま返す（悪化させない）。
/// ループ拘束が VIO 相対のまま（estimateRelative 未設定）だと食い違いが無く自然に無改変になる。
/// 実効性を出すには DefaultLoopClosureDetector.estimateRelative に幾何的な相対姿勢（ICP等）を与える。
final class DefaultPoseGraphOptimizer: PoseGraphOptimizer {

    func optimize(nodes: [simd_float4x4], edges: [PoseGraphEdge],
                  config: GlobalOptConfig) -> [simd_float4x4] {
        guard nodes.count >= 2, !edges.isEmpty else { return nodes }

        var poses = nodes
        let anchor = 0
        let errBefore = totalError(poses, edges)
        let stepBase: Float = 0.2   // 1 エッジあたりの寄せ率（過補正防止）

        for _ in 0..<config.pgoIterations {
            for e in edges {
                guard e.from < poses.count, e.to < poses.count else { continue }
                let w = min(1.0, max(0.0, e.weight)) * stepBase
                guard w > 0 else { continue }
                // i から予測した j へ寄せる。
                if e.to != anchor {
                    let predJ = poses[e.from] * e.relativePose
                    poses[e.to] = PoseMath.blend(poses[e.to], predJ, w)
                }
                // j から予測した i へ寄せる。
                if e.from != anchor {
                    let predI = poses[e.to] * e.relativePose.inverse
                    poses[e.from] = PoseMath.blend(poses[e.from], predI, w)
                }
            }
        }

        let errAfter = totalError(poses, edges)
        return errAfter < errBefore ? poses : nodes   // 改善時のみ採用
    }

    /// エッジ総残差（並進 [m] + 回転 [rad] を重み付き加算）。
    private func totalError(_ poses: [simd_float4x4], _ edges: [PoseGraphEdge]) -> Float {
        var sum: Float = 0
        for e in edges {
            guard e.from < poses.count, e.to < poses.count else { continue }
            let rel = poses[e.from].inverse * poses[e.to]
            let dt = simd_length(PoseMath.translation(rel) - PoseMath.translation(e.relativePose))
            let da = PoseMath.angle(rel, e.relativePose)
            sum += (dt + da) * max(0.001, e.weight)
        }
        return sum
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

/// 大域最適化の実行統計（ログ/可視化用）。
struct GlobalOptStats {
    var keyframes = 0
    var loopCandidates = 0
    var correctionApplied = false   // PGO が実際に姿勢を補正したか
    var triangles = 0
}

/// 検出→最適化→再統合→再メッシュを束ねる。差し替え可能な detector / optimizer を保持。
final class GlobalOptimizationPipeline {

    var detector: LoopClosureDetector = DefaultLoopClosureDetector()
    var optimizer: PoseGraphOptimizer = DefaultPoseGraphOptimizer()
    private let reintegrator = TSDFReintegrator()
    private let smoother = TSDFSmoother()   // ライブ経路と同じ SDF 平滑化（再統合メッシュのぼこぼこ防止）

    /// 直近 run() の統計（呼び出し後に読む）。
    private(set) var lastStats = GlobalOptStats()

    /// - Returns: 再生成した頂点スープ（CPUMesh）。失敗時は nil（呼び出し側は従来メッシュにフォールバック）。
    func run(frames: [Keyframe], config: ScanConfig, gConfig: GlobalOptConfig,
             context: MetalContext) -> CPUMesh? {
        lastStats = GlobalOptStats()
        guard frames.count >= 2 else { return nil }
        lastStats.keyframes = frames.count

        // 1) エッジ構築: オドメトリ（連続キーフレーム）＋ ループ拘束。
        var edges: [PoseGraphEdge] = []
        edges.reserveCapacity(frames.count)
        for i in 1..<frames.count {
            let rel = frames[i - 1].pose.inverse * frames[i].pose
            edges.append(PoseGraphEdge(from: i - 1, to: i, relativePose: rel,
                                       weight: 1, kind: .odometry))
        }
        // ループ拘束の幾何推定を frame-to-frame ICP で注入する（現状 detector が既定実装のとき）。
        // VIO 相対との食い違いが PGO により分配され、周回の継ぎ目が閉じる。
        if let d = detector as? DefaultLoopClosureDetector {
            let solver = LoopClosureICP(context: context, config: config)
            d.featureMatch = { solver.solve($0, $1)?.confidence ?? 0 }
            d.estimateRelative = { solver.solve($0, $1)?.rel ?? ($0.pose.inverse * $1.pose) }
        }
        let candidates = detector.detect(frames, config: gConfig)
        lastStats.loopCandidates = candidates.count
        for c in candidates {
            edges.append(PoseGraphEdge(from: c.from, to: c.to, relativePose: c.relativePose,
                                       weight: c.confidence, kind: .loop))
        }

        // 2) 大域最適化 → 補正姿勢を書き戻す。
        let nodes = frames.map { $0.pose }
        let corrected = optimizer.optimize(nodes: nodes, edges: edges, config: gConfig)
        if corrected.count == frames.count {
            // 実際に姿勢が動いたか（安全ガードで無改変のこともある）。
            var moved = false
            for i in 0..<frames.count {
                if PoseMath.distance(corrected[i], frames[i].pose) > 1e-5 { moved = true }
                frames[i].pose = corrected[i]
            }
            lastStats.correctionApplied = moved
        }

        // 3) 新規ボリュームへ再統合（補正姿勢で）。
        guard let volume = TSDFVolume(device: context.device,
                                      voxelSize: config.voxelSize, extent: config.volumeExtent) else {
            return nil
        }
        reintegrator.reintegrate(frames, into: volume, config: config, context: context)

        // 4) 再メッシュ（Marching Cubes）。ライブ経路と同じく SDF 平滑化を通してから MC し、
        //    再統合メッシュがぼこぼこにならないようにする（＝ループ補正の効果 × ライブ同等の滑らかさ）。
        guard let extractor = MarchingCubesExtractor(device: context.device),
              let cb = context.commandQueue.makeCommandBuffer() else { return nil }
        var source = volume.voxelBuffer
        if let smoothed = smoother.smooth(volume: volume, config: config,
                                          commandBuffer: cb, context: context) {
            source = smoothed
        }
        _ = extractor.extract(volume: volume, sourceBuffer: source, config: config,
                              commandBuffer: cb, context: context)
        cb.commit()
        cb.waitUntilCompleted()

        let soup = extractor.readbackPositions(context: context)
        guard soup.count >= 3 else { return nil }
        lastStats.triangles = soup.count / 3
        return CPUMesh(positions: soup)
    }
}
