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
    /// ブロックスパース統合（Phase 8）。検証済みのため既定 ON（密版は toggle でフォールバック可）。
    var sparseEnabled = true
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
    /// メッシュ抽出間隔（フレーム数）。ライブ表示中は頻度を上げて成長を滑らかに見せる。
    private var meshExtractInterval: Int { liveMode ? 5 : 15 }
    /// ライブ表示モード（AR オーバーレイ/3D表示中）。カラー取得と高頻度メッシュを有効化。
    var liveMode = false {
        didSet {
            guard liveMode != oldValue else { return }
            updateColorCapture()
        }
    }

    /// カラー焼き込みの ON/OFF。ON でカメラ映像をボクセルへ蓄積し、メッシュに頂点カラーを出力する。
    var colorBakingEnabled = false {
        didSet {
            meshExtractor?.colorEnabled = colorBakingEnabled
            updateColorCapture()
        }
    }

    /// カラー取得は「ライブ表示」または「カラー焼き込み」のどちらかが有効なら ON。
    private func updateColorCapture() {
        source.setColorCapture(liveMode || colorBakingEnabled)
    }
    /// 表示ビューのサイズ[pt]（ARKit 投影/表示変換に使用）。
    var previewViewport: CGSize = .zero {
        didSet { source.setViewport(previewViewport) }
    }

    /// ワールドトラッキング（6DOF 姿勢）の ON/OFF。既定 ON。スキャン開始前に設定する
    /// （OFF は前面トラッキング＋IMU のみになり、端末を大きく動かす撮影では姿勢精度が落ちる）。
    var worldTrackingEnabled = true {
        didSet { source.setWorldTracking(worldTrackingEnabled) }
    }

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

    // 大域最適化（エクスポート専用・リアルタイムと分離）。
    /// キーフレーム間引き・ループ検出・PGO のパラメータ。
    let globalOptConfig = GlobalOptConfig()
    /// スキャン中にキーフレームを間引き保持する（有効時のみ・60fps を犠牲にしない）。
    private(set) lazy var keyframeRecorder = KeyframeRecorder(config: globalOptConfig)
    /// エクスポート時の大域最適化パイプライン（検出→PGO→再統合→再メッシュ）。
    private let globalOptPipeline = GlobalOptimizationPipeline()
    /// 大域最適化の ON/OFF。ON にするとスキャン中にキーフレームを保持し、保存時に大域最適化する。
    /// 既定 OFF（キーフレーム保持もしない＝コストゼロ）。スキャン開始前に設定する。
    var globalOptimizationEnabled = false {
        didSet { keyframeRecorder.enabled = globalOptimizationEnabled }
    }

    /// 現在の追従状態（capture キューで更新）。normal のときだけ配置・統合する。
    private var currentTracking: ScanTrackingState = .notAvailable

    /// 現在のスキャンモード（対象サイズ別プリセット）。既定は上半身（従来値）。
    private(set) var scanMode: ScanMode = .upperBody

    // 深度オドメトリ主軸（ICP をフレーム→モデルの主トラッカーにし、姿勢を累積する）。
    /// ON で深度オドメトリを主軸にする（ARKit は相対運動 prior のみ。長期ドリフトから独立）。既定 OFF。
    var depthOdometryEnabled = false
    /// 累積トラッキング姿勢（ICP 補正を積む）。
    private var odomTrackedPose = matrix_identity_float4x4
    /// ARKit 相対運動 prior 用の前フレーム ARKit 姿勢。
    private var odomArkitPrev = matrix_identity_float4x4

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

    /// 指定センサーをソースとし、標準フィルタ（Confidence）を組み込んで構築する。
    /// - Parameter sensor: .trueDepth（前面・既定）/ .lidar（背面 sceneDepth）。
    static func makeDefault(sensor: ScanSensor = .trueDepth,
                            config: ScanConfig = ScanConfig()) -> ScanEngine? {
        guard let context = MetalContext() else { return nil }
        let source: DepthFrameSource = (sensor == .lidar)
            ? LiDARSource(context: context)
            : TrueDepthSource(context: context)
        let engine = ScanEngine(context: context, source: source, config: config)
        engine.filterChain.append(ConfidenceFilter(config: config))  // priority 10
        engine.filterChain.append(BilateralFilter(config: config))   // priority 20
        engine.filterChain.append(TemporalFilter(config: config))    // priority 30
        engine.tsdf = TSDFVolume(device: context.device,
                                 voxelSize: config.voxelSize, extent: config.volumeExtent)
        engine.meshExtractor = MarchingCubesExtractor(device: context.device)
        // エクスポート後処理（保存時のみ。リアルタイムには影響しない）。
        engine.exportPipeline.append(VertexWeld())        // 溶接でインデックス化
        engine.exportPipeline.append(HoleFilling())       // 小さな穴を塞ぐ（境界検出→重心ファン）
        engine.exportPipeline.append(TaubinSmoothing())   // λ/μ 平滑化（穴埋め後に馴染ませる）
        engine.exportPipeline.append(engine.decimator)    // QEM 削減（既定は無効）
        // [Phase 7b-2+] LOD をここに追加
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
        odomTrackedPose = matrix_identity_float4x4   // 深度オドメトリの累積姿勢をリセット
        odomArkitPrev = matrix_identity_float4x4
        keyframeRecorder.reset()          // 大域最適化用キーフレームを破棄（有効時のみ蓄積）
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

    /// スキャン対象モード（手/足/上半身）を適用する。
    /// voxelSize・volumeExtent・深度レンジを一括で切り替え、TSDF ボリュームを新解像度で作り直す。
    /// ボリューム再確保はスキャン中に行うと危険なので、実行中は無視する（RN 側でも開始中は非活性）。
    func applyMode(_ mode: ScanMode) {
        if case .running = state { return }   // 実行中は切替不可（停止してから）
        guard mode != scanMode || tsdf == nil else { return }

        scanMode = mode
        var newConfig = mode.makeConfig()
        if source.sensor == .lidar { newConfig.applyLiDARProfile() }   // LiDAR はノイズ・ドリフト大 → 厚い融合帯
        config = newConfig
        // 深度レンジ変更を ConfidenceFilter（有効マスク生成）へ反映。
        filterChain.updateConfig(newConfig)
        // TSDF ボリュームを新しい voxelSize/extent で作り直す。
        // 失敗（メモリ上限超過）時は従来ボリュームを維持する。
        if let volume = TSDFVolume(device: context.device,
                                   voxelSize: newConfig.voxelSize, extent: newConfig.volumeExtent) {
            tsdf = volume
        }
        let voxelMm = String(format: "%.1f", newConfig.voxelSize * 1000)
        onEvent?("mode", "モード: \(mode.label)（voxel \(voxelMm)mm）")
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

    /// 現在のメッシュをファイル化してドキュメントへ保存し、URL を返す（同期・要バックグラウンド）。
    /// - Parameters:
    ///   - format: 0=STL binary, 1=STL ascii, 2=PLY(binary・頂点カラー付き)
    ///   - globalOptimize: true かつキーフレームがあれば大域最適化→再統合→再メッシュしてから後処理。
    func exportMesh(format: Int, filename: String, globalOptimize: Bool = false) -> URL? {
        guard let extractor = meshExtractor else { return nil }
        let ply = (format == 2)
        let binary = (format != 1)   // STL ascii のみ非バイナリ

        // 頂点（位置＋カラー）の取得元。大域最適化 ON なら再生成、それ以外は現在のメッシュ。
        var soup: [SIMD3<Float>]
        var soupColors: [SIMD3<Float>]
        if globalOptimize, keyframeRecorder.store.count >= 2,
           let regenerated = globalOptPipeline.run(frames: keyframeRecorder.store.snapshot(),
                                                    config: config, gConfig: globalOptConfig,
                                                    context: context) {
            soup = regenerated.positions
            soupColors = regenerated.colors   // 再メッシュは現状無色
            let s = globalOptPipeline.lastStats
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?("globalOpt",
                    "大域最適化: KF \(s.keyframes) / ループ候補 \(s.loopCandidates) / 補正 \(s.correctionApplied ? "有" : "無") / 三角形 \(s.triangles)")
            }
        } else {
            let m = extractor.readbackMesh(context: context)
            soup = m.positions
            soupColors = m.colors
        }
        guard soup.count >= 3 else { return nil }

        // 無色センチネル(負値)はグレーへ寄せてから後処理（溶接の色平均が壊れないように）。
        let gray = SIMD3<Float>(0.7, 0.76, 0.85)
        let colors: [SIMD3<Float>] = soupColors.count == soup.count
            ? soupColors.map { $0.x < 0 ? gray : $0 } : []

        // エクスポート後処理（Weld→HoleFilling→Taubin→QEM）。カラーも段を通して引き継がれる。
        decimator.targetRatio = exportDecimateRatio
        let processed = exportPipeline.run(CPUMesh(positions: soup, normals: [],
                                                   colors: colors, indices: []))

        let ext = ply ? "ply" : "stl"
        let data: Data
        if ply {
            data = PLYExporter.data(positions: processed.positions, colors: processed.colors,
                                    indices: processed.indices, binary: true)
        } else {
            let outPositions: [SIMD3<Float>] = processed.indices.isEmpty
                ? processed.positions
                : processed.indices.map { processed.positions[Int($0)] }
            data = STLExporter.data(positions: outPositions, binary: binary)
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let name = filename.hasSuffix(".\(ext)") ? filename : "\(filename).\(ext)"
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

    // MARK: - 深度オドメトリ主軸トラッカー

    /// ICP をフレーム→モデルの主基準にして姿勢を累積する（ARKit は相対運動 prior のみ）。
    /// 累積姿勢は ICP 補正を積むため、ARKit の長期ドリフトから独立する。
    /// - Returns: (統合に使う姿勢, 統合するか)。
    private func trackDepthOdometry(_ frame: DepthFrame,
                                    tsdf: TSDFVolume) -> (pose: simd_float4x4, integrate: Bool) {
        let arkit = frame.cameraToWorld

        // ブートストラップ: 最初のフレームで世界基準を定め、ボリュームを配置して統合。
        if !tsdf.isPositioned {
            odomTrackedPose = arkit
            odomArkitPrev = arkit
            tsdf.position(frontOf: arkit, distance: (config.depthMin + config.depthMax) * 0.5)
            return (arkit, true)
        }

        // 予測: 前トラッキング姿勢に ARKit の相対運動（短期は頑健）を合成。
        let arkitDelta = odomArkitPrev.inverse * arkit
        let predicted = odomTrackedPose * arkitDelta
        odomArkitPrev = arkit

        // ICP をフレーム→モデルで実行（予測を初期値）。
        let r = icpRefiner.refine(
            depth: frame.depth, mask: frame.validMask, volume: tsdf,
            intrinsics: frame.intrinsics, width: frame.width, height: frame.height,
            vioPose: predicted, config: config, context: context)

        switch r.status {
        case .ok:
            // 整合良好 → ICP 補正姿勢を採用（深度が真値）。
            odomTrackedPose = r.pose
            DispatchQueue.main.async { [weak self] in self?.onICPStats?(r.rms, r.correspondences, true) }
            return (odomTrackedPose, true)
        case .aborted:
            // モデル不足（初期）→ 予測姿勢で統合してモデルを育てる。
            odomTrackedPose = predicted
            return (predicted, true)
        case .poor:
            // 整合不良 → 予測姿勢は保持するが統合はスキップ（モデル保護）。
            odomTrackedPose = predicted
            DispatchQueue.main.async { [weak self] in self?.onICPStats?(r.rms, r.correspondences, false) }
            return (predicted, false)
        }
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

        // TSDF 統合。姿勢の決め方はモードで分岐し、統合/メッシュ処理は共通化する。
        if let tsdf {
            var proceed = false
            var integrateFrame = filtered
            var doIntegrate = true

            if depthOdometryEnabled {
                // 深度オドメトリ主軸: ICP をフレーム→モデルの主基準にして姿勢を累積。
                let (pose, integ) = trackDepthOdometry(filtered, tsdf: tsdf)
                integrateFrame.cameraToWorld = pose
                doIntegrate = integ
                proceed = true
            } else if currentTracking == .normal {
                // VIO 主軸（従来）: 追従が安定しているときだけ配置・統合。
                if !tsdf.isPositioned {
                    tsdf.position(frontOf: frame.cameraToWorld,
                                  distance: (config.depthMin + config.depthMax) * 0.5)
                }

                var vioRms: Float = .infinity   // VIO 姿勢での整合残差（ICP 改善判定の基準）

                // 整合ゲート（姿勢は動かさない）＆ ICP 用の基準残差を取得。
                if tsdf.isPositioned, (connectGate || icpEnabled) {
                    let ev = icpRefiner.evaluate(
                        depth: filtered.depth, mask: filtered.validMask, volume: tsdf,
                        intrinsics: filtered.intrinsics, width: filtered.width, height: filtered.height,
                        pose: filtered.cameraToWorld, config: config, context: context)
                    vioRms = ev.rms
                    if connectGate, ev.observed >= config.gateMinOverlap {
                        let ratio = Float(ev.agree) / Float(ev.observed)
                        doIntegrate = ratio >= config.gateAgreeRatio
                        DispatchQueue.main.async { [weak self] in
                            self?.onICPStats?(ev.rms, ev.agree, doIntegrate)
                        }
                    }
                }

                // ICP 姿勢補正（任意）: VIO より整合が良くなる時だけ採用。
                if doIntegrate, icpEnabled, tsdf.isPositioned {
                    let r = icpRefiner.refine(
                        depth: filtered.depth, mask: filtered.validMask, volume: tsdf,
                        intrinsics: filtered.intrinsics, width: filtered.width, height: filtered.height,
                        vioPose: filtered.cameraToWorld, config: config, context: context)
                    if r.status == .ok, r.rms < vioRms {
                        integrateFrame.cameraToWorld = r.pose
                    }
                }
                proceed = true
            }

            if proceed {

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

            // 大域最適化用キーフレーム保持（有効時のみ・間引き。深度は raw 所有テクスチャを参照保持）。
            // 姿勢は統合に使った pose（ICP 補正後含む）。リアルタイム経路への影響は無効時ゼロ。
            if doIntegrate {
                keyframeRecorder.consider(depth: frame.depth, pose: integrateFrame.cameraToWorld,
                                          intrinsics: frame.intrinsics,
                                          width: frame.width, height: frame.height,
                                          timestamp: frame.timestamp)
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
            }   // if proceed
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
