//
//  STLExporter.swift
//  ScanEngine / Export
//
//  メッシュを STL（バイナリ / ASCII）へ書き出す。エクスポートパイプライン専用で、
//  リアルタイム表示とは独立（Renderer/Integrator から参照されない）。
//
//  入力は三角形の頂点列（vertex soup: 3頂点で1三角形）。STL は面ごとに法線を持つので
//  ここで面法線を計算する。単位は m → mm（×1000、CAD/3Dプリント慣習）で出力する。
//

import simd
import Foundation

enum STLExporter {

    /// 頂点列（3つで1三角形）から STL データを生成。
    static func data(positions: [SIMD3<Float>], binary: Bool,
                     scale: Float = 1000, name: String = "ScanEngineMesh") -> Data {
        binary ? binarySTL(positions, scale: scale)
               : asciiSTL(positions, scale: scale, name: name)
    }

    // MARK: - Binary STL

    private static func binarySTL(_ positions: [SIMD3<Float>], scale: Float) -> Data {
        let triCount = positions.count / 3
        var bytes = [UInt8]()
        bytes.reserveCapacity(84 + triCount * 50)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 80))   // ヘッダ
        appendUInt32(&bytes, UInt32(triCount))

        for t in 0..<triCount {
            let v0 = positions[t * 3] * scale
            let v1 = positions[t * 3 + 1] * scale
            let v2 = positions[t * 3 + 2] * scale
            let n = faceNormal(v0, v1, v2)
            appendFloat(&bytes, n.x); appendFloat(&bytes, n.y); appendFloat(&bytes, n.z)
            appendFloat(&bytes, v0.x); appendFloat(&bytes, v0.y); appendFloat(&bytes, v0.z)
            appendFloat(&bytes, v1.x); appendFloat(&bytes, v1.y); appendFloat(&bytes, v1.z)
            appendFloat(&bytes, v2.x); appendFloat(&bytes, v2.y); appendFloat(&bytes, v2.z)
            bytes.append(0); bytes.append(0)   // attribute byte count
        }
        return Data(bytes)
    }

    // MARK: - ASCII STL

    private static func asciiSTL(_ positions: [SIMD3<Float>], scale: Float, name: String) -> Data {
        let triCount = positions.count / 3
        var s = "solid \(name)\n"
        s.reserveCapacity(triCount * 180)
        for t in 0..<triCount {
            let v0 = positions[t * 3] * scale
            let v1 = positions[t * 3 + 1] * scale
            let v2 = positions[t * 3 + 2] * scale
            let n = faceNormal(v0, v1, v2)
            s += "  facet normal \(n.x) \(n.y) \(n.z)\n"
            s += "    outer loop\n"
            s += "      vertex \(v0.x) \(v0.y) \(v0.z)\n"
            s += "      vertex \(v1.x) \(v1.y) \(v1.z)\n"
            s += "      vertex \(v2.x) \(v2.y) \(v2.z)\n"
            s += "    endloop\n"
            s += "  endfacet\n"
        }
        s += "endsolid \(name)\n"
        return Data(s.utf8)
    }

    // MARK: - helpers

    private static func faceNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let n = simd_cross(b - a, c - a)
        let len = simd_length(n)
        return len > 1e-12 ? n / len : SIMD3<Float>(0, 0, 1)
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
