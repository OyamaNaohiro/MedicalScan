//
//  ScanEngineTypes.swift
//  ScanEngine / Core
//
//  パイプライン各段が受け渡す値型を定義する。
//
//  最重要設計: `DepthFrame` は「フィルタ→TSDF へそのまま渡せる」完結した 1 フレーム表現にする。
//  TSDF integrate が必要とする情報（深度テクスチャ・カメラ内部パラメータ・カメラ姿勢・
//  解像度）をすべて内包するので、Phase 4 で型を変えずに `tsdf.integrate(frame)` が書ける。
//

import Metal
import simd

// MARK: - センサー種別（DepthFrameSource の実体を識別。録画再生も含む）

enum ScanSensor {
    case trueDepth   // 前面 TrueDepth（主軸）
    case lidar       // 背面 LiDAR sceneDepth（将来拡張）
    case recorded    // 録画済みフレームの再生（オフライン検証用）
}

// MARK: - スキャンモード（対象サイズ別プリセット）

/// 対象サイズに合わせて voxelSize / volumeExtent / 深度レンジを一括で切り替えるプリセット。
///
/// 核心は voxelSize（解像度）。対象が小さいほど箱を縮めて voxelSize を細かくでき、
/// 同じメモリ/計算量のまま線解像度が上がる（＝細部精度が上がる）。
/// TrueDepth の近距離ノイズ床は概ね 0.5〜1mm なので、手モードの 1.5mm 未満は頭打ちになる。
///
/// rawValue は React（scanMode prop）と一致させる。
enum ScanMode: Int {
    case hand = 0        // 手・小物   ~30cm   voxel 1.5mm
    case foot = 1        // 足・部位   ~50cm   voxel 2.0mm
    case upperBody = 2   // 上半身     ~1m     voxel 3.0mm（従来既定）

    /// このモードに対応する ScanConfig を返す（サイズ非依存パラメータは既定を継承）。
    func makeConfig() -> ScanConfig {
        var c = ScanConfig()
        switch self {
        case .hand:
            c.voxelSize = 0.0015                 // 1.5mm（ノイズ床(~1mm)より大きくモデルが安定・十分細かい）
            c.volumeExtent = [0.3, 0.3, 0.3]     // 200^3 ≈ 800万ボクセル（≈64MB）
            c.depthMin = 0.15
            c.depthMax = 0.45
            // truncation は「指の分離」と「視点間の融合（繋がり・滑らかさ）」のトレードオフ。
            // ×6(9mm)は癒着、×3(4.5mm)は薄すぎて周回で細部が途切れ。側面が周回でズレて別々の壁に
            // なり融合しない（meshMinWeightを下げても繋がらない）ため、×4.0(6mm)で融合を優先。
            // 外周・手の甲には向かい合う面が truncation 内に無いので指の癒着は起きにくい。
            c.truncationScale = 4.0
            // 指の隙間を穴埋めで塞がないよう、穴埋めの発動を厳しくする（16→22）。
            c.sdfHoleFillMinNeighbors = 22
            // 1.5mm はノイズが目立ちやすい。残像の出ないボリューム空間の平均化で表面を滑らかにする。
            c.maxWeight = 128        // ボリューム空間での観測平均を増やす（64→128）
            // 指の側面・縁など斜め視点の観測を拾い、周回中の細部を繋げる。
            c.grazingCosMin = 0.05   // 0.1→0.05
            // meshMinWeight は既定3のまま（下げるとノイズが面化してぼこぼこするだけで繋がらなかった）。
            // 小さい面・薄い側面は孤立ノイズ除去(27近傍の観測<5で削除)で侵食され消える。平滑化2反復で
            // 更に痩せる。手モードは細部保持を優先し除去を弱める（5→2）。副作用は浮遊ノイズ増。
            c.sdfNoiseMinNeighbors = 2
        case .foot:
            c.voxelSize = 0.002                  // 2.0mm
            c.volumeExtent = [0.5, 0.5, 0.5]     // 250^3 ≈ 1560万ボクセル
            c.depthMin = 0.20
            c.depthMax = 0.60
        case .upperBody:
            c.voxelSize = 0.003                  // 3.0mm（従来値）
            c.volumeExtent = [0.6, 1.2, 0.6]
            c.depthMin = 0.20
            c.depthMax = 0.90
        }
        return c
    }

