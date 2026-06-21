//
//  ScanEngine.swift
//  ScanEngine / Core
//
//  スキャンパイプラインを統括する facade（MVVM の Model）。
//  入力ソース → フィルタチェーン →（Phase 4 で TSDF）→ プレビュー という固定の流れを持ち、
//  各段はプロトコル/差し替え可能オブジェクトに委譲する。
//
//  View（ScanEnginePreviewView）も RN Bridge も、この ScanEngine のみに依存する。
//  スキャン処理を View に持たせない（責務分離）ための中心点。
//

import Metal
import Foundation

/// パイプライン統括。スレッド安全のため状態更新と通知は内部で適切にマーシャリングする。
final class ScanEngine: DepthFrameSourceDelegate {

    // MARK: - 公開状態（MVVM: Model → ViewModel/Bridge へ）

    /// 状態変化通知（メインスレッドで呼ぶ）。
    var onState: ((ScanEngineState) -> Void)?
    /// 1 フレーム処理完了通知（プレビュー描画用、メインスレッドで呼ぶ）。
    var onFrame: ((DepthFrame) -> Void)?

    /// 状態はキャプチャキューとメインスレッドの双方から更新され得るため、ロックで保護する
    /// （Thread Sanitizer 対策）。読み取りは公開、更新は `setState` 経由（private）に限定する。
    private let stateLock = NSLock()
    private var _state: ScanEngineState = .idle

    /// 現在の状態（読み取り専用・スレッド安全）。
    var state: ScanEngineState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    /// 状態を更新し、変化時のみメインスレッドで通知する。
    private func setState(_ newValue: ScanEngineState) {
        stateLock.lock()
        let changed = newValue != _state
        _state = newValue
        stateLock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onState?(newValue)
        }
    }

    /// パラメータ。React から一部調整される。
    var config: ScanConfig

    /// 公開: フィルタチェーン（Phase 3 でフィルタを append する拡張点）。
    let filterChain = DepthFilterChain()

    // MARK: - 依存

    private let context: MetalContext
    private let source: DepthFrameSource

    /// 共有 GPU コンテキスト（プレビュー View 等が同一 device を使うために公開）。
    var metalContext: MetalContext { context }

    // Phase 4 で追加予定（型は確定済み・ここに差し込むだけで配線完了）:
    // private var tsdf: TSDFVolume?

    // MARK: - Init

    /// - Parameters:
    ///   - context: 共有 GPU コンテキスト
    ///   - source: 深度供給元（既定は TrueDepth）。テストや LiDAR/録画では差し替え可能。
    init(context: MetalContext, source: DepthFrameSource, config: ScanConfig = ScanConfig()) {
        self.context = context
        self.source = source
        self.config = config
        self.source.delegate = self
    }

    /// TrueDepth を既定ソースとして組み立てる簡易ファクトリ。
    static func makeDefault(config: ScanConfig = ScanConfig()) -> ScanEngine? {
        guard let context = MetalContext() else { return nil }
        let source = TrueDepthSource(context: context)
        return ScanEngine(context: context, source: source, config: config)
    }

    // MARK: - 制御 API（Bridge から呼ばれる最小操作）

    func start() {
        setState(.starting)
        source.start()
    }

    func stop() {
        source.stop()
        setState(.stopped)
    }

    /// 累積データの破棄（Phase 4 で TSDF ボリューム再初期化を追加）。
    func reset() {
        // tsdf?.clear()
    }

    // MARK: - DepthFrameSourceDelegate

    func depthFrameSource(_ source: DepthFrameSource, didOutput frame: DepthFrame) {
        // 品質の低いフレームは早期に足切り（無駄な GPU 処理を避ける）。
        guard frame.quality >= config.qualityMin else { return }

        // フィルタ →（Phase 4: TSDF integrate）を 1 つの command buffer に積む。
        let commandBuffer = context.commandQueue.makeCommandBuffer()
        let processed = filterChain.process(frame,
                                            commandBuffer: commandBuffer ?? dummyCommandBuffer(),
                                            context: context)
        // [Phase 4] tsdf?.integrate(processed, config: config, commandBuffer: commandBuffer)
        commandBuffer?.commit()

        // プレビューへ（描画は View 側の責務）。
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(processed)
        }
    }

    func depthFrameSource(_ source: DepthFrameSource, didChangeTracking trackingState: ScanTrackingState) {
        if case .stopped = state { return }
        setState(.running(tracking: trackingState))
    }

    func depthFrameSource(_ source: DepthFrameSource, didFail error: Error) {
        setState(.failed(error.localizedDescription))
    }

    // MARK: - private

    /// commandBuffer 生成に失敗した場合のフォールバック（実質到達しないが nil 回避）。
    private func dummyCommandBuffer() -> MTLCommandBuffer {
        // 生成失敗時はキューから再取得を試み、無ければ致命的状態へ。
        if let cb = context.commandQueue.makeCommandBuffer() { return cb }
        fatalError("MTLCommandBuffer を生成できません")
    }
}
