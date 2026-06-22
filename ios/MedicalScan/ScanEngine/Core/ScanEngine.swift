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
    /// 1 フレーム処理完了通知（raw=入力, filtered=フィルタ後）。プレビュー/比較表示用、メインで呼ぶ。
    var onFrame: ((_ raw: DepthFrame, _ filtered: DepthFrame) -> Void)?
    /// per-filter GPU 時間[ms]（completion handler 由来＝バックグラウンド）。
    var onFilterGPUTime: ((_ name: String, _ ms: Double) -> Void)?
    /// イベントログ（tracking/quality/dropped 等）。メインで呼ぶ。
    var onEvent: ((_ kind: String, _ message: String) -> Void)?
    /// TSDF 統合の計測値。メインで呼ぶ。
    var onTSDFStats: ((TSDFStats) -> Void)?

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
    private var thermalObserver: NSObjectProtocol?

    // TSDF（Phase 4）。Mesh は知らない（Phase 5 で別コンポーネント）。
    private let integrator = TSDFIntegrator()
    private var tsdf: TSDFVolume?

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
        // per-filter GPU 時間をそのまま外へ中継。
        filterChain.onFilterGPUTime = { [weak self] name, ms in
            self?.onFilterGPUTime?(name, ms)
        }
        // 端末の発熱状態を監視（ブロック形式で NSObject 化を回避）。
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.handleThermalChange()
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    private func handleThermalChange() {
        let state = ProcessInfo.processInfo.thermalState
        guard state == .serious || state == .critical else { return }
        let label = state == .critical ? "critical" : "serious"
        onEvent?("thermal", "発熱警告: \(label)")
    }

    /// TrueDepth を既定ソースとし、標準フィルタ（Confidence）を組み込んで構築する。
    static func makeDefault(config: ScanConfig = ScanConfig()) -> ScanEngine? {
        guard let context = MetalContext() else { return nil }
        let source = TrueDepthSource(context: context)
        let engine = ScanEngine(context: context, source: source, config: config)
        engine.filterChain.append(ConfidenceFilter(config: config))  // priority 10
        engine.filterChain.append(BilateralFilter(config: config))   // priority 20
        engine.filterChain.append(TemporalFilter(config: config))    // priority 30
        engine.tsdf = TSDFVolume(device: context.device,
                                 voxelSize: config.voxelSize, extent: config.volumeExtent)
        return engine
    }

    // MARK: - 制御 API（Bridge から呼ばれる最小操作）

    func start() {
        filterChain.reset()   // Temporal 等の履歴を破棄してから開始
        // TSDF ボリュームをクリア（配置もリセット）。
        if let tsdf, let cb = context.commandQueue.makeCommandBuffer() {
            tsdf.clear(commandBuffer: cb)
            cb.commit()
        }
        setState(.starting)
        source.start()
    }

    func stop() {
        source.stop()
        setState(.stopped)
    }

    /// 累積データの破棄（Phase 4 で TSDF ボリューム再初期化を追加）。
    func reset() {
        filterChain.reset()
        // tsdf?.clear()
    }

    // MARK: - DepthFrameSourceDelegate

    func depthFrameSource(_ source: DepthFrameSource, didOutput frame: DepthFrame) {
        // 品質の低いフレームは早期に足切り（無駄な GPU 処理を避ける）。
        guard frame.quality >= config.qualityMin else {
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?("depthQualityLow", "深度品質が低くフレームを破棄しました")
            }
            return
        }

        // フィルタチェーン（各フィルタが専用 command buffer で encode/commit）。
        let filtered = filterChain.process(frame, context: context)

        // TSDF 統合（専用 command buffer で計測。Mesh は作らない）。
        if let tsdf {
            if !tsdf.isPositioned {
                tsdf.position(frontOf: frame.cameraToWorld,
                              distance: (config.depthMin + config.depthMax) * 0.5)
            }
            if let cb = context.commandQueue.makeCommandBuffer() {
                integrator.integrate(filtered, volume: tsdf, config: config,
                                     commandBuffer: cb, context: context)
                cb.addCompletedHandler { [weak self, weak tsdf] buffer in
                    guard let tsdf else { return }
                    let (updated, active) = tsdf.readCounters()
                    var stats = TSDFStats()
                    stats.gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
                    stats.updated = updated
                    stats.active = active
                    stats.total = tsdf.voxelCount
                    stats.bytes = tsdf.byteCount
                    DispatchQueue.main.async { self?.onTSDFStats?(stats) }
                }
                cb.commit()
            }
        }

        // プレビュー/比較へ（描画は View 側の責務）。raw と filtered を渡す。
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(frame, filtered)
        }
    }

    func depthFrameSource(_ source: DepthFrameSource, didChangeTracking trackingState: ScanTrackingState) {
        if case .stopped = state { return }
        setState(.running(tracking: trackingState))
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?("tracking", "Tracking: \(trackingState.label)")
        }
    }

    func depthFrameSource(_ source: DepthFrameSource, didFail error: Error) {
        setState(.failed(error.localizedDescription))
    }

    func depthFrameSource(_ source: DepthFrameSource, didLogEvent kind: String, message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(kind, message)
        }
    }
}
