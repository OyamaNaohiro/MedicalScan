//
//  MeshPostProcessor.swift
//  ScanEngine / Meshing
//
//  エクスポート（STL 等）パイプライン用のメッシュ後処理「拡張点」。
//
//  設計方針（Phase 6 で確定）:
//   - リアルタイム表示パイプライン: GPU の頂点スープ（接続なし）。SDF 平滑化で品質確保。
//   - エクスポートパイプライン: CPU 側のインデックス付きメッシュに対し、重い高品質処理を段階適用。
//  この 2 つを分離し、それぞれ独立に最適化できるようにする。
//
//  Phase 7 以降で以下の MeshPostProcessor を実装して `ExportMeshPipeline.stages` に積む:
//   - VertexWeld（頂点溶接＝重複頂点をマージしインデックス化・隣接構築）
//   - TaubinSmoothing（λ/μ 平滑化、収縮を打ち消す）
//   - HoleFilling（境界エッジ検出→穴埋め）
//   - QEMDecimation（Quadric Error Metrics による頂点削減）
//   - LODGeneration（多段解像度）
//  本フェーズでは構造のみ定義し、具体段は実装しない（リアルタイム性能優先）。
//

import simd

/// エクスポート処理用の CPU メッシュ（インデックス付き）。
/// リアルタイムの GPU 頂点スープ（MCVertex）とは別表現にして、両パイプラインを分離する。
struct CPUMesh {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]

    init(positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []) {
        self.positions = positions
        self.normals = normals
        self.indices = indices
    }

    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { positions.isEmpty || indices.isEmpty }
}

/// エクスポート時のメッシュ後処理 1 段。Phase 7 以降で具体実装を追加する拡張点。
protocol MeshPostProcessor: AnyObject {
    var name: String { get }
    /// 入力メッシュを変換して返す（純変換）。
    func process(_ mesh: CPUMesh) -> CPUMesh
}

/// エクスポート用メッシュ後処理パイプライン。段を順に適用する。
/// リアルタイム表示とは独立（Renderer / Integrator から参照されない）。
final class ExportMeshPipeline {

    private(set) var stages: [MeshPostProcessor] = []

    func append(_ stage: MeshPostProcessor) { stages.append(stage) }
    func removeAll() { stages.removeAll() }
    var isEmpty: Bool { stages.isEmpty }

    /// 全段を順に適用。段が無ければ入力をそのまま返す。
    func run(_ mesh: CPUMesh) -> CPUMesh {
        var current = mesh
        for stage in stages {
            current = stage.process(current)
        }
        return current
    }
}
