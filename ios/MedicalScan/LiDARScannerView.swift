import UIKit
import ARKit
import SceneKit

class LiDARScannerView: UIView, ARSessionDelegate, ARSCNViewDelegate {

  private var sceneView: ARSCNView!
  private var isSessionRunning = false

  @objc var showMeshOverlay: Bool = true {
    didSet { updateMeshVisibility() }
  }

  /// "lidar" (default) or "trueDepth"
  @objc var scannerMode: String = "lidar" {
    didSet {
      if isSessionRunning {
        pauseARSession()
        startARSession()
      }
    }
  }

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
    sceneView.automaticallyUpdatesLighting = true
    sceneView.debugOptions = [.showWorldOrigin]
    addSubview(sceneView)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    sceneView.frame = bounds
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      startARSession()
    } else {
      pauseARSession()
    }
  }

  // MARK: - AR Session Management

  private func startARSession() {
    guard !isSessionRunning else { return }

    sceneView.session.delegate = self

    if scannerMode == "trueDepth" {
      guard ARFaceTrackingConfiguration.isSupported else { return }
      let config = ARFaceTrackingConfiguration()
      config.isLightEstimationEnabled = true
      sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    } else {
      guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else { return }
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

  // MARK: - Mesh Overlay

  private func updateMeshVisibility() {
    if showMeshOverlay {
      sceneView.debugOptions.insert(.showWorldOrigin)
    } else {
      sceneView.debugOptions.remove(.showWorldOrigin)
    }
  }

  // MARK: - ARSCNViewDelegate

  func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
    if let meshAnchor = anchor as? ARMeshAnchor {
      let geometry = createLiDARGeometry(from: meshAnchor.geometry)
      return SCNNode(geometry: geometry)
    }
    if let faceAnchor = anchor as? ARFaceAnchor {
      let geometry = createFaceGeometry(from: faceAnchor.geometry)
      return SCNNode(geometry: geometry)
    }
    return nil
  }

  func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
    if let meshAnchor = anchor as? ARMeshAnchor {
      node.geometry = createLiDARGeometry(from: meshAnchor.geometry)
    } else if let faceAnchor = anchor as? ARFaceAnchor {
      node.geometry = createFaceGeometry(from: faceAnchor.geometry)
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

    let triangleCount = faceGeometry.triangleCount
    let indices = faceGeometry.triangleIndices.map { UInt32($0) }

    return buildGeometry(vertexSource: vertexSource, indices: indices, faceCount: triangleCount)
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
}
