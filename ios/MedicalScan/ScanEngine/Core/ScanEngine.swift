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
    /// ICP の残差[m]・対応点数・統合適用フラグ。メインで呼ぶ。
    var onICPStats: ((_ rms: Float, _ correspondences: Int, _ applied: Bool) -> Void)?

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
    private let sparseIntegrator = SparseTSDFIntegrator()
    /// ブロックスパース統合（Phase 8）。既定 OFF（密版フォールバック維持）。
    var sparseEnabled = false
    private let sliceRenderer = TSDFSliceRenderer()
    private var tsdf: TSDFVolume?

    // Mesh 抽出（Phase 5）。Voxel 更新は知らない（読み取りのみ）。
    private var meshExtractor: MarchingCubesExtractor?
    /// エクスポート時のメッシュ後処理（リアルタイムとは独立）。
    let exportPipeline = ExportMeshPipeline()
    private let decimator = QEMDecimation()
    /// エクスポート時の三角形削減率（1.0=無効=フル解像度, 0.5=半分 ...）。
    var exportDecimateRatio: Float = 1.0
    private var meshFrameCounter = 0
    private let meshExtractInterval = 15   // ~1秒ごと（深度~15fps想定）

    // ICP Refinement（VIO 初期値の微調整。frame-to-model）。
    private let icpRefiner = ICPRefiner()
    /// ICP 姿勢補正の ON/OFF（既定 OFF。誤りやすいので任意）。
    var icpEnabled = false
    /// 整合ゲートの ON/OFF（既定 ON。既存メッシュと一致するフレームだけ統合）。
    var connectGate = true

    // SDF 平滑化（Phase 6, ボリューム空間）。マスターは破壊しない。
    private let smoother = TSDFSmoother()
    /// SDF 平滑化の ON/OFF（A/B 比較用）。
    var sdfSmoothEnabled = true

    /// 現在の追従状態（capture キューで更新）。normal のときだけ配置・統合する。
    private var currentTracking: ScanTrackingState = .notAvailable

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
        // エクスポート後処理（保存時のみ。リアルタイムには影響しない）。
        engine.exportPipeline.append(VertexWeld())        // 溶接でインデックス化
        engine.exportPipeline.append(TaubinSmoothing())   // λ/μ 平滑化
        engine.exportPipeline.append(engine.decimator)    // QEM 削減（既定は無効）
        // [Phase 7b-2+] HoleFilling / LOD をここに追加
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
        currentTracking = .notAvailable   // 再開時は追従が normal になるまで配置・統合しない
        meshFrameCounter = 0
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

    /// 抽出メッシュのバウンディング（軌道カメラのフレーミング用）。
    func currentMeshBounds() -> (center: SIMD3<Float>, radius: Float)? {
        meshExtractor?.readBounds()
    }

    /// 現在のメッシュを STL 化してドキュメントへ保存し、URL を返す（同期・要バックグラウンド）。
    /// エクスポートパイプライン（後処理）はここに差し込む（Phase 7b）。
    func exportSTL(binary: Bool, filename: String) -> URL? {
        guard let extractor = meshExtractor else { return nil }
        let soup = extractor.readbackPositions(context: context)
        guard soup.count >= 3 else { return nil }

        // エクスポート後処理（Weld→Taubin→QEM）。削減率を反映してから走らせる。
        decimator.targetRatio = exportDecimateRatio
        let processed = exportPipeline.run(CPUMesh(positions: soup, normals: [], indices: []))
        // インデックス付きなら三角形列へ展開、無ければ soup のまま。
        let outPositions: [SIMD3<Float>] = processed.indices.isEmpty
            ? processed.positions
            : processed.indices.map { processed.positions[Int($0)] }
        let data = STLExporter.data(positions: outPositions, binary: binary)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let name = filename.hasSuffix(".stl") ? filename : "\(filename).stl"
        let url = docs.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
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

        // TSDF 統合（追従が安定しているときだけ。不安定な姿勢での配置・統合を避ける）。
        if currentTracking == .normal, let tsdf {
            if !tsdf.isPositioned {
                tsdf.position(frontOf: frame.cameraToWorld,
                              distance: (config.depthMin + config.depthMax) * 0.5)
            }

            var integrateFrame = filtered
            var doIntegrate = true

            // 整合ゲート（姿勢は動かさない）: 既存モデルと重なる点が一致しないフレームは統合しない。
            // 重なりが少ない＝未観測の新領域なので統合（拡張）を許可する。
            if connectGate, tsdf.isPositioned {
                let ev = icpRefiner.evaluate(
                    depth: filtered.depth, mask: filtered.validMask, volume: tsdf,
                    intrinsics: filtered.intrinsics, width: filtered.width, height: filtered.height,
                    pose: filtered.cameraToWorld, config: config, context: context)
                if ev.observed >= config.gateMinOverlap {
                    let ratio = Float(ev.agree) / Float(ev.observed)
                    doIntegrate = ratio >= config.gateAgreeRatio
                    DispatchQueue.main.async { [weak self] in
                        self?.onICPStats?(ev.rms, ev.agree, doIntegrate)
                    }
                }
            }

            // 任意: ICP 姿勢補正（既定 OFF）。ゲート通過時のみ。
            if doIntegrate, icpEnabled, tsdf.isPositioned {
                let r = icpRefiner.refine(
                    depth: filtered.depth, mask: filtered.validMask, volume: tsdf,
                    intrinsics: filtered.intrinsics, width: filtered.width, height: filtered.height,
                    vioPose: filtered.cameraToWorld, config: config, context: context)
                switch r.status {
                case .ok: integrateFrame.cameraToWorld = r.pose
                case .poor: doIntegrate = false
                case .aborted: break
                }
            }

            if doIntegrate, let cb = context.commandQueue.makeCommandBuffer() {
                if sparseEnabled {
                    sparseIntegrator.integrate(integrateFrame, volume: tsdf, config: config,
                                               commandBuffer: cb, context: context)
                } else {
                    integrator.integrate(integrateFrame, volume: tsdf, config: config,
                                         commandBuffer: cb, context: context)
                }
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

            // Mesh 抽出（統合したフレームのみ・スロットル。Voxel 更新後に読むので順序は queue が保証）。
            if doIntegrate { meshFrameCounter += 1 }
            if doIntegrate, let extractor = meshExtractor, tsdf.isPositioned,
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
        currentTracking = trackingState   // capture キュー上。didOutput と同一キューで一貫
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
