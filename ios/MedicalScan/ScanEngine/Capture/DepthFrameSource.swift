//
//  DepthFrameSource.swift
//  ScanEngine / Capture
//
//  深度入力を抽象化するプロトコル。実体は TrueDepth / LiDAR / 録画再生 のいずれでもよい。
//  エンジン本体（ScanEngine）はこのプロトコルにのみ依存する（Dependency Inversion）。
//  これにより入力ソースを差し替えても下流（フィルタ・TSDF・メッシュ化）は無変更で済む。
//

import Foundation

/// 深度フレームの供給元。
protocol DepthFrameSource: AnyObject {
    /// 供給されるフレームのセンサー種別。
    var sensor: ScanSensor { get }

    /// フレーム/状態/エラーの受け取り先。
    var delegate: DepthFrameSourceDelegate? { get set }

    /// キャプチャ開始（AR セッション開始や録画再生開始）。
    func start()

    /// キャプチャ停止。
    func stop()
}

/// DepthFrameSource からの通知。すべて 1 つの直列キュー上で呼ばれることを保証する実装にする。
protocol DepthFrameSourceDelegate: AnyObject {
    /// 新しい深度フレームが得られた。
    func depthFrameSource(_ source: DepthFrameSource, didOutput frame: DepthFrame)

    /// トラッキング状態が変化した。
    func depthFrameSource(_ source: DepthFrameSource, didChangeTracking state: ScanTrackingState)

    /// 復旧不能なエラー。
    func depthFrameSource(_ source: DepthFrameSource, didFail error: Error)
}

/// 任意実装にするためのデフォルト（録画ソースなどトラッキングが無い実体向け）。
extension DepthFrameSourceDelegate {
    func depthFrameSource(_ source: DepthFrameSource, didChangeTracking state: ScanTrackingState) {}
}