    var label: String {
        switch self {
        case .hand: return "手・小物"
        case .foot: return "足・部位"
        case .upperBody: return "上半身"
        }
    }
}

// MARK: - トラッキング状態（ARCamera.trackingState を抽象化）

// ARKit VIO の追従状態。normal 以外は姿勢が信頼できないため TSDF 統合を抑制する。
enum ScanTrackingState: Equatable {
    case normal        // 安定。統合可
    case limited       // 初期化中/急速移動/特徴不足など。統合抑制
    case relocalizing  // 再ローカライズ中（中断復帰など）。統合停止
    case notAvailable  // 追従不可。統合停止
}

// MARK: - カメラ内部パラメータ

/// 深度マップ解像度に合わせてスケール済みのピンホール内部パラメータ。
/// 画素 (u,v) ←→ カメラ座標 (X,Y,Z) の相互変換に用いる。
struct CameraIntrinsics {
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float

    /// 3x3 行列形式（compute kernel へ simd でそのまま渡せる）。
    var matrix: simd_float3x3 {
        simd_float3x3(columns: (SIMD3<Float>(fx, 0,  0),
                                SIMD3<Float>(0,  fy, 0),
                                SIMD3<Float>(cx, cy, 1)))
    }

    /// 参照解像度 refW/refH で得た内部パラメータを、実際の depth 解像度 (w,h) にスケールする。
    static func scaled(from intrinsic: simd_float3x3,
                       referenceWidth refW: Float, referenceHeight refH: Float,
                       toWidth w: Int, toHeight h: Int) -> CameraIntrinsics {
        let sx = Float(w) / refW
        let sy = Float(h) / refH
        return CameraIntrinsics(fx: intrinsic[0][0] * sx,
                                fy: intrinsic[1][1] * sy,
                                cx: intrinsic[2][0] * sx,
                                cy: intrinsic[2][1] * sy)
    }
}

// MARK: - DepthFrame（パイプラインの基本単位）

/// 1 フレーム分の深度入力。フィルタ・TSDF・プレビューが共通で受け取る。
/// GPU リソースは MTLTexture 参照のまま保持し、CPU へのコピーを避ける。
struct DepthFrame {
    /// 深度 [m]。r32Float。無効画素は 0 または NaN（有効性は validMask / config レンジで判定）。
    /// フィルタはコピーして depth を差し替えるため var。
    var depth: MTLTexture
    /// 有効画素マスク（r8Unorm: 1=有効）。ConfidenceFilter が生成。未生成なら nil。
    var validMask: MTLTexture?
    /// LiDAR 時のみ存在する信頼度（0..2）。TrueDepth では nil（quality + レンジで代替）。
    var confidence: MTLTexture?
    /// 対応するカラー（RGBA）。プレビュー/カラーTSDF 用。未取得なら nil。
    var color: MTLTexture?

    /// 深度解像度に整合した内部パラメータ。
    let intrinsics: CameraIntrinsics
    /// カメラ→ワールド変換（姿勢）。既定は VIO 由来。ICP Refinement で差し替えられるよう var。
    var cameraToWorld: simd_float4x4

    let width: Int
    let height: Int
    /// フレーム品質 0..1（AVDepthData.depthDataQuality 由来）。低品質フレームの足切り用。
    let quality: Float
    let timestamp: TimeInterval
    let sensor: ScanSensor

    /// 適用済みフィルタのビットフラグ（将来: TSDF 統合判断・品質メタに使用）。
    var filterFlags: UInt32 = 0

    // MARK: AR オーバーレイ（カメラ映像へメッシュを重ねるライブ表示用。取得時のみ非nil）
    /// ARKit ビュー行列（portrait 表示向き。world→camera）。
    var cameraView: simd_float4x4?
    /// ARKit 投影行列（portrait・viewport 反映済み）。メッシュを映像に正しく重ねるため使用。
    var cameraProjection: simd_float4x4?
    /// 背景カメラ映像の UV 補正（displayTransform の逆行列。portrait）。
    var displayTransformInv: simd_float3x3?
}

