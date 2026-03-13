import UIKit
import ARKit
import SceneKit
import ModelIO

class LiDARScannerView: UIView, ARSessionDelegate, ARSCNViewDelegate {

  private var sceneView: ARSCNView!
  private var isSessionRunning = false
  private var collectedMeshAnchors: [ARMeshAnchor] = []
  private var collectedFaceAnchors: [ARFaceAnchor] = []

  // MARK: - React Props

  @objc var showMeshOverlay: Bool = true

  @objc var scannerMode: String = "lidar" {
    didSet {
      guard scannerMode != oldValue, isSessionRunning else { return }
      pauseARSession()
      if isScanning { startARSession() }
    }
  }

  @objc var isScanning: Bool = false {
    didSet {
      guard isScanning != oldValue else { return }
      if isScanning {
        collectedMeshAnchors = []
        collectedFaceAnchors = []
        startARSession()
        onScanEvent?(["type": "scanStarted"])
      } else {
        pauseARSession()
        onScanEvent?(["type": "scanStopped"])
      }
    }
  }

  @objc var exportFilename: String = "" {
    didSet {
      guard !exportFilename.isEmpty else { return }
      let filename = exportFilename
      let mode = scannerMode
      let meshAnchors = collectedMeshAnchors
      let faceAnchors = collectedFaceAnchors
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        do {
          let filePath: String
          if mode == "trueDepth" {
            guard !faceAnchors.isEmpty else {
              self.onScanEvent?(["type": "error", "message": "No face mesh data captured."])
              return
            }
            filePath = try self.convertFaceMeshToSTL(anchors: faceAnchors, filename: filename)
          } else {
            guard !meshAnchors.isEmpty else {
              self.onScanEvent?(["type": "error", "message": "No mesh data captured. Run a scan first."])
              return
            }
            filePath = try self.convertMeshToSTL(anchors: meshAnchors, filename: filename)
          }
          self.onScanEvent?(["type": "exported", "path": filePath])
        } catch {
          self.onScanEvent?(["type": "error", "message": error.localizedDescription])
        }
      }
    }
  }

  @objc var onScanEvent: RCTBubblingEventBlock?

  // MARK: - Init

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupSceneView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupSceneView()
  }

  private func setupSceneView() {
    sceneView = ARSCNView(frame: bounds)
    sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    sceneView.delegate = self
    sceneView.session.delegate = self
    sceneView.automaticallyUpdatesLighting = true
    addSubview(sceneView)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    sceneView.frame = bounds
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      pauseARSession()
    }
  }

  // MARK: - AR Session Management

  private func startARSession() {
    guard !isSessionRunning else { return }
    if scannerMode == "trueDepth" {
      guard ARFaceTrackingConfiguration.isSupported else {
        onScanEvent?(["type": "error", "message": "TrueDepth camera is not available on this device."])
        return
      }
      let config = ARFaceTrackingConfiguration()
      config.isLightEstimationEnabled = true
      sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    } else {
      guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
        onScanEvent?(["type": "error", "message": "LiDAR scanner is not available on this device."])
        return
      }
      let config = ARWorldTrackingConfiguration()
      config.sceneReconstruction = .mesh
      config.environmentTexturing = .automatic
      sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
    isSessionRunning = true
  }

  private func pauseARSession() {
    guard isSessionRunning else { return }
    sceneView.session.pause()
    isSessionRunning = false
  }

  // MARK: - ARSessionDelegate

  func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
    guard isScanning else { return }
    for anchor in anchors {
      if let meshAnchor = anchor as? ARMeshAnchor {
        collectedMeshAnchors.append(meshAnchor)
      } else if let faceAnchor = anchor as? ARFaceAnchor {
        collectedFaceAnchors.removeAll { $0.identifier == faceAnchor.identifier }
        collectedFaceAnchors.append(faceAnchor)
      }
    }
  }

  func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
    guard isScanning else { return }
    for anchor in anchors {
      if let meshAnchor = anchor as? ARMeshAnchor {
        collectedMeshAnchors.removeAll { $0.identifier == meshAnchor.identifier }
        collectedMeshAnchors.append(meshAnchor)
      } else if let faceAnchor = anchor as? ARFaceAnchor {
        collectedFaceAnchors.removeAll { $0.identifier == faceAnchor.identifier }
        collectedFaceAnchors.append(faceAnchor)
      }
    }
  }

  func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
    for anchor in anchors {
      collectedMeshAnchors.removeAll { $0.identifier == anchor.identifier }
      collectedFaceAnchors.removeAll { $0.identifier == anchor.identifier }
    }
  }

  // MARK: - ARSCNViewDelegate

  func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
    guard showMeshOverlay else { return SCNNode() }
    if let meshAnchor = anchor as? ARMeshAnchor {
      return SCNNode(geometry: createLiDARGeometry(from: meshAnchor.geometry))
    }
    if let faceAnchor = anchor as? ARFaceAnchor {
      return SCNNode(geometry: createFaceGeometry(from: faceAnchor.geometry))
    }
    return nil
  }

  func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
    if let meshAnchor = anchor as? ARMeshAnchor {
      node.geometry = showMeshOverlay ? createLiDARGeometry(from: meshAnchor.geometry) : nil
    } else if let faceAnchor = anchor as? ARFaceAnchor {
      node.geometry = showMeshOverlay ? createFaceGeometry(from: faceAnchor.geometry) : nil
    }
  }

  // MARK: - Geometry Builders

  private func createLiDARGeometry(from meshGeometry: ARMeshGeometry) -> SCNGeometry {
    let vertexCount = meshGeometry.vertices.count
    let vertexPointer = meshGeometry.vertices.buffer.contents()
      .bindMemory(to: SIMD3<Float>.self, capacity: vertexCount)
    var vertices: [SCNVector3] = []
    for i in 0..<vertexCount {
      let v = vertexPointer[i]
      vertices.append(SCNVector3(v.x, v.y, v.z))
    }
    let vertexSource = SCNGeometrySource(vertices: vertices)
    let faceCount = meshGeometry.faces.count
    let indexBuffer = meshGeometry.faces.buffer.contents()
    let bytesPerIndex = meshGeometry.faces.bytesPerIndex
    var indices: [UInt32] = []
    for i in 0..<(faceCount * 3) {
      let offset = i * bytesPerIndex
      if bytesPerIndex == 4 {
        indices.append(indexBuffer.load(fromByteOffset: offset, as: UInt32.self))
      } else if bytesPerIndex == 2 {
        indices.append(UInt32(indexBuffer.load(fromByteOffset: offset, as: UInt16.self)))
      }
    }
    return buildGeometry(vertexSource: vertexSource, indices: indices, faceCount: faceCount)
  }

  private func createFaceGeometry(from faceGeometry: ARFaceGeometry) -> SCNGeometry {
    let vertices = faceGeometry.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
    let vertexSource = SCNGeometrySource(vertices: vertices)
    let indices = faceGeometry.triangleIndices.map { UInt32($0) }
    return buildGeometry(vertexSource: vertexSource, indices: indices, faceCount: faceGeometry.triangleCount)
  }

  private func buildGeometry(vertexSource: SCNGeometrySource, indices: [UInt32], faceCount: Int) -> SCNGeometry {
    let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.stride)
    let element = SCNGeometryElement(
      data: indexData,
      primitiveType: .triangles,
      primitiveCount: faceCount,
      bytesPerIndex: MemoryLayout<UInt32>.stride
    )
    let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
    let material = SCNMaterial()
    material.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.3)
    material.isDoubleSided = true
    material.fillMode = .lines
    geometry.materials = [material]
    return geometry
  }

  // MARK: - STL Export

  private func convertMeshToSTL(anchors: [ARMeshAnchor], filename: String) throws -> String {
    let allocator = MDLMeshBufferDataAllocator()
    let asset = MDLAsset()
    for anchor in anchors {
      let meshGeometry = anchor.geometry
      let transform = anchor.transform
      let vertexCount = meshGeometry.vertices.count
      let faceCount = meshGeometry.faces.count
      var vertices: [SIMD3<Float>] = []
      let vertexPointer = meshGeometry.vertices.buffer.contents()
        .bindMemory(to: SIMD3<Float>.self, capacity: vertexCount)
      for i in 0..<vertexCount {
        let local = vertexPointer[i]
        let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1.0)
        vertices.append(SIMD3<Float>(world.x, world.y, world.z))
      }
      let indexBuffer = meshGeometry.faces.buffer.contents()
      let bytesPerIndex = meshGeometry.faces.bytesPerIndex
      var indices: [UInt32] = []
      for i in 0..<(faceCount * 3) {
        let offset = i * bytesPerIndex
        if bytesPerIndex == 4 {
          indices.append(indexBuffer.load(fromByteOffset: offset, as: UInt32.self))
        } else if bytesPerIndex == 2 {
          indices.append(UInt32(indexBuffer.load(fromByteOffset: offset, as: UInt16.self)))
        }
      }
      if let mdlMesh = buildMDLMesh(vertices: vertices, indices: indices,
                                    vertexCount: vertexCount, allocator: allocator) {
        asset.add(mdlMesh)
      }
    }
    return try exportAsset(asset, filename: filename)
  }

  private func convertFaceMeshToSTL(anchors: [ARFaceAnchor], filename: String) throws -> String {
    let allocator = MDLMeshBufferDataAllocator()
    let asset = MDLAsset()
    for anchor in anchors {
      let faceGeometry = anchor.geometry
      let transform = anchor.transform
      let vertexCount = faceGeometry.vertices.count
      var vertices: [SIMD3<Float>] = []
      for i in 0..<vertexCount {
        let local = faceGeometry.vertices[i]
        let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1.0)
        vertices.append(SIMD3<Float>(world.x, world.y, world.z))
      }
      var indices: [UInt32] = []
      for i in 0..<(faceGeometry.triangleCount * 3) {
        indices.append(UInt32(faceGeometry.triangleIndices[i]))
      }
      if let mdlMesh = buildMDLMesh(vertices: vertices, indices: indices,
                                    vertexCount: vertexCount, allocator: allocator) {
        asset.add(mdlMesh)
      }
    }
    return try exportAsset(asset, filename: filename)
  }

  private func buildMDLMesh(vertices: [SIMD3<Float>],
                             indices: [UInt32],
                             vertexCount: Int,
                             allocator: MDLMeshBufferDataAllocator) -> MDLMesh? {
    let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<SIMD3<Float>>.stride)
    let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)
    let vertexDescriptor = MDLVertexDescriptor()
    let positionAttribute = MDLVertexAttribute(
      name: MDLVertexAttributePosition,
      format: .float3,
      offset: 0,
      bufferIndex: 0
    )
    vertexDescriptor.attributes = NSMutableArray(array: [positionAttribute])
    vertexDescriptor.layouts = NSMutableArray(array: [
      MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)
    ])
    let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.stride)
    let indexBuffer = allocator.newBuffer(with: indexData, type: .index)
    let submesh = MDLSubmesh(
      indexBuffer: indexBuffer,
      indexCount: indices.count,
      indexType: .uInt32,
      geometryType: .triangles,
      material: nil
    )
    return MDLMesh(
      vertexBuffer: vertexBuffer,
      vertexCount: vertexCount,
      descriptor: vertexDescriptor,
      submeshes: [submesh]
    )
  }

  private func exportAsset(_ asset: MDLAsset, filename: String) throws -> String {
    let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let sanitizedFilename = filename.hasSuffix(".stl") ? filename : "\(filename).stl"
    let fileURL = documentsDir.appendingPathComponent(sanitizedFilename)
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
    try asset.export(to: fileURL)
    return fileURL.path
  }
}