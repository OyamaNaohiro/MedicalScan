//
//  TaubinSmoothing.swift
//  ScanEngine / Meshing
//
//  Taubin λ/μ スムージング（エクスポート専用・CPU・インデックス付きメッシュ前提）。
//  数学: Laplacian 平滑化を λ(>0) と μ(<0, |μ|>λ) で交互に行う。
//   p ← p + λ(L p),  p ← p + μ(L p)
//  λ だけだと収縮するが、μ の反収縮で体積を保ちつつ高周波ノイズを除去する。
//  リアルタイムには使わず、保存時のみ適用（責務分離）。
//

import simd

final class TaubinSmoothing: MeshPostProcessor {

    let name = "TaubinSmoothing"
    private let iterations: Int
    private let lambda: Float
    private let mu: Float

    init(iterations: Int = 5, lambda: Float = 0.5, mu: Float = -0.53) {
        self.iterations = iterations
        self.lambda = lambda
        self.mu = mu
    }

    func process(_ mesh: CPUMesh) -> CPUMesh {
        guard !mesh.indices.isEmpty, mesh.positions.count > 2 else { return mesh }

        // 隣接（1リング）を構築。
        var adjacency = [Set<UInt32>](repeating: [], count: mesh.positions.count)
        var t = 0
        let idx = mesh.indices
        while t + 2 < idx.count {
            let a = idx[t], b = idx[t + 1], c = idx[t + 2]
            t += 3
            adjacency[Int(a)].insert(b); adjacency[Int(a)].insert(c)
            adjacency[Int(b)].insert(a); adjacency[Int(b)].insert(c)
            adjacency[Int(c)].insert(a); adjacency[Int(c)].insert(b)
        }

        var pos = mesh.positions

        func smoothStep(_ factor: Float) {
            var next = pos
            for i in 0..<pos.count {
                let nb = adjacency[i]
                guard !nb.isEmpty else { continue }
                var avg = SIMD3<Float>(repeating: 0)
                for j in nb { avg += pos[Int(j)] }
                avg /= Float(nb.count)
                next[i] = pos[i] + factor * (avg - pos[i])   // L p = avg - p
            }
            pos = next
        }

        for _ in 0..<iterations {
            smoothStep(lambda)
            smoothStep(mu)
        }

        // 頂点法線を面積重み付きで再計算。
        var normals = [SIMD3<Float>](repeating: .zero, count: pos.count)
        t = 0
        while t + 2 < idx.count {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            t += 3
            let n = simd_cross(pos[b] - pos[a], pos[c] - pos[a])  // 長さ=面積×2（重み）
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        for i in 0..<normals.count {
            let l = simd_length(normals[i])
            if l > 1e-12 { normals[i] /= l }
        }

        // カラーは頂点順・数を保つのでそのまま引き継ぐ。
        return CPUMesh(positions: pos, normals: normals, colors: mesh.colors, indices: mesh.indices)
    }
}
