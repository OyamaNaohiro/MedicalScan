import UIKit
import SceneKit
import ModelIO

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

    // Ambient light
    let ambient = SCNLight()
    ambient.type = .ambient
    ambient.intensity = 400
    let ambientNode = SCNNode()
    ambientNode.light = ambient
    scene.rootNode.addChildNode(ambientNode)

    // Directional light
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

    // Remove old mesh nodes
    scene.rootNode.childNodes
      .filter { $0.name == "stlMesh" }
      .forEach { $0.removeFromParentNode() }

    let url = URL(fileURLWithPath: stlFilePath)
    guard FileManager.default.fileExists(atPath: stlFilePath) else { return }

    let asset = MDLAsset(url: url)
    guard let mdlMesh = asset.object(at: 0) as? MDLMesh else { return }

    guard let geometry = try? SCNGeometry(mdlMesh: mdlMesh) else { return }

    let material = SCNMaterial()
    material.diffuse.contents = UIColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
    material.lightingModel = .physicallyBased
    material.roughness.contents = Float(0.6)
    material.metalness.contents = Float(0.1)
    geometry.materials = [material]

    let meshNode = SCNNode(geometry: geometry)
    meshNode.name = "stlMesh"

    // Center and normalize scale
    let (min, max) = meshNode.boundingBox
    let size = SCNVector3(max.x - min.x, max.y - min.y, max.z - min.z)
    let maxDim = Swift.max(size.x, size.y, size.z)
    if maxDim > 0 {
      let s = Float(2.0) / maxDim
      meshNode.scale = SCNVector3(s, s, s)
    }
    let cx = (min.x + max.x) / 2
    let cy = (min.y + max.y) / 2
    let cz = (min.z + max.z) / 2
    meshNode.pivot = SCNMatrix4MakeTranslation(cx, cy, cz)

    scene.rootNode.addChildNode(meshNode)

    // Camera
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
}