//
//  GlobalOptimizationTypes.swift
//  ScanEngine / Export / GlobalOpt
//
//  エクスポート時の大域最適化（ループ閉じ込み + Pose Graph Optimization）の
//  中核データ型・プロトコル・設定を定義する「拡張構造」。
//
//  設計の要点（要件）:
//   - リアルタイム経路とは完全分離。ここに定義するものはエクスポート時のみ動く。
//     リアルタイムで触れるのは KeyframeRecorder.consider() だけで、有効時のみ・間引き保持で
//     60fps を犠牲にしない（既定は無効＝コストゼロ）。
//   - ループ候補は「姿勢距離・姿勢角度・特徴一致率」で判定する（DefaultLoopClosureDetector）。
//   - 大域最適化後は TSDF を再統合し、最終メッシュを再生成する（GlobalOptimizationPipeline）。
//
//  実装拡張点（TODO）:
//   - FeatureMatcher: 深度/法線などから特徴一致率を返すフック。
//   - PoseGraphOptimizer: SE(3) の実ソルバ（Gauss-Newton / LM）。既定は安全な恒等（無改変）。
//

import Metal
import simd

// MARK: - キーフレーム

/// スキャン中に間引いて保持する 1 キーフレーム。
/// エクスポート時の大域最適化・TSDF 再統合に使う。
/// リアルタイムでは「深度テクスチャ参照＋姿勢＋内部パラメータ」を持つだけ（コピー最小化）。
/// depth は TrueDepthSource が毎フレーム新規確保する所有テクスチャを参照保持する（ゼロコピー）。
final class Keyframe {
    let id: Int
    /// VIO 由来のワールド姿勢。PGO により補正され得るため var。
    var pose: simd_float4x4
    let intrinsics: CameraIntrinsics
    let width: Int
    let height: Int
    let depth: MTLTexture
    let timestamp: TimeInterval
    /// ループ検出用の特徴（任意・遅延生成）。実装時に定義する。
    var descriptor: LoopDescriptor?

    init(id: Int, pose: simd_float4x4, intrinsics: CameraIntrinsics,
         width: Int, height: Int, depth: MTLTexture, timestamp: TimeInterval) {
        self.id = id
        self.pose = pose
        self.intrinsics = intrinsics
        self.width = width
        self.height = height
        self.depth = depth
        self.timestamp = timestamp
    }
}

/// ループ検出に使う軽量特徴（実装差し替え可能）。
/// 例: 縮小深度のダウンサンプル、法線ヒストグラム、学習特徴など。
struct LoopDescriptor {
    var vector: [Float]
}

/// スレッドセーフなキーフレーム保持。リアルタイム（capture キュー）から append、
/// エクスポート（バックグラウンド）から snapshot される。
final class KeyframeStore {
    private let lock = NSLock()
    private var frames: [Keyframe] = []

    func append(_ k: Keyframe) { lock.lock(); frames.append(k); lock.unlock() }
    func snapshot() -> [Keyframe] { lock.lock(); defer { lock.unlock() }; return frames }
    func clear() { lock.lock(); frames.removeAll(); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
}

// MARK: - ループ候補・ポーズグラフ

/// ループ閉じ込み候補（キーフレーム i, j 間の相対姿勢拘束）。
struct LoopCandidate {
    let from: Int                      // keyframe index
    let to: Int
    var relativePose: simd_float4x4    // from→to の相対姿勢（ICP 等で推定）
    var confidence: Float              // 特徴一致率など 0..1
}

/// ポーズグラフのエッジ。
struct PoseGraphEdge {
    enum Kind { case odometry, loop }
    let from: Int
    let to: Int
    var relativePose: simd_float4x4    // 計測相対姿勢（from→to）
    var weight: Float                  // 情報量（信頼度）
    let kind: Kind
}

// MARK: - 設定

/// 大域最適化・キーフレーム間引きのパラメータ。
struct GlobalOptConfig {
    // キーフレーム間引き（リアルタイム保持のゲート）
    var keyframeMinTranslation: Float = 0.03   // 3cm 動いたら
    var keyframeMinRotation: Float = 0.1       // ~5.7°
    var keyframeMinInterval: TimeInterval = 0.2
    var maxKeyframes: Int = 400                // メモリ上限（超過で保持停止）

    // ループ候補ゲート
    var minFrameGap: Int = 20            // これ以上離れたキーフレーム同士のみ候補（隣接は除外）
    var maxPoseDistance: Float = 0.15    // 位置がこの距離以内 [m]
    var maxPoseAngle: Float = 0.6        // 姿勢角度差の上限 [rad] (~34°)
    var minFeatureMatch: Float = 0.4     // 特徴一致率の下限（フック使用時）

    // PGO
    var pgoIterations: Int = 10
    var pgoConverge: Float = 1e-5
}

// MARK: - プロトコル（実装拡張点）

/// ループ候補検出。姿勢距離・角度で粗くゲートし、特徴一致率で確定する。
protocol LoopClosureDetector: AnyObject {
    func detect(_ frames: [Keyframe], config: GlobalOptConfig) -> [LoopCandidate]
}

/// ポーズグラフ最適化（大域最適化）。
/// ノード=キーフレーム姿勢、エッジ=オドメトリ + ループ拘束。
/// 戻り値は補正後のワールド姿勢（nodes と同順・同数）。
protocol PoseGraphOptimizer: AnyObject {
    func optimize(nodes: [simd_float4x4], edges: [PoseGraphEdge],
                  config: GlobalOptConfig) -> [simd_float4x4]
}

// MARK: - 姿勢ヘルパー

enum PoseMath {
    static func translation(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    static func distance(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        simd_length(translation(a) - translation(b))
    }

    static func rot3(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                      SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                      SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }

    /// 2 姿勢の回転角の差 [rad]。
    static func angle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let r = rot3(a).transpose * rot3(b)
        let trace = r.columns.0.x + r.columns.1.y + r.columns.2.z
        let c = max(-1, min(1, (trace - 1) * 0.5))
        return acos(c)
    }

    /// 回転(quat)＋並進から 4x4 姿勢を組み立てる。
    static func makePose(rotation q: simd_quatf, translation t: SIMD3<Float>) -> simd_float4x4 {
        let r = simd_float3x3(q)
        return simd_float4x4(SIMD4(r.columns.0, 0),
                             SIMD4(r.columns.1, 0),
                             SIMD4(r.columns.2, 0),
                             SIMD4(t, 1))
    }

    /// 2 姿勢を係数 t（0..1）で補間する（回転は slerp、並進は線形）。PGO の緩和更新に使う。
    static func blend(_ a: simd_float4x4, _ b: simd_float4x4, _ t: Float) -> simd_float4x4 {
        let qa = simd_quatf(rot3(a)), qb = simd_quatf(rot3(b))
        let q = simd_slerp(qa, qb, t)
        let tr = translation(a) + (translation(b) - translation(a)) * t
        return makePose(rotation: q, translation: tr)
    }
}