// MARK: - ScanConfig（全パラメータの一元管理。一部は React から調整）

struct ScanConfig {
    // 体積・解像度
    var voxelSize: Float = 0.003                       // 3 mm
    var volumeExtent: SIMD3<Float> = [0.6, 1.2, 0.6]   // ~上半身（m）
    /// 切り詰め距離の倍率（voxelSize 比）。大きいほど近接面が融合しやすく「つながり」優先
    /// （ドリフトの二重壁を1枚へ融合）、小さいほど細部が出るが二重壁になりやすい。
    /// ※ sparse 統合の 3x3x3 マーキング被覆に収めるため実質上限は ~6。
    var truncationScale: Float = 4
    /// 切り詰め距離。voxelSize × truncationScale（融合＝つながりを優先）。
    var truncation: Float { voxelSize * truncationScale }

    // TrueDepth 有効性マスク（per-pixel confidence が無い代替）
    var depthMin: Float = 0.20      // m
    var depthMax: Float = 0.90      // m
    var qualityMin: Float = 0.5     // フレーム品質の足切り
    var grazingCosMin: Float = 0.1  // |視線・法線| の下限。低いほど斜め縁も採用→周回時に側面がつながりやすい

    // フィルタ
    var bilateralSigmaSpace: Float = 3
    var bilateralSigmaDepth: Float = 0.02
    var temporalAlpha: Float = 0.2  // 深度マップ側 EMA

    // TSDF
    var maxWeight: Float = 64       // 重み上限（適応性を保つ）

    // SDF 平滑化（ボリューム空間。MC 前に距離場を整える）
    // 反復・ブレンドを強めると、融合したつながりは保ったまま表面のさざ波（ぼこぼこ）を均せる。
    var sdfSmoothIterations: Int = 2     // 反復回数（1→2 で表面のさざ波を低減）
    var sdfSmoothRadius: Int = 1          // 近傍半径（1=3^3）
    var sdfSmoothAmount: Float = 0.8      // 自距離→近傍平均へのブレンド 0..1（0.7→0.8 で更に平滑）
    var sdfNoiseMinNeighbors: Int = 5     // 観測近傍がこれ未満なら孤立ノイズとして除去
    var sdfHoleFillMinNeighbors: Int = 16 // 観測近傍がこれ以上なら未観測穴を補完

    // Mesh 抽出（MC）
    var meshMinWeight: Float = 3          // この重み未満のボクセルは表面化しない（ノイズ抑制と成長のバランス）

    // ICP Refinement（VIO 初期値の微調整。frame-to-model）
    var icpIterations: Int = 5
    var icpStride: Int = 6                // 深度の間引き（点数削減）
    var icpMinWeight: Float = 2           // モデル(TSDF)として信頼する最小重み
    /// ARKit 予測運動への事前分布の相対重み。劣決定方向の安定化を狙ったが、引き戻し先の ARKit
    /// 自体がドリフトするため、深度オドメトリに ARKit ドリフトを再注入してしまい全モードで劣化した
    /// （ビルド105→107で撤回）。0=無効。将来は引き戻し先を定速度モデル(深度オドメトリ自身)にすべき。
    var icpPriorWeight: Float = 0.0

    // 整合ゲート（姿勢は動かさず、既存メッシュと一致するフレームだけ統合）
    var gateMinOverlap: Int = 250         // これ未満＝重なりほぼ無し（新領域）のときは無条件統合。
                                          // 250 に戻し、ゲートを緩めてメッシュが育ちやすい 71 系の見え方に近づける
                                          // （厳格化=60 は二重壁を抑える代わりに面が欠けやすかったため元に戻した）
    var gateAgreeRatio: Float = 0.7       // 重なり点のうち表面に一致する最低割合（厳しめ）
}

// MARK: - エンジン状態（MVVM の Model が公開する状態）

enum ScanEngineState: Equatable {
    case idle
    case starting
    case running(tracking: ScanTrackingState)
    case stopped
    case failed(String)
}
