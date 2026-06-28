//
//  QEMDecimation.swift
//  ScanEngine / Meshing
//
//  Quadric Error Metrics（Garland-Heckbert 1997）による三角形削減（エクスポート専用・CPU）。
//  各頂点に隣接面の平面クアドリック Q を集積し、エッジ collapse のコスト＝統合クアドリックの
//  二次誤差で評価する。コストの小さい辺から union-find で統合して頂点数を減らす。
//
//  完全な逐次 QEM（優先度キュー＋接続更新）より単純で堅牢な実装。組成情報の破綻を避けるため、
//  union-find による頂点クラスタリング方式（コスト順処理）を採る。リアルタイムには使わない。
//

import simd

/// 対称 4x4 クアドリック（10 係数）。誤差 = vᵀ Q v（v=(x,y,z,1)）。
private struct Quadric {
    var a: Float = 0, b: Float = 0, c: Float = 0, d: Float = 0
    var e: Float = 0, f: Float = 0, g: Float = 0
    var h: Float = 0, i: Float = 0
    var j: Float = 0

    /// 平面 (n, dd)（dd = -n·p）からクアドリックを作る。
    init(plane n: SIMD3<Float>, _ dd: Float) {
        a = n.x * n.x; b = n.x * n.y; c = n.x * n.z; d = n.x * dd
        e = n.y * n.y; f = n.y * n.z; g = n.y * dd
        h = n.z * n.z; i = n.z * dd
        j = dd * dd
    }
    init() {}

    mutating func add(_ q: Quadric) {
        a += q.a; b += q.b; c += q.c; d += q.d
        e += q.e; f += q.f; g += q.g
        h += q.h; i += q.i; j += q.j
    }

    func error(_ v: SIMD3<Float>) -> Float {
        let x = v.x, y = v.y, z = v.z
        return a*x*x + 2*b*x*y + 2*c*x*z + 2*d*x
             + e*y*y + 2*f*y*z + 2*g*y
             + h*z*z + 2*i*z + j
    }

    /// 二次誤差を最小化する位置（特異なら fallback）。
    func optimalPosition(fallback: SIMD3<Float>) -> SIMD3<Float> {
        let m = simd_float3x3(SIMD3<Float>(a, b, c),
                              SIMD3<Float>(b, e, f),
                              SIMD3<Float>(c, f, h))
        if abs(simd_determinant(m)) < 1e-10 { return fallback }
        return m.inverse * SIMD3<Float>(-d, -g, -i)
    }
}

final class QEMDecimation: MeshPostProcessor {

    let name = "QEMDecimation"
    /// 残す三角形の割合（1.0=無効, 0.5=半分, 0.25=1/4 ...）。
    var targetRatio: Float

    init(targetRatio: Float = 1.0) { self.targetRatio = targetRatio }

    func process(_ mesh: CPUMesh) -> CPUMesh {
        let triCount = mesh.indices.count / 3
        guard targetRatio < 0.999, triCount > 200, mesh.positions.count > 4 else { return mesh }
        let targetTri = max(100, Int(Float(triCount) * targetRatio))
        let collapsesNeeded = max(0, (triCount - targetTri) / 2)
        guard collapsesNeeded > 0 else { return mesh }

        var pos = mesh.positions
        let n = pos.count
        let idx = mesh.indices

        // 1. 頂点クアドリック。
        var quad = [Quadric](repeating: Quadric(), count: n)
        var t = 0
        while t + 2 < idx.count {
            let ia = Int(idx[t]), ib = Int(idx[t + 1]), ic = Int(idx[t + 2]); t += 3
            let p0 = pos[ia], p1 = pos[ib], p2 = pos[ic]
            var nrm = simd_cross(p1 - p0, p2 - p0)
            let len = simd_length(nrm)
            if len > 1e-12 {
                nrm /= len
                let q = Quadric(plane: nrm, -simd_dot(nrm, p0))
                quad[ia].add(q); quad[ib].add(q); quad[ic].add(q)
            }
        }

        // 2. ユニーク辺＋コスト。
        struct Edge { var cost: Float; var u: Int; var v: Int }
        var seen = Set<UInt64>()
        var edges = [Edge]()
        edges.reserveCapacity(idx.count)
        func keyOf(_ x: Int, _ y: Int) -> UInt64 { UInt64(min(x, y)) << 32 | UInt64(max(x, y)) }
        func costOf(_ x: Int, _ y: Int) -> Float {
            var q = quad[x]; q.add(quad[y])
            let target = q.optimalPosition(fallback: (pos[x] + pos[y]) * 0.5)
            return q.error(target)
        }
        t = 0
        while t + 2 < idx.count {
            let ia = Int(idx[t]), ib = Int(idx[t + 1]), ic = Int(idx[t + 2]); t += 3
            for (x, y) in [(ia, ib), (ib, ic), (ic, ia)] {
                let k = keyOf(x, y)
                if seen.insert(k).inserted {
                    edges.append(Edge(cost: costOf(x, y), u: min(x, y), v: max(x, y)))
                }
            }
        }
        edges.sort { $0.cost < $1.cost }

        // 3. union-find でコスト順に統合。
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        var collapses = 0
        for edge in edges {
            if collapses >= collapsesNeeded { break }
            let ru = find(edge.u), rv = find(edge.v)
            if ru == rv { continue }
            var q = quad[ru]; q.add(quad[rv])
            let target = q.optimalPosition(fallback: (pos[ru] + pos[rv]) * 0.5)
            parent[rv] = ru
            quad[ru] = q
            pos[ru] = target
            collapses += 1
        }

        // 4. 再構築（root をコンパクト化、退化三角形除去、法線再計算）。
        var rootRemap = [Int: UInt32]()
        var newPos = [SIMD3<Float>]()
        func mapped(_ x: Int) -> UInt32 {
            let r = find(x)
            if let m = rootRemap[r] { return m }
            let m = UInt32(newPos.count); rootRemap[r] = m; newPos.append(pos[r]); return m
        }
        var newIdx = [UInt32]()
        t = 0
        while t + 2 < idx.count {
            let a = mapped(Int(idx[t])), b = mapped(Int(idx[t + 1])), c = mapped(Int(idx[t + 2])); t += 3
            if a == b || b == c || a == c { continue }
            newIdx.append(a); newIdx.append(b); newIdx.append(c)
        }

        var normals = [SIMD3<Float>](repeating: .zero, count: newPos.count)
        t = 0
        while t + 2 < newIdx.count {
            let a = Int(newIdx[t]), b = Int(newIdx[t + 1]), c = Int(newIdx[t + 2]); t += 3
            let nrm = simd_cross(newPos[b] - newPos[a], newPos[c] - newPos[a])
            normals[a] += nrm; normals[b] += nrm; normals[c] += nrm
        }
        for k in 0..<normals.count {
            let l = simd_length(normals[k])
            if l > 1e-12 { normals[k] /= l }
        }

        return CPUMesh(positions: newPos, normals: normals, indices: newIdx)
    }
}
