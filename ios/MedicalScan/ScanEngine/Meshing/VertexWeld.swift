//
//  VertexWeld.swift
//  ScanEngine / Meshing
//
//  頂点溶接: vertex soup（重複頂点）を量子化グリッドでマージし、インデックス付きメッシュにする。
//  Taubin/HoleFilling/QEM など接続情報を要する後処理の前提。エクスポートパイプライン専用。
//
//  Marching Cubes の共有辺頂点は隣接セルから同一式で計算されるためほぼ同一値になる。
//  微小量子化（既定 1µm）で確実にマージする。
//

import simd

final class VertexWeld: MeshPostProcessor {

    let name = "VertexWeld"
    private let quantum: Float   // マージ用グリッド一辺 [m]

    init(quantum: Float = 1e-5) { self.quantum = quantum }

    func process(_ mesh: CPUMesh) -> CPUMesh {
        guard !mesh.positions.isEmpty else { return mesh }

        // 入力が soup（indices 空）なら連番インデックスとして扱う。
        let inIndices: [UInt32] = mesh.indices.isEmpty
            ? Array(0..<UInt32(mesh.positions.count))
            : mesh.indices

        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x / quantum).rounded()),
                         Int32((p.y / quantum).rounded()),
                         Int32((p.z / quantum).rounded()))
        }

        var map = [SIMD3<Int32>: UInt32]()
        map.reserveCapacity(mesh.positions.count / 2)
        var newPositions = [SIMD3<Float>]()
        var remap = [UInt32](repeating: 0, count: mesh.positions.count)

        for (i, p) in mesh.positions.enumerated() {
            let k = key(p)
            if let idx = map[k] {
                remap[i] = idx
            } else {
                let idx = UInt32(newPositions.count)
                map[k] = idx
                newPositions.append(p)
                remap[i] = idx
            }
        }

        // インデックスを張り替え、溶接で潰れた三角形は除去。
        var newIndices = [UInt32]()
        newIndices.reserveCapacity(inIndices.count)
        var t = 0
        while t + 2 < inIndices.count {
            let a = remap[Int(inIndices[t])]
            let b = remap[Int(inIndices[t + 1])]
            let c = remap[Int(inIndices[t + 2])]
            t += 3
            if a == b || b == c || a == c { continue }   // 退化
            newIndices.append(a); newIndices.append(b); newIndices.append(c)
        }

        return CPUMesh(positions: newPositions, normals: [], indices: newIndices)
    }
}
