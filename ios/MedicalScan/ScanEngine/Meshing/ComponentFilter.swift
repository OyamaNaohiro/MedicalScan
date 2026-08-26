//
//  ComponentFilter.swift
//  ScanEngine / Meshing
//
//  連結成分フィルタ（エクスポート後処理）。頂点溶接後のメッシュを連結成分へ分け、
//  本体（最大成分）と、それに準ずる大きさの成分だけを残す。
//
//  目的: スキャン中にドリフトや誤トラッキングで本体からズレて育った「ゴースト／二重メッシュ」を消す。
//  ゴーストは本体から空間的に分離した別の連結成分になるため、最大成分基準で足切りできる。
//
//  重要: VertexWeld の後（隣接が構築済み）・HoleFilling の前に適用すること。
//  溶接前は頂点スープ（全三角形が別成分）なので機能しない。
//

import simd

final class ComponentFilter: MeshPostProcessor {

    let name = "ComponentFilter"

    /// 最大成分の三角形数に対する保持比（0..1）。これ未満の成分は削除する。
    /// 0.5 = 最大成分の 50% 未満の成分（＝小さめのゴースト・浮遊片）を削除。
    /// 1.0 に近づけるほど厳しく（本体だけ残す）。
    var keepRatio: Float

    init(keepRatio: Float = 0.5) { self.keepRatio = keepRatio }

    func process(_ mesh: CPUMesh) -> CPUMesh {
        let vcount = mesh.positions.count
        guard vcount > 0, mesh.indices.count >= 3 else { return mesh }

        // Union-Find（頂点単位。経路圧縮）。
        var parent = Array(0..<vcount)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        let idx = mesh.indices
        var t = 0
        while t + 2 < idx.count {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            union(a, b); union(b, c)   // a-b-c を同一成分へ
            t += 3
        }

        // 成分ごとの三角形数。
        var triCount: [Int: Int] = [:]
        t = 0
        while t + 2 < idx.count {
            triCount[find(Int(idx[t])), default: 0] += 1
            t += 3
        }
        guard let maxTris = triCount.values.max(), maxTris > 0 else { return mesh }

        // 残す成分（最大成分の keepRatio 以上）。
        let threshold = Int(Float(maxTris) * max(0, min(1, keepRatio)))
        var keepRoots = Set<Int>()
        for (root, n) in triCount where n >= threshold { keepRoots.insert(root) }
        guard !keepRoots.isEmpty, keepRoots.count < triCount.count else { return mesh }  // 全部残るなら無変更

        // 残す三角形の頂点だけをリマップして再構築。
        let hasColor = mesh.hasColor
        let hasNormal = mesh.normals.count == vcount
        var remap = [Int32](repeating: -1, count: vcount)
        var newPositions: [SIMD3<Float>] = []
        var newColors: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var newIndices: [UInt32] = []

        t = 0
        while t + 2 < idx.count {
            let tri = [Int(idx[t]), Int(idx[t + 1]), Int(idx[t + 2])]
            if keepRoots.contains(find(tri[0])) {
                for v in tri {
                    if remap[v] < 0 {
                        remap[v] = Int32(newPositions.count)
                        newPositions.append(mesh.positions[v])
                        if hasColor { newColors.append(mesh.colors[v]) }
                        if hasNormal { newNormals.append(mesh.normals[v]) }
                    }
                    newIndices.append(UInt32(remap[v]))
                }
            }
            t += 3
        }
        return CPUMesh(positions: newPositions, normals: newNormals,
                       colors: newColors, indices: newIndices)
    }
}
