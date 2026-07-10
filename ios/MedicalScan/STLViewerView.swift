import UIKit
import SceneKit

class STLViewerView: UIView {
  private let sceneView = SCNView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    addSubview(sceneView)
    sceneView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      sceneView.topAnchor.constraint(equalTo: topAnchor),
      sceneView.bottomAnchor.constraint(equalTo: bottomAnchor),
      sceneView.leadingAnchor.constraint(equalTo: leadingAnchor),
      sceneView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])

    sceneView.backgroundColor = UIColor(white: 0.08, alpha: 1)
    sceneView.allowsCameraControl = true
    sceneView.autoenablesDefaultLighting = true
    sceneView.antialiasingMode = .multisampling4X

    let scene = SCNScene()
    sceneView.scene = scene

    let ambient = SCNLight()
    ambient.type = .ambient
    ambient.intensity = 400
    let ambientNode = SCNNode()
    ambientNode.light = ambient
    scene.rootNode.addChildNode(ambientNode)

    let dir = SCNLight()
    dir.type = .directional
    dir.intensity = 1000
    let dirNode = SCNNode()
    dirNode.light = dir
    dirNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
    scene.rootNode.addChildNode(dirNode)
  }

  @objc var stlFilePath: String = "" {
    didSet { loadMesh() }
  }

  private func loadMesh() {
    guard !stlFilePath.isEmpty,
          let scene = sceneView.scene else { return }

    scene.rootNode.childNodes
      .filter { $0.name == "meshRoot" }
      .forEach { $0.removeFromParentNode() }

    guard FileManager.default.fileExists(atPath: stlFilePath),
          let data = try? Data(contentsOf: URL(fileURLWithPath: stlFilePath)) else { return }

    // 拡張子でパーサを切替（.ply は頂点カラー対応、それ以外は STL）。
    let geometry: SCNGeometry?
    if stlFilePath.lowercased().hasSuffix(".ply") {
      geometry = parsePLY(data: data)
    } else {
      geometry = parseSTL(data: data)
    }
    guard let geometry else { return }

    // 頂点カラーがあれば白ディフューズ（頂点色が乗算される）、無ければ従来の青。
    let hasColor = !geometry.sources(for: .color).isEmpty
    let material = SCNMaterial()
    if hasColor {
      material.diffuse.contents = UIColor.white
      material.lightingModel = .blinn
      material.isDoubleSided = true
    } else {
      material.diffuse.contents = UIColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
      material.lightingModel = .physicallyBased
      material.roughness.contents = Float(0.6)
      material.metalness.contents = Float(0.1)
    }
    geometry.materials = [material]

    let meshNode = SCNNode(geometry: geometry)
    meshNode.name = "meshRoot"

    let (bboxMin, bboxMax) = meshNode.boundingBox
    let dx = bboxMax.x - bboxMin.x
    let dy = bboxMax.y - bboxMin.y
    let dz = bboxMax.z - bboxMin.z
    let maxDim = Swift.max(dx, dy, dz)
    if maxDim > 0 {
      let s = Float(2.0) / maxDim
      meshNode.scale = SCNVector3(s, s, s)
    }
    let cx = (bboxMin.x + bboxMax.x) / 2
    let cy = (bboxMin.y + bboxMax.y) / 2
    let cz = (bboxMin.z + bboxMax.z) / 2
    meshNode.pivot = SCNMatrix4MakeTranslation(cx, cy, cz)

    scene.rootNode.addChildNode(meshNode)

    scene.rootNode.childNodes
      .filter { $0.name == "viewerCamera" }
      .forEach { $0.removeFromParentNode() }

    let camera = SCNCamera()
    camera.zFar = 200
    let cameraNode = SCNNode()
    cameraNode.name = "viewerCamera"
    cameraNode.camera = camera
    cameraNode.position = SCNVector3(0, 0, 4)
    scene.rootNode.addChildNode(cameraNode)
    sceneView.pointOfView = cameraNode
    sceneView.defaultCameraController.interactionMode = .orbitTurntable
  }

  // MARK: - PLY Parser (binary_little_endian / ascii, 頂点カラー対応)

  private static func plyTypeSize(_ t: String) -> Int {
    switch t {
    case "char", "uchar", "int8", "uint8": return 1
    case "short", "ushort", "int16", "uint16": return 2
    case "int", "uint", "int32", "uint32", "float", "float32": return 4
    case "double", "float64": return 8
    default: return 4
    }
  }
  private static func plyIsFloat(_ t: String) -> Bool {
    t == "float" || t == "float32" || t == "double" || t == "float64"
  }

  private func parsePLY(data: Data) -> SCNGeometry? {
    // 1) ヘッダ終端（end_header の次の改行の後）を探す。
    guard let bodyStart = plyBodyStart(data),
          let headerText = String(data: data.subdata(in: 0..<bodyStart), encoding: .ascii)
    else { return nil }

    // 2) ヘッダ解析。
    var isAscii = false, isBinaryLE = false
    var vertexCount = 0, faceCount = 0
    var currentElement = ""
    struct Prop { let name: String; let size: Int; let isFloat: Bool }
    var vProps: [Prop] = []
    var faceCountSize = 1, faceIndexSize = 4

    for line in headerText.components(separatedBy: .newlines) {
      let p = line.trimmingCharacters(in: .whitespaces)
        .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
      guard let head = p.first else { continue }
      switch head {
      case "format" where p.count >= 2:
        isAscii = p[1] == "ascii"
        isBinaryLE = p[1] == "binary_little_endian"
      case "element" where p.count >= 3:
        currentElement = p[1]
        if p[1] == "vertex" { vertexCount = Int(p[2]) ?? 0 }
        else if p[1] == "face" { faceCount = Int(p[2]) ?? 0 }
      case "property":
        if currentElement == "vertex", p.count >= 3 {
          vProps.append(Prop(name: p[2], size: Self.plyTypeSize(p[1]), isFloat: Self.plyIsFloat(p[1])))
        } else if currentElement == "face", p.count >= 5, p[1] == "list" {
          faceCountSize = Self.plyTypeSize(p[2])
          faceIndexSize = Self.plyTypeSize(p[3])
        }
      default: break
      }
    }
    guard vertexCount > 0, isAscii || isBinaryLE else { return nil }

    // 3) 頂点プロパティのオフセット/順序を索引化。
    var order: [String: Int] = [:], offset: [String: Int] = [:]
    var size: [String: Int] = [:], isFloat: [String: Bool] = [:]
    var stride = 0
    for (i, prop) in vProps.enumerated() {
      order[prop.name] = i; offset[prop.name] = stride
      size[prop.name] = prop.size; isFloat[prop.name] = prop.isFloat
      stride += prop.size
    }
    let hasColor = offset["red"] != nil && offset["green"] != nil && offset["blue"] != nil
    guard offset["x"] != nil, offset["y"] != nil, offset["z"] != nil else { return nil }

    var positions = [Float](); positions.reserveCapacity(vertexCount * 3)
    var colors = [Float](); if hasColor { colors.reserveCapacity(vertexCount * 3) }
    var indices = [Int32]()

    if isBinaryLE {
      data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let base = raw.baseAddress!
        func coord(_ cursor: Int, _ name: String) -> Float {
          let o = cursor + offset[name]!
          if isFloat[name] == true { return size[name] == 8
            ? Float(base.loadUnaligned(fromByteOffset: o, as: Float64.self))
            : base.loadUnaligned(fromByteOffset: o, as: Float.self) }
          return Float(base.loadUnaligned(fromByteOffset: o, as: Int32.self))
        }
        func chan(_ cursor: Int, _ name: String) -> Float {
          let o = cursor + offset[name]!
          if isFloat[name] == true { return base.loadUnaligned(fromByteOffset: o, as: Float.self) }
          switch size[name]! {
          case 1: return Float(base.load(fromByteOffset: o, as: UInt8.self)) / 255.0
          case 2: return Float(base.loadUnaligned(fromByteOffset: o, as: UInt16.self)) / 65535.0
          default: return Float(base.loadUnaligned(fromByteOffset: o, as: UInt32.self)) / 4294967295.0
          }
        }
        var cursor = bodyStart
        for _ in 0..<vertexCount {
          positions.append(coord(cursor, "x"))
          positions.append(coord(cursor, "y"))
          positions.append(coord(cursor, "z"))
          if hasColor {
            colors.append(chan(cursor, "red"))
            colors.append(chan(cursor, "green"))
            colors.append(chan(cursor, "blue"))
          }
          cursor += stride
        }
        func idx(_ pos: Int) -> Int32 {
          switch faceIndexSize {
          case 1: return Int32(base.load(fromByteOffset: pos, as: UInt8.self))
          case 2: return Int32(base.loadUnaligned(fromByteOffset: pos, as: UInt16.self))
          default: return Int32(bitPattern: base.loadUnaligned(fromByteOffset: pos, as: UInt32.self))
          }
        }
        for _ in 0..<faceCount {
          guard cursor + faceCountSize <= raw.count else { break }
          let k = Int(faceCountSize == 1 ? Int(base.load(fromByteOffset: cursor, as: UInt8.self))
                                         : Int(base.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)))
          cursor += faceCountSize
          guard k >= 3, cursor + k * faceIndexSize <= raw.count else { cursor += max(0, k) * faceIndexSize; continue }
          var poly = [Int32](); poly.reserveCapacity(k)
          for _ in 0..<k { poly.append(idx(cursor)); cursor += faceIndexSize }
          for t in 1..<(k - 1) { indices.append(poly[0]); indices.append(poly[t]); indices.append(poly[t + 1]) }
        }
      }
    } else {
      // ascii
      let body = String(data: data.subdata(in: bodyStart..<data.count), encoding: .ascii) ?? ""
      let lines = body.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      var li = 0
      let ox = order["x"]!, oy = order["y"]!, oz = order["z"]!
      for _ in 0..<vertexCount where li < lines.count {
        let t = lines[li].components(separatedBy: .whitespaces).filter { !$0.isEmpty }; li += 1
        guard t.count >= vProps.count else { continue }
        positions.append(Float(t[ox]) ?? 0); positions.append(Float(t[oy]) ?? 0); positions.append(Float(t[oz]) ?? 0)
        if hasColor {
          let orr = order["red"]!, og = order["green"]!, ob = order["blue"]!
          let div: Float = (isFloat["red"] == true) ? 1.0 : 255.0
          colors.append((Float(t[orr]) ?? 0) / div)
          colors.append((Float(t[og]) ?? 0) / div)
          colors.append((Float(t[ob]) ?? 0) / div)
        }
      }
      for _ in 0..<faceCount where li < lines.count {
        let t = lines[li].components(separatedBy: .whitespaces).filter { !$0.isEmpty }; li += 1
        guard let k = Int(t.first ?? ""), k >= 3, t.count >= k + 1 else { continue }
        let poly = (1...k).map { Int32(t[$0]) ?? 0 }
        for j in 1..<(k - 1) { indices.append(poly[0]); indices.append(poly[j]); indices.append(poly[j + 1]) }
      }
    }

    return buildIndexedGeometry(positions: positions,
                                colors: hasColor ? colors : nil, indices: indices)
  }

  /// end_header の次の改行の直後（本体開始オフセット）を返す。
  private func plyBodyStart(_ data: Data) -> Int? {
    guard let r = data.range(of: Data("end_header".utf8)) else { return nil }
    var i = r.upperBound
    while i < data.count, data[i] != 0x0A { i += 1 }   // 改行(\n)まで進める
    return i < data.count ? i + 1 : nil
  }

  /// インデックス付きメッシュ（＋任意の頂点カラー）から法線を計算して SCNGeometry を作る。
  private func buildIndexedGeometry(positions: [Float], colors: [Float]?, indices: [Int32]) -> SCNGeometry? {
    let vertexCount = positions.count / 3
    guard vertexCount > 0, indices.count >= 3 else { return nil }

    // 面から頂点法線を面積重み付きで計算。
    var normals = [Float](repeating: 0, count: positions.count)
    var t = 0
    while t + 2 < indices.count {
      let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2]); t += 3
      guard a < vertexCount, b < vertexCount, c < vertexCount else { continue }
      let ax = positions[a*3], ay = positions[a*3+1], az = positions[a*3+2]
      let bx = positions[b*3], by = positions[b*3+1], bz = positions[b*3+2]
      let cx = positions[c*3], cy = positions[c*3+1], cz = positions[c*3+2]
      let ux = bx-ax, uy = by-ay, uz = bz-az
      let vx = cx-ax, vy = cy-ay, vz = cz-az
      let nx = uy*vz - uz*vy, ny = uz*vx - ux*vz, nz = ux*vy - uy*vx
      for idx in [a, b, c] { normals[idx*3] += nx; normals[idx*3+1] += ny; normals[idx*3+2] += nz }
    }
    for i in 0..<vertexCount {
      let l = (normals[i*3]*normals[i*3] + normals[i*3+1]*normals[i*3+1] + normals[i*3+2]*normals[i*3+2]).squareRoot()
      if l > 1e-9 { normals[i*3] /= l; normals[i*3+1] /= l; normals[i*3+2] /= l }
    }

    let posData = Data(bytes: positions, count: positions.count * 4)
    let posSource = SCNGeometrySource(data: posData, semantic: .vertex,
      vectorCount: vertexCount, usesFloatComponents: true,
      componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
    let nrmData = Data(bytes: normals, count: normals.count * 4)
    let nrmSource = SCNGeometrySource(data: nrmData, semantic: .normal,
      vectorCount: vertexCount, usesFloatComponents: true,
      componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)

    var sources = [posSource, nrmSource]
    if let colors, colors.count == positions.count {
      let colData = Data(bytes: colors, count: colors.count * 4)
      let colSource = SCNGeometrySource(data: colData, semantic: .color,
        vectorCount: vertexCount, usesFloatComponents: true,
        componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
      sources.append(colSource)
    }

    let idxData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
    let element = SCNGeometryElement(data: idxData, primitiveType: .triangles,
      primitiveCount: indices.count / 3, bytesPerIndex: MemoryLayout<Int32>.size)

    return SCNGeometry(sources: sources, elements: [element])
  }

  // MARK: - STL Parser (pure Swift, no ModelIO)

  private func parseSTL(data: Data) -> SCNGeometry? {
    // Detect ASCII STL by checking for "solid" prefix followed by a newline
    if data.count > 6 {
      let prefix = String(bytes: data.prefix(80), encoding: .ascii) ?? ""
      let trimmed = prefix.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("solid") && (prefix.contains("\n") || prefix.contains("\r")) {
        if let geo = parseASCIISTL(data: data) { return geo }
      }
    }
    return parseBinarySTL(data: data)
  }

  private func parseBinarySTL(data: Data) -> SCNGeometry? {
    guard data.count >= 84 else { return nil }

    let triangleCount = data.withUnsafeBytes { ptr -> UInt32 in
      ptr.load(fromByteOffset: 80, as: UInt32.self).littleEndian
    }
    guard triangleCount > 0,
          data.count >= 84 + Int(triangleCount) * 50 else { return nil }

    var positions = [Float]()
    var normals = [Float]()
    positions.reserveCapacity(Int(triangleCount) * 9)
    normals.reserveCapacity(Int(triangleCount) * 9)

    data.withUnsafeBytes { raw in
      let base = raw.baseAddress!
      for i in 0..<Int(triangleCount) {
        let offset = 84 + i * 50
        let fPtr = (base + offset).assumingMemoryBound(to: Float.self)
        let nx = fPtr[0], ny = fPtr[1], nz = fPtr[2]
        for v in 0..<3 {
          let vBase = fPtr + 3 + v * 3
          positions.append(vBase[0])
          positions.append(vBase[1])
          positions.append(vBase[2])
          normals.append(nx)
          normals.append(ny)
          normals.append(nz)
        }
      }
    }

    return buildGeometry(positions: positions, normals: normals)
  }

  private func parseASCIISTL(data: Data) -> SCNGeometry? {
    guard let text = String(data: data, encoding: .utf8) ??
                     String(data: data, encoding: .ascii) else { return nil }

    var positions = [Float]()
    var normals = [Float]()
    var currentNormal = (Float(0), Float(0), Float(0))

    for line in text.components(separatedBy: .newlines) {
      let parts = line.trimmingCharacters(in: .whitespaces)
        .components(separatedBy: .whitespaces)
        .filter { !$0.isEmpty }
      guard !parts.isEmpty else { continue }

      if parts[0] == "facet" && parts.count >= 5 {
        currentNormal = (Float(parts[2]) ?? 0,
                         Float(parts[3]) ?? 0,
                         Float(parts[4]) ?? 0)
      } else if parts[0] == "vertex" && parts.count >= 4 {
        positions.append(Float(parts[1]) ?? 0)
        positions.append(Float(parts[2]) ?? 0)
        positions.append(Float(parts[3]) ?? 0)
        normals.append(currentNormal.0)
        normals.append(currentNormal.1)
        normals.append(currentNormal.2)
      }
    }

    guard !positions.isEmpty else { return nil }
    return buildGeometry(positions: positions, normals: normals)
  }

  private func buildGeometry(positions: [Float], normals: [Float]) -> SCNGeometry? {
    let vertexCount = positions.count / 3
    guard vertexCount > 0 else { return nil }

    let posData = Data(bytes: positions, count: positions.count * MemoryLayout<Float>.size)
    let posSource = SCNGeometrySource(
      data: posData, semantic: .vertex,
      vectorCount: vertexCount, usesFloatComponents: true,
      componentsPerVector: 3, bytesPerComponent: 4,
      dataOffset: 0, dataStride: 12)

    let nrmData = Data(bytes: normals, count: normals.count * MemoryLayout<Float>.size)
    let nrmSource = SCNGeometrySource(
      data: nrmData, semantic: .normal,
      vectorCount: vertexCount, usesFloatComponents: true,
      componentsPerVector: 3, bytesPerComponent: 4,
      dataOffset: 0, dataStride: 12)

    let indices = (0..<Int32(vertexCount)).map { $0 }
    let idxData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
    let element = SCNGeometryElement(
      data: idxData, primitiveType: .triangles,
      primitiveCount: vertexCount / 3,
      bytesPerIndex: MemoryLayout<Int32>.size)

    return SCNGeometry(sources: [posSource, nrmSource], elements: [element])
  }
}