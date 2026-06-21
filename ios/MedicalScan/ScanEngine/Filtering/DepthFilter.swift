//
//  DepthFilter.swift
//  ScanEngine / Filtering
//
//  深度フィルタの抽象と、それを順に適用するチェーン。
//  Confidence / Bilateral / Temporal などを「追加するだけ」で拡張できる構造（Phase 3 で実装）。
//
//  設計意図:
//   - 各フィルタは 1 つの commandBuffer に encode し、入力 DepthFrame を受けて
//     （多くは depth テクスチャを差し替えた）新しい DepthFrame を返す純粋な変換とする。
//   - チェーンは順序付きリスト。TSDF integrate はこのチェーンの出力を受け取る位置に入るため、
//     フィルタを増減しても下流は無変更（Open/Closed）。
//

import Metal

/// 深度フレームを GPU 上で変換する 1 段。
protocol DepthFilter: AnyObject {
    /// フィルタ名（デバッグ/プロファイル用）。
    var name: String { get }

    /// `frame` を変換して返す。GPU 処理は `commandBuffer` に encode する（commit はチェーン側）。
    /// 出力テクスチャは `context.texturePool` から借りること（再確保を避ける）。
    func process(_ frame: DepthFrame,
                 commandBuffer: MTLCommandBuffer,
                 context: MetalContext) -> DepthFrame
}

/// フィルタを順に適用するパイプライン。
final class DepthFilterChain {

    private(set) var filters: [DepthFilter] = []

    /// 末尾に追加（適用順 = 追加順）。
    func append(_ filter: DepthFilter) { filters.append(filter) }

    /// すべて削除。
    func removeAll() { filters.removeAll() }

    var isEmpty: Bool { filters.isEmpty }

    /// チェーンを適用。空なら入力をそのまま返す（GPU 処理なし）。
    func process(_ frame: DepthFrame,
                 commandBuffer: MTLCommandBuffer,
                 context: MetalContext) -> DepthFrame {
        var current = frame
        for filter in filters {
            current = filter.process(current, commandBuffer: commandBuffer, context: context)
        }
        return current
    }
}
