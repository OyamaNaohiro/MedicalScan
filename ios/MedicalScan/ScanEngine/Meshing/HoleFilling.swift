//
//  HoleFilling.swift
//  ScanEngine / Meshing
//
//  境界（穴）検出→小さな穴を重心ファンで塞ぐ後処理（エクスポート専用・CPU・インデックス付き前提）。
//
//  仕組み:
//   - 有向ハーフエッジ集合を作り、逆向きが存在しない有向辺＝境界辺を抽出する。
//     （多様体+境界では、内部辺は 2 三角形から u→v と v→u の対で現れ、境界辺は片側のみ。）
//   - 境界辺を u→v で連結して穴のループを辿る。
//   - 辺数が閾値以下の小さなループだけ、重心を追加して三角形ファンで塞ぐ。
//     （スキャンで開いている大きな面＝辺数の多いループは塞がず残す。）
//
//  巻き方向: 既存三角形が u→v を持つので、穴側は逆の v→u。塞ぐ三角形は (v, u, C) とし、
//  既存サーフェスと一貫した外向き法線を保つ（VertexWeld の後・TaubinSmoothing の前に適用）。
//

import simd

final class HoleFilling: MeshPostProcessor {

    let name = "HoleFilling"

    /// この境界辺数以下の穴だけ塞ぐ（大きな開口はスキャンの開いた面として残す）。
    private let maxHoleEdges: Int

    init(maxHoleEdges: Int = 30) { self.maxHoleEdges = maxHoleEdges }

    private struct DEdge: Hashable { var a: UInt32; var b: UInt32 }

    func process(_ mesh: CPUMesh) -> CPUMesh {
        guard mesh.indices.count >= 3 else { return mesh }
        let idx = mesh.indices

        // 1) 有向ハーフエッジ集合。
        var dirSet = Set<DEdge>()
        dirSet.reserveCapacity(idx.count)
        var i = 0
        while i + 2 < idx.count {
            let a = idx[i], b = idx[i + 1], c = idx[i + 2]
            i += 3
            dirSet.insert(DEdge(a: a, b: b))
            dirSet.insert(DEdge(a: b, b: c))
            dirSet.insert(DEdge(a: c, b: a))
        }

        // 2) 境界辺（逆向きが無い有向辺）から u→v の連結表を作る。
        //    多重境界頂点（非多様体）は簡易に最初の 1 本のみ採用する。
        var nextOf = [UInt32: UInt32]()
        for e in dirSet where !dirSet.contains(DEdge(a: e.b, b: e.a)) {
            if nextOf[e.a] == nil { nextOf[e.a] = e.b }
        }
        guard !nextOf.isEmpty else { return mesh }

        // 3) ループを辿り、小さな穴を重心ファンで塞ぐ。
        var positions = mesh.positions
        var newIndices = mesh.indices
        var visited = Set<UInt32>()
        var filled = 0

        for start in nextOf.keys {
            if visited.contains(start) { continue }

            var loop = [UInt32]()
            var cur = start
            var closed = false
            while true {
                if visited.contains(cur) {
                    closed = (cur == start)   // 開始点へ戻れば閉ループ
                    break
                }
                visited.insert(cur)
                loop.append(cur)
                guard let nxt = nextOf[cur] else { break }   // 行き止まり（非多様体）
                cur = nxt
                if loop.count > maxHoleEdges + 1 { break }    // 大きすぎる→スキップ
            }

            guard closed, loop.count >= 3, loop.count <= maxHoleEdges else { continue }

            var centroid = SIMD3<Float>(repeating: 0)
            for v in loop { centroid += positions[Int(v)] }
            centroid /= Float(loop.count)
            let cIdx = UInt32(positions.count)
            positions.append(centroid)

            for k in 0..<loop.count {
                let u = loop[k]
                let v = loop[(k + 1) % loop.count]
                // 既存が u→v なので穴側は v→u。三角形 (v, u, C)。
                newIndices.append(v); newIndices.append(u); newIndices.append(cIdx)
            }
            filled += 1
        }

        guard filled > 0 else { return mesh }
        return CPUMesh(positions: positions, normals: [], indices: newIndices)
    }
}
