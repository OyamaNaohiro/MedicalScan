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
    didSet { loadSTL() }
  }

  private func loadSTL() {
    guard !stlFilePath.isEmpty,
          let scene = sceneView.scene else { return }

    scene.rootNode.childNodes
      .filter { $0.name == "stlMesh" }
      .forEach { $0.removeFromParentNode() }

    guard FileManager.default.fileExists(atPath: stlFilePath),
          let data = try? Data(contentsOf: URL(fileURLWithPath: stlFilePath)) else { return }

    guard let geometry = parseSTL(data: data) else { return }

    let material = SCNMaterial()
    material.diffuse.contents = UIColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
    material.lightingModel = .physicallyBased
    material.roughness.contents = Float(0.6)
    material.metalness.contents = Float(0.1)
    geometry.materials = [material]

    let meshNode = SCNNode(geometry: geometry)
    meshNode.name = "stlMesh"

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