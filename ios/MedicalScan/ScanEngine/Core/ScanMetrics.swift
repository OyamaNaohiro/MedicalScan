//
//  ScanMetrics.swift
//  ScanEngine / Core
//
//  デバッグHUD・品質評価のための計測値と、レート（FPS）の指数移動平均カウンタ。
//  TSDF 実装以降も品質を客観評価するため、Phase 2b から常設する。
//

import QuartzCore

// MARK: - 表示モード（プレビューの可視化切替）

/// プレビューの可視化モード。RN からは Int で受け取る。
enum DepthDisplayMode: Int {
    case rawDepth   = 0   // 生の深度をカラーマップ（マスクなし）
    case validMask  = 1   // 有効/無効の2値マスク
    case filtered   = 2   // 有効画素のみ深度カラーマップ（フィルタ後の見え方）
    case difference = 3   // |raw - filtered| の差分表示
}

// MARK: - 計測値

/// HUD に出す 1 スナップショット。
struct ScanMetrics {
    var renderFPS: Double = 0      // プレビュー描画レート
    var depthFPS: Double = 0       // 深度フレーム到着レート
    var gpuMs: Double = 0          // 直近フレームの GPU 時間
    var cpuMs: Double = 0          // 直近フレームの CPU 処理時間
    var validRatio: Double = 0     // 有効画素率 0..1
    var tracking: ScanTrackingState = .notAvailable
    var displayMode: DepthDisplayMode = .filtered
    /// フィルタ名 → 直近 GPU 時間[ms]（Confidence/Bilateral/Temporal）。
    var filterTimes: [String: Double] = [:]

    // TSDF（Phase 4）
    var tsdfGpuMs: Double = 0
    var tsdfUpdated: UInt32 = 0
    var tsdfActive: UInt32 = 0
    var tsdfOccupancy: Double = 0   // 0..1
    var tsdfMB: Double = 0

    // Mesh（Phase 5）
    var meshTriangles: Int = 0
    var mcGpuMs: Double = 0

    // ICP Refinement
    var icpRmsMm: Double = 0
    var icpCorr: Int = 0
    var icpApplied: Bool = false

    // 距離ガイド（UX 画面用）。中央領域の代表距離と現在モードの有効レンジ。
    var centerDepthM: Double = 0     // 画面中央の対象までの距離[m]（0=対象なし）
    var depthRangeMin: Double = 0    // 適正レンジ下限[m]
    var depthRangeMax: Double = 0    // 適正レンジ上限[m]

    /// ScanEventEmitter で RN へ送るための辞書表現（軽量・数値のみ）。
    var dictionary: [String: Any] {
        [
            "type": "metrics",
            "renderFPS": renderFPS,
            "depthFPS": depthFPS,
            "gpuMs": gpuMs,
            "cpuMs": cpuMs,
            "validRatio": validRatio,
            "tracking": tracking.label,
            "displayMode": displayMode.rawValue,
            "filterTimes": filterTimes,
            "tsdfGpuMs": tsdfGpuMs,
            "tsdfUpdated": Int(tsdfUpdated),
            "tsdfActive": Int(tsdfActive),
            "tsdfOccupancy": tsdfOccupancy,
            "tsdfMB": tsdfMB,
            "meshTriangles": meshTriangles,
            "mcGpuMs": mcGpuMs,
            "icpRmsMm": icpRmsMm,
            "icpCorr": icpCorr,
            "icpApplied": icpApplied,
            "centerDepthM": centerDepthM,
            "depthRangeMin": depthRangeMin,
            "depthRangeMax": depthRangeMax,
        ]
    }
}

extension ScanTrackingState {
    var label: String {
        switch self {
        case .normal: return "normal"
        case .limited: return "limited"
        case .relocalizing: return "relocalizing"
        case .notAvailable: return "notAvailable"
        }
    }
}

// MARK: - レートカウンタ（FPS の指数移動平均）

/// イベント間隔から瞬間 FPS を求め、EMA で平滑化する。
/// 数学: 瞬間値 inst = 1/Δt を毎回測り、fps ← (1-α)·fps + α·inst。
/// α を小さくすると安定、大きくすると追従が速い。HUD 向けに α=0.1。
final class RateCounter {
    private var lastTimestamp: CFTimeInterval?
    private let alpha: Double
    private(set) var fps: Double = 0

    init(alpha: Double = 0.1) { self.alpha = alpha }

    /// 1 イベント発生を記録し、平滑化 FPS を更新する。
    func tick(now: CFTimeInterval = CACurrentMediaTime()) {
        defer { lastTimestamp = now }
        guard let last = lastTimestamp else { return }
        let dt = now - last
        guard dt > 0 else { return }
        let inst = 1.0 / dt
        fps = fps == 0 ? inst : (1 - alpha) * fps + alpha * inst
    }

    func reset() { lastTimestamp = nil; fps = 0 }
}
