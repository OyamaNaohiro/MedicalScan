//
//  PLYExporter.swift
//  ScanEngine / Export
//
//  メッシュを PLY（バイナリ / ASCII）へ書き出す。STL と違い頂点カラーを保持できる
//  （property uchar red/green/blue）。エクスポートパイプライン専用（リアルタイムと独立）。
//
//  入力はインデックス付きメッシュ（positions + indices）。indices が空なら
//  positions を三角形スープ（3頂点=1三角形）とみなして連番フェイスを生成する。
//  単位は m → mm（×1000）で STL と揃える。
//

import simd
import Foundation

enum PLYExporter {

    /// - Parameters:
    ///   - positions: 頂点位置 [m]
    ///   - colors: 頂点カラー（RGB 0..1）。空/不整合ならグレーで出力。
    ///   - indices: 三角形インデックス。空なら positions を連番スープ扱い。
    static func data(positions: [SIMD3<Float>], colors: [SIMD3<Float>],
                     indices: [UInt32], binary: Bool, scale: Float = 1000) -> Data {
        // インデックスが無ければ連番（スープ）。
        let idx: [UInt32] = indices.isEmpty
            ? Array(0..<UInt32(positions.count))
            : indices
        let triCount = idx.count / 3
        let hasColor = colors.count == positions.count
        let gray = SIMD3<Float>(0.7, 0.76, 0.85)

        func rgb(_ i: Int) -> (UInt8, UInt8, UInt8) {
            var c = hasColor ? colors[i] : gray
            // 無色センチネル(負値)や範囲外はグレー/クランプ。
            if c.x < 0 || c.y < 0 || c.z < 0 { c = gray }
            c = simd_clamp(c, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)) * 255
            return (UInt8(c.x), UInt8(c.y), UInt8(c.z))
        }

        let header = """
        ply
        format \(binary ? "binary_little_endian" : "ascii") 1.0
        comment ScanEngine colored mesh
        element vertex \(positions.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element face \(triCount)
        property list uchar uint vertex_indices
        end_header

        """

        if binary {
            var bytes = [UInt8]()
            bytes.reserveCapacity(header.utf8.count + positions.count * 15 + triCount * 13)
            bytes.append(contentsOf: header.utf8)
            for i in 0..<positions.count {
                let p = positions[i] * scale
                appendFloat(&bytes, p.x); appendFloat(&bytes, p.y); appendFloat(&bytes, p.z)
                let (r, g, b) = rgb(i)
                bytes.append(r); bytes.append(g); bytes.append(b)
            }
            for t in 0..<triCount {
                bytes.append(3)   // 頂点数/フェイス
                appendUInt32(&bytes, idx[t * 3])
                appendUInt32(&bytes, idx[t * 3 + 1])
                appendUInt32(&bytes, idx[t * 3 + 2])
            }
            return Data(bytes)
        } else {
            var s = header
            s.reserveCapacity(header.utf8.count + positions.count * 40 + triCount * 20)
            for i in 0..<positions.count {
                let p = positions[i] * scale
                let (r, g, b) = rgb(i)
                s += "\(p.x) \(p.y) \(p.z) \(r) \(g) \(b)\n"
            }
            for t in 0..<triCount {
                s += "3 \(idx[t * 3]) \(idx[t * 3 + 1]) \(idx[t * 3 + 2])\n"
            }
            return Data(s.utf8)
        }
    }

    private static func appendFloat(_ buffer: inout [UInt8], _ f: Float) {
        let bits = f.bitPattern.littleEndian
        buffer.append(UInt8(bits & 0xFF))
        buffer.append(UInt8((bits >> 8) & 0xFF))
        buffer.append(UInt8((bits >> 16) & 0xFF))
        buffer.append(UInt8((bits >> 24) & 0xFF))
    }

    private static func appendUInt32(_ buffer: inout [UInt8], _ v: UInt32) {
        let le = v.littleEndian
        buffer.append(UInt8(le & 0xFF))
        buffer.append(UInt8((le >> 8) & 0xFF))
        buffer.append(UInt8((le >> 16) & 0xFF))
        buffer.append(UInt8((le >> 24) & 0xFF))
    }
}
