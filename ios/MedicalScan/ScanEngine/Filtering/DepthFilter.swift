//
//  DepthFilter.swift
//  ScanEngine / Filtering
//
//  深度フィルタの抽象と、それを順に適用するチェーン。
//  各フィルタは enabled / priority / name を持ち、append / remove / reorder 可能。
//
//  GPU 計測方針（確定）: per-filter の GPU 時間を取るため、フィルタごとに専用 command buffer を
//  生成して commit する。同一 command queue 上で commit 順に直列実行されるため、前段の出力テクスチャ
//  への書き込みは後段の読み取り前に完了する（リソースハザードは順序保証で安全）。
//  GPU 時間は completion handler で gpuEndTime-gpuStartTime を読み、onFilterGPUTime で通知する。
//

import Metal
import QuartzCore

/// 深度フレームを GPU 上で変換する 1 段。
protocol DepthFilter: AnyObject {
    /// 表示・計測用の名前。
    var name: String { get }
    /// 無効化すると process でスキップされる。
    var isEnabled: Bool { get set }
    /// 適用順（小さいほど先）。Confidence=10, Bilateral=20, Temporal=30 を想定。
    var priority: Int { get }

    /// `frame` を変換し、与えられた `commandBuffer` に GPU 処理を encode して返す。
    /// 出力テクスチャは解像度変化時のみ確保して使い回す（毎フレーム確保を避ける）。
    func encode(_ frame: DepthFrame,
                commandBuffer: MTLCommandBuffer,
                context: MetalContext) -> DepthFrame

    /// 内部状態（履歴等）を破棄する。状態を持たないフィルタは既定の空実装でよい。
    func reset()
}

extension DepthFilter {
    func reset() {}
}

/// フィルタを優先度順に適用するパイプライン。
final class DepthFilterChain {

    private var filters: [DepthFilter] = []

    /// per-filter の GPU 時間[ms] 通知（completion handler から呼ぶ＝バックグラウンドスレッド）。
    var onFilterGPUTime: ((_ name: String, _ ms: Double) -> Void)?

    // MARK: - 構成変更

    func append(_ filter: DepthFilter) { filters.append(filter) }

    func remove(named name: String) { filters.removeAll { $0.name == name } }

    func filter(named name: String) -> DepthFilter? { filters.first { $0.name == name } }

    /// 有効/無効の切替（存在しなければ無視）。
    func setEnabled(_ enabled: Bool, for name: String) {
        filters.first { $0.name == name }?.isEnabled = enabled
    }

    func removeAll() { filters.removeAll() }

    /// 全フィルタの内部状態を破棄（スキャン開始/リセット時に呼ぶ）。
    func reset() { filters.forEach { $0.reset() } }

    var isEmpty: Bool { filters.isEmpty }

    // MARK: - 適用

    /// 有効フィルタを priority 昇順で適用。各フィルタは専用 command buffer で encode/commit する。
    func process(_ frame: DepthFrame, context: MetalContext) -> DepthFrame {
        let active = filters.filter { $0.isEnabled }.sorted { $0.priority < $1.priority }
        var current = frame
        for filter in active {
            guard let cb = context.commandQueue.makeCommandBuffer() else { continue }
            cb.label = filter.name
            current = filter.encode(current, commandBuffer: cb, context: context)
            let name = filter.name
            cb.addCompletedHandler { [weak self] buffer in
                let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
                self?.onFilterGPUTime?(name, ms)
            }
            cb.commit()
        }
        return current
    }
}
