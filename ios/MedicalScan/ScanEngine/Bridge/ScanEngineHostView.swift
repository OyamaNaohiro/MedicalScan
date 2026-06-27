//
//  ScanEngineHostView.swift
//  ScanEngine / Bridge
//
//  React Native がマウントするホスト View（Swift 実体）。
//  ScanEngine（処理）と ScanEnginePreviewView（描画専用）を所有して配線し、
//  メトリクス/状態を ScanEventEmitter 経由で RN へ送る。
//  RN へ公開するプロパティは isScanning / displayMode のみ（UI は RN 側）。
//

import UIKit
import Metal
import QuartzCore
import simd

@objc(ScanEngineHostView)
final class ScanEngineHostView: UIView {

    // MARK: - 依存

    private var engine: ScanEngine?
    private var preview: ScanEnginePreviewView?

    // MARK: - メトリクス集約

    private var metrics = ScanMetrics()
    private let depthRate = RateCounter(alpha: 0.15)
    private var lastEmit: CFTimeInterval = 0
    private var depthScratch: [Float] = []

    // MARK: - React props（KVC 経由で ObjC ラッパから設定）

    @objc var isScanning: Bool = false {
        didSet {
            guard isScanning != oldValue else { return }
            if isScanning { engine?.start() } else { engine?.stop() }
        }
    }

    @objc var displayMode: Int = DepthDisplayMode.filtered.rawValue {
        didSet {
            let mode = DepthDisplayMode(rawValue: displayMode) ?? .filtered
            preview?.displayMode = mode
            metrics.displayMode = mode
        }
    }

    /// 各フィルタの ON/OFF。
    @objc var confidenceEnabled: Bool = true {
        didSet { engine?.filterChain.setEnabled(confidenceEnabled, for: "Confidence") }
    }
    @objc var bilateralEnabled: Bool = true {
        didSet { engine?.filterChain.setEnabled(bilateralEnabled, for: "Bilateral") }
    }
    @objc var temporalEnabled: Bool = true {
        didSet { engine?.filterChain.setEnabled(temporalEnabled, for: "Temporal") }
    }

    /// TSDF スライス表示。0:off(深度) 1:distance 2:weight 3:occupancy。
    @objc var tsdfDisplay: Int = 0
    /// スライス軸。0:XY 1:XZ 2:YZ。
    @objc var tsdfAxis: Int = 0
    /// スライス位置 0..1。
    @objc var tsdfSlice: Double = 0.5

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black

        guard let engine = ScanEngine.makeDefault() else {
            ScanEventEmitter.emitEvent(["type": "engineError",
                                        "message": "Metal を初期化できませんでした。"])
            return
        }
        guard let preview = ScanEnginePreviewView(context: engine.metalContext) else {
            ScanEventEmitter.emitEvent(["type": "engineError",
                                        "message": "プレビューを初期化できませんでした（シェーダ未ロード）。"])
            return
        }
        self.engine = engine
        self.preview = preview

        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        preview.displayMode = DepthDisplayMode(rawValue: displayMode) ?? .filtered

