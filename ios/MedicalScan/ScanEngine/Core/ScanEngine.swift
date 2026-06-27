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
import simd

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
    /// Mesh 抽出の計測値。メインで呼ぶ。
    var onMeshStats: ((MeshStats) -> Void)?

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
    private let sliceRenderer = TSDFSliceRenderer()
    private var tsdf: TSDFVolume?

    // Mesh 抽出（Phase 5）。Voxel 更新は知らない（読み取りのみ）。
    private var meshExtractor: MarchingCubesExtractor?
    private var meshFrameCounter = 0
    private let meshExtractInterval = 30   // ~2秒ごと（深度~15fps想定）

    // SDF 平滑化（Phase 6, ボリューム空間）。マスターは破壊しない。
    private let smoother = TSDFSmoother()
    /// SDF 平滑化の ON/OFF（A/B 比較用）。
    var sdfSmoothEnabled = true

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
        engine.meshExtractor = MarchingCubesExtractor(device: context.device)
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

    /// TSDF 断面を描画してテクスチャを返す（デバッグ表示用。Mesh は作らない）。
    /// - Parameters: mode 1:distance 2:weight 3:occupancy / axis 0:XY 1:XZ 2:YZ / slice 0..1
    func encodeTSDFSlice(mode: Int, axis: Int, slice: Float) -> MTLTexture? {
        guard let tsdf, tsdf.isPositioned,
              let m = TSDFSliceRenderer.Mode(rawValue: mode),
              let a = TSDFSliceRenderer.Axis(rawValue: axis),
              let cb = context.commandQueue.makeCommandBuffer() else { return nil }
        let tex = sliceRenderer.encode(volume: tsdf, mode: m, axis: a, slice: slice,
                                       commandBuffer: cb, context: context)
        cb.commit()
        return tex
    }

    /// 現在抽出済みのメッシュ（描画用）。頂点が無ければ nil。
    func currentMesh() -> (buffer: MTLBuffer, count: Int)? {
        guard let m = meshExtractor?.currentMesh(), m.vertexCount > 0 else { return nil }
        return (m.vertexBuffer, m.vertexCount)
    }

    /// ボリューム中心（ワールド）。軌道カメラの注視点。
    var volumeWorldCenter: SIMD3<Float>? {
        guard let tsdf, tsdf.isPositioned else { return nil }
        return tsdf.origin + tsdf.extent * 0.5
    }

    /// ボリューム半径（ワールド）。軌道カメラの距離決定用。
    var volumeWorldRadius: Float? {
        guard let tsdf else { return nil }
        return simd_length(tsdf.extent) * 0.5
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

            // Mesh 抽出（重いのでスロットル。Voxel 更新後に読むので順序は queue が保証）。
            meshFrameCounter += 1
            if let extractor = meshExtractor, tsdf.isPositioned,
               meshFrameCounter % meshExtractInterval == 0,
               let cb = context.commandQueue.makeCommandBuffer() {
                // SDF 平滑化（ON のとき）→ その結果から MC。OFF はマスターから直接。
                var source = tsdf.voxelBuffer
                if sdfSmoothEnabled,
                   let smoothed = smoother.smooth(volume: tsdf, config: config,
                                                  commandBuffer: cb, context: context) {
                    source = smoothed
                }
                _ = extractor.extract(volume: tsdf, sourceBuffer: source, config: config,
                                      commandBuffer: cb, context: context)
                cb.addCompletedHandler { [weak self, weak extractor] buffer in
                    guard let extractor else { return }
                    var stats = MeshStats()
                    stats.gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
                    stats.triangles = extractor.readVertexCount() / 3
                    DispatchQueue.main.async { self?.onMeshStats?(stats) }
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
