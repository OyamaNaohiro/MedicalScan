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
}

// MARK: - ScanConfig（全パラメータの一元管理。一部は React から調整）

struct ScanConfig {
    // 体積・解像度
    var voxelSize: Float = 0.003                       // 3 mm
    var volumeExtent: SIMD3<Float> = [0.6, 1.2, 0.6]   // ~上半身（m）
    /// 切り詰め距離。経験則で voxelSize の数倍（薄板の表裏が混ざらない範囲）。
    var truncation: Float { voxelSize * 4 }

    // TrueDepth 有効性マスク（per-pixel confidence が無い代替）
    var depthMin: Float = 0.20      // m
    var depthMax: Float = 0.90      // m
    var qualityMin: Float = 0.5     // フレーム品質の足切り
    var grazingCosMin: Float = 0.2  // |視線・法線| の下限（斜め縁を除外）

    // フィルタ
    var bilateralSigmaSpace: Float = 3
    var bilateralSigmaDepth: Float = 0.02
    var temporalAlpha: Float = 0.2  // 深度マップ側 EMA

    // TSDF
    var maxWeight: Float = 64       // 重み上限（適応性を保つ）

    // SDF 平滑化（ボリューム空間。MC 前に距離場を整える）
    var sdfSmoothIterations: Int = 1
    var sdfSmoothRadius: Int = 1          // 近傍半径（1=3^3）
    var sdfSmoothAmount: Float = 0.7      // 自距離→近傍平均へのブレンド 0..1
    var sdfNoiseMinNeighbors: Int = 5     // 観測近傍がこれ未満なら孤立ノイズとして除去
    var sdfHoleFillMinNeighbors: Int = 16 // 観測近傍がこれ以上なら未観測穴を補完

    // Mesh 抽出（MC）
    var meshMinWeight: Float = 3          // この重み未満のボクセルは表面化しない（ノイズ抑制と成長のバランス）

    // ICP Refinement（VIO 初期値の微調整。frame-to-model）
    var icpIterations: Int = 5
    var icpStride: Int = 6                // 深度の間引き（点数削減）
    var icpMinWeight: Float = 2           // モデル(TSDF)として信頼する最小重み

    // 整合ゲート（姿勢は動かさず、既存メッシュと一致するフレームだけ統合）
    var gateMinOverlap: Int = 60          // これ未満＝重なりほぼ無し（真の新領域）のときだけ無条件統合。
                                          // 少しでも重なれば一致チェックを課す（ドリフトの抜け穴を塞ぐ）
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