        wireCallbacks(engine: engine, preview: preview)
    }

    // MARK: - 配線

    private func wireCallbacks(engine: ScanEngine, preview: ScanEnginePreviewView) {
        // 描画自己計測（GPU 時間・描画FPS）
        preview.onRenderMetrics = { [weak self] gpuMs, fps in
            guard let self else { return }
            self.metrics.gpuMs = gpuMs
            self.metrics.renderFPS = fps
        }

        // 深度フレーム（raw, filtered）→ プレビュー更新 + メトリクス集計
        engine.onFrame = { [weak self] raw, filtered in
            guard let self else { return }
            let t0 = CACurrentMediaTime()

            let cfg = engine.config
            // フィルタが適用された場合のみ filtered/mask を渡す（未適用なら raw 表示）。
            let filteredTex: MTLTexture? = filtered.filterFlags != 0 ? filtered.depth : nil
            self.preview?.update(raw: raw.depth,
                                 filtered: filteredTex,
                                 mask: filtered.validMask,
                                 depthMin: cfg.depthMin, depthMax: cfg.depthMax)

            // TSDF スライス表示（ON のときだけ断面を描画して上書き表示）。
            if self.tsdfDisplay > 0 {
                let tex = engine.encodeTSDFSlice(mode: self.tsdfDisplay,
                                                 axis: self.tsdfAxis,
                                                 slice: Float(self.tsdfSlice))
                self.preview?.updateSlice(tex)
            } else {
                self.preview?.updateSlice(nil)
            }

            self.depthRate.tick()
            self.metrics.depthFPS = self.depthRate.fps
            // 有効画素率は raw 深度（shared, CPU 可読）から算出する。
            self.metrics.validRatio = self.computeValidRatio(raw.depth,
                                                             min: cfg.depthMin, max: cfg.depthMax)
            self.metrics.cpuMs = (CACurrentMediaTime() - t0) * 1000.0
            self.emitMetricsThrottled()
        }

        // per-filter GPU 時間（バックグラウンド → メインへ）
        engine.onFilterGPUTime = { [weak self] name, ms in
            DispatchQueue.main.async { self?.metrics.filterTimes[name] = ms }
        }

        // TSDF 計測
        engine.onTSDFStats = { [weak self] stats in
            guard let self else { return }
            self.metrics.tsdfGpuMs = stats.gpuMs
            self.metrics.tsdfUpdated = stats.updated
            self.metrics.tsdfActive = stats.active
            self.metrics.tsdfOccupancy = stats.occupancy
            self.metrics.tsdfMB = stats.megabytes
        }

        // Mesh 計測
        engine.onMeshStats = { [weak self] stats in
            guard let self else { return }
            self.metrics.meshTriangles = stats.triangles
            self.metrics.mcGpuMs = stats.gpuMs
        }

        // イベントログ
        engine.onEvent = { [weak self] kind, message in
            _ = self
            ScanEventEmitter.emitEvent(["type": "engineLog", "kind": kind, "message": message])
        }

        // 状態通知
        engine.onState = { [weak self] state in
            self?.handleState(state)
        }
    }

    private func handleState(_ state: ScanEngineState) {
        switch state {
        case .running(let tracking):
            metrics.tracking = tracking
            ScanEventEmitter.emitEvent(["type": "engineState",
                                        "state": "running", "tracking": tracking.label])
        case .starting:
            ScanEventEmitter.emitEvent(["type": "engineState", "state": "starting"])
        case .stopped:
            depthRate.reset()
            ScanEventEmitter.emitEvent(["type": "engineState", "state": "stopped"])
        case .failed(let message):
            ScanEventEmitter.emitEvent(["type": "engineError", "message": message])
        case .idle:
            break
        }
    }

    // MARK: - メトリクス

    /// HUD 用に ~5Hz で送出（毎フレーム送らずブリッジ負荷を抑える）。
    private func emitMetricsThrottled() {
        let now = CACurrentMediaTime()
        guard now - lastEmit > 0.2 else { return }
        lastEmit = now
        ScanEventEmitter.emitEvent(metrics.dictionary)
    }

    /// 有効画素率を CPU で粗くサンプル（16画素おき）。Phase 8 で GPU リダクションへ。
    private func computeValidRatio(_ tex: MTLTexture, min lo: Float, max hi: Float) -> Double {
        let w = tex.width, h = tex.height
        let count = w * h
        guard count > 0 else { return 0 }
        if depthScratch.count != count { depthScratch = [Float](repeating: 0, count: count) }
        depthScratch.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var valid = 0, total = 0, i = 0
        let stride = 16
        while i < count {
            let d = depthScratch[i]
            if d.isFinite && d >= lo && d <= hi { valid += 1 }
            total += 1
            i += stride
        }
        return total > 0 ? Double(valid) / Double(total) : 0
    }
}
