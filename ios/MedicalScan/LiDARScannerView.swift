import UIKit
import ARKit
import SceneKit
import ModelIO
import AVFoundation
import simd

class LiDARScannerView: UIView, ARSessionDelegate, ARSCNViewDelegate {

  // MARK: - ARKit
  private var sceneView: ARSCNView!
  private var isSessionRunning = false
  private var collectedMeshAnchors: [ARMeshAnchor] = []

  // MARK: - TrueDepth Object: world-space voxel fusion
  private let fusionQueue = DispatchQueue(label: "com.medicalscan.fusion", qos: .userInitiated)
  private var worldVoxels: [SIMD3<Int32>: (sum: SIMD3<Float>, count: Int32)] = [:]
  private let voxelSize: Float = 0.005        // 5 mm per voxel
  private var pointCloudNode: SCNNode?
  private var fusedFrameCount   = 0
  private var lastVisualizeCount = 0

  // MARK: - React Props

  @objc var showMeshOverlay: Bool = true

  @objc var scannerMode: String = "lidar" {
    didSet {
      guard scannerMode != oldValue else { return }
      if isSessionRunning { pauseARSession() }
      if window != nil { startPreviewSession() }
    }
  }

  @objc var isScanning: Bool = false {
    didSet {
      guard isScanning != oldValue else { return }
      if isScanning {
        collectedMeshAnchors = []
        fusionQueue.async { [weak self] in
          self?.worldVoxels = [:]
          self?.fusedFrameCount    = 0
          self?.lastVisualizeCount = 0
        }
        DispatchQueue.main.async { [weak self] in
          self?.pointCloudNode?.removeFromParentNode()
          self?.pointCloudNode = nil
        }
        if !isSessionRunning { startPreviewSession() }
        ScanEventEmitter.emitEvent(["type": "scanStarted"])
      } else {
        ScanEventEmitter.emitEvent(["type": "scanStopped"])
      }
    }
  }

  @objc var exportFilename: String = "" {
    didSet {
      guard !exportFilename.isEmpty else { return }
      let filename    = exportFilename
      let mode        = scannerMode
      let meshAnchors = collectedMeshAnchors

      if mode == "trueDepthObject" {
        fusionQueue.async { [weak self] in
          guard let self = self else { return }
          let snapshot = self.worldVoxels
          DispatchQueue.global(qos: .userInitiated).async {
            do {
              guard !snapshot.isEmpty else {
                ScanEventEmitter.emitEvent(["type": "error",
                  "message": "スキャンデータがありません。スキャンを実行してください。"])
                return
              }
              let path = try self.voxelsToSTL(snapshot, filename: filename)
              ScanEventEmitter.emitEvent(["type": "exported", "path": path])
            } catch {
              ScanEventEmitter.emitEvent(["type": "error", "message": error.localizedDescription])
            }
          }
        }
      } else {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
          guard let self = self else { return }
          do {
            guard !meshAnchors.isEmpty else {
              ScanEventEmitter.emitEvent(["type": "error",
                "message": "メッシュデータがありません。スキャンを実行してください。"])
              return
            }
            let path = try self.convertMeshToSTL(anchors: meshAnchors, filename: filename)
            ScanEventEmitter.emitEvent(["type": "exported", "path": path])
          } catch {
            ScanEventEmitter.emitEvent(["type": "error", "message": error.localizedDescription])
          }
        }
      }
    }
  }

  // MARK: - Init

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
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
    } else if !isSessionRunning {
      startPreviewSession()
    }
  }

  // MARK: - Session Management

  private func startPreviewSession() {
    guard !isSessionRunning else { return }

    if scannerMode == "trueDepthObject" {
      guard ARFaceTrackingConfiguration.isSupported else {
        ScanEventEmitter.emitEvent(["type": "error",
          "message": "TrueDepthカメラが利用できません（Face ID非搭載機種）。"])
        return
      }
      let config = ARFaceTrackingConfiguration()
      if ARFaceTrackingConfiguration.supportsWorldTracking {
        config.isWorldTrackingEnabled = true   // iPhone 12+ で安定した姿勢追跡
      }
      config.isLightEstimationEnabled = false
      sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

    } else {  // lidar
      guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
        ScanEventEmitter.emitEvent(["type": "error",
          "message": "LiDARスキャナーはこのデバイスでは利用できません。"])
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
    DispatchQueue.main.async { [weak self] in
      self?.pointCloudNode?.removeFromParentNode()
      self?.pointCloudNode = nil
    }
    isSessionRunning = false
  }

  // MARK: - ARSessionDelegate

  // TrueDepth Object: integrate depth every ARKit frame
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard isScanning, scannerMode == "trueDepthObject" else { return }
    guard let capturedDepth = frame.capturedDepthData else { return }

    let transform = frame.camera.transform
    let depth     = capturedDepth
    fusionQueue.async { [weak self] in
      self?.integrateDepth(depth, cameraTransform: transform)
    }
  }

  // LiDAR: collect mesh anchors
  func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
    guard isScanning, scannerMode == "lidar" else { return }
    anchors.compactMap { $0 as? ARMeshAnchor }.forEach { collectedMeshAnchors.append($0) }
  }

  func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
    guard isScanning, scannerMode == "lidar" else { return }
    for a in anchors.compactMap({ $0 as? ARMeshAnchor }) {
      collectedMeshAnchors.removeAll { $0.identifier == a.identifier }
      collectedMeshAnchors.append(a)
    }
  }

  func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
    for a in anchors { collectedMeshAnchors.removeAll { $0.identifier == a.identifier } }
  }

  // MARK: - ARSCNViewDelegate (LiDAR mesh overlay)

  func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
    guard showMeshOverlay, scannerMode == "lidar",
          let mesh = anchor as? ARMeshAnchor else { return SCNNode() }
    return SCNNode(geometry: lidarGeometry(mesh.geometry))
  }

  func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
    guard scannerMode == "lidar", let mesh = anchor as? ARMeshAnchor else { return }
    node.geometry = showMeshOverlay ? lidarGeometry(mesh.geometry) : nil
  }

  // MARK: - Depth Integration (runs on fusionQueue)

  private func integrateDepth(_ rawDepth: AVDepthData, cameraTransform: simd_float4x4) {
    var depthData = rawDepth
    if depthData.depthDataType != kCVPixelFormatType_DepthFloat32 {
      depthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    }

    let map = depthData.depthDataMap
    CVPixelBufferLockBaseAddress(map, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

    let dw  = CVPixelBufferGetWidth(map)
    let dh  = CVPixelBufferGetHeight(map)
    let bpr = CVPixelBufferGetBytesPerRow(map)
    let base = CVPixelBufferGetBaseAddress(map)!

    // Camera intrinsics from the depth sensor's own calibration
    var fx: Float, fy: Float, cx: Float, cy: Float
    if let cal = depthData.cameraCalibrationData {
      let refW  = Float(cal.intrinsicMatrixReferenceDimensions.width)
      let scale = Float(dw) / refW
      let m = cal.intrinsicMatrix       // column-major: m[col][row]
      fx = m[0][0] * scale
      fy = m[1][1] * scale
      cx = m[2][0] * scale
      cy = m[2][1] * scale
    } else {
      fx = Float(dw) * 1.1;  fy = Float(dw) * 1.1
      cx = Float(dw) / 2.0;  cy = Float(dh) / 2.0
    }

    let step = 3  // sample every 3rd pixel for speed/quality balance

    for py in Swift.stride(from: 0, to: dh, by: step) {
      let row = base.advanced(by: py * bpr).assumingMemoryBound(to: Float.self)
      for px in Swift.stride(from: 0, to: dw, by: step) {
        let d = row[px]
        guard d.isFinite, d > 0.15, d < 0.9 else { continue }

        // Back-project to camera space (camera looks in -Z)
        let xc = (Float(px) - cx) * d / fx
        let yc = -(Float(py) - cy) * d / fy
        let zc = -d

        // Transform to world space
        let w4 = cameraTransform * SIMD4<Float>(xc, yc, zc, 1.0)
        let wp = SIMD3<Float>(w4.x, w4.y, w4.z)

        // Quantise to voxel grid
        let key = SIMD3<Int32>(
          Int32(floor(wp.x / voxelSize)),
          Int32(floor(wp.y / voxelSize)),
          Int32(floor(wp.z / voxelSize)))

        if var e = worldVoxels[key] {
          e.sum += wp; e.count += 1
          worldVoxels[key] = e
        } else {
          worldVoxels[key] = (wp, 1)
        }
      }
    }

    fusedFrameCount += 1
    guard fusedFrameCount - lastVisualizeCount >= 20 else { return }
    lastVisualizeCount = fusedFrameCount

    // Snapshot up to 40 k points for visualization
    let pts = Array(worldVoxels.values.prefix(40000)).map { $0.sum / Float($0.count) }
    DispatchQueue.main.async { [weak self] in self?.updatePointCloud(pts) }
  }

  // MARK: - Real-time Point Cloud Visualisation

  private func updatePointCloud(_ points: [SIMD3<Float>]) {
    guard !points.isEmpty else { return }

    let verts   = points.map { SCNVector3($0.x, $0.y, $0.z) }
    let src     = SCNGeometrySource(vertices: verts)
    let idxData = Data(bytes: (0..<verts.count).map { Int32($0) }, count: verts.count * 4)
    let elem    = SCNGeometryElement(data: idxData, primitiveType: .point,
                                     primitiveCount: verts.count, bytesPerIndex: 4)
    elem.pointSize = 5
    elem.minimumPointScreenSpaceRadius = 2
    elem.maximumPointScreenSpaceRadius = 8

    let geo = SCNGeometry(sources: [src], elements: [elem])
    let mat = SCNMaterial()
    mat.diffuse.contents = UIColor.systemGreen
    mat.lightingModel    = .constant
    geo.materials = [mat]

    let node = SCNNode(geometry: geo)
    pointCloudNode?.removeFromParentNode()
    sceneView.scene.rootNode.addChildNode(node)
    pointCloudNode = node
  }

  // MARK: - Voxel Surface → STL Export

  private func voxelsToSTL(
    _ voxels: [SIMD3<Int32>: (sum: SIMD3<Float>, count: Int32)],
    filename: String) throws -> String {

    let occupied = Set(voxels.keys)
    let hs = voxelSize * 0.5

    typealias FaceDef = (offset: SIMD3<Int32>, normal: SIMD3<Float>)
    let faceDefs: [FaceDef] = [
      (SIMD3( 1, 0, 0), SIMD3( 1, 0, 0)),
      (SIMD3(-1, 0, 0), SIMD3(-1, 0, 0)),
      (SIMD3( 0, 1, 0), SIMD3( 0, 1, 0)),
      (SIMD3( 0,-1, 0), SIMD3( 0,-1, 0)),
      (SIMD3( 0, 0, 1), SIMD3( 0, 0, 1)),
      (SIMD3( 0, 0,-1), SIMD3( 0, 0,-1)),
    ]

    var triCount = 0
    for (key, _) in voxels {
      for f in faceDefs {
        let nk = SIMD3<Int32>(key.x + f.offset.x, key.y + f.offset.y, key.z + f.offset.z)
        if !occupied.contains(nk) { triCount += 2 }
      }
    }

    guard triCount > 0 else {
      throw NSError(domain: "Scan", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "メッシュを生成できませんでした。スキャンデータが少なすぎます。"])
    }

    var bytes = [UInt8](repeating: 0, count: 84 + triCount * 50)
    let tc = UInt32(triCount)
    bytes[80] = UInt8(tc & 0xFF);       bytes[81] = UInt8((tc >> 8)  & 0xFF)
    bytes[82] = UInt8((tc >> 16) & 0xFF); bytes[83] = UInt8((tc >> 24) & 0xFF)
    var off = 84

    for (key, entry) in voxels {
      let center = entry.sum / Float(entry.count)
      for f in faceDefs {
        let nk = SIMD3<Int32>(key.x + f.offset.x, key.y + f.offset.y, key.z + f.offset.z)
        guard !occupied.contains(nk) else { continue }

        let fc   = center + f.normal * hs
        let (u, v) = perpVectors(f.normal)
        let a = fc + (u + v) * hs;   let b = fc + (u - v) * hs
        let c = fc + (-u - v) * hs;  let d = fc + (-u + v) * hs
        writeTriangle(&bytes, &off, f.normal, a, b, c)
        writeTriangle(&bytes, &off, f.normal, a, c, d)
      }
    }

    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let name = filename.hasSuffix(".stl") ? filename : "\(filename).stl"
    let url  = docs.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    try Data(bytes).write(to: url)
    return url.path
  }

  private func perpVectors(_ n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
    let u = abs(n.x) < 0.9
      ? simd_normalize(simd_cross(n, SIMD3(1, 0, 0)))
      : simd_normalize(simd_cross(n, SIMD3(0, 1, 0)))
    return (u, simd_cross(n, u))
  }

  private func writeTriangle(_ bytes: inout [UInt8], _ off: inout Int,
                              _ n: SIMD3<Float>,
                              _ v0: SIMD3<Float>, _ v1: SIMD3<Float>, _ v2: SIMD3<Float>) {
    func wf(_ f: Float) {
      withUnsafeBytes(of: f) {
        bytes[off] = $0[0]; bytes[off+1] = $0[1]
        bytes[off+2] = $0[2]; bytes[off+3] = $0[3]
      }
      off += 4
    }
    wf(n.x);  wf(n.y);  wf(n.z)
    wf(v0.x); wf(v0.y); wf(v0.z)
    wf(v1.x); wf(v1.y); wf(v1.z)
    wf(v2.x); wf(v2.y); wf(v2.z)
    bytes[off] = 0; bytes[off+1] = 0; off += 2
  }

  // MARK: - LiDAR Overlay Geometry

  private func lidarGeometry(_ meshGeometry: ARMeshGeometry) -> SCNGeometry {
    let vCount = meshGeometry.vertices.count
    let vPtr   = meshGeometry.vertices.buffer.contents()
      .bindMemory(to: SIMD3<Float>.self, capacity: vCount)
    let verts  = (0..<vCount).map { SCNVector3(vPtr[$0].x, vPtr[$0].y, vPtr[$0].z) }
    let src    = SCNGeometrySource(vertices: verts)

    let fCount = meshGeometry.faces.count
    let iBuf   = meshGeometry.faces.buffer.contents()
    let bpi    = meshGeometry.faces.bytesPerIndex
    var idx: [UInt32] = []
    for i in 0..<(fCount * 3) {
      let o = i * bpi
      idx.append(bpi == 4
        ? iBuf.load(fromByteOffset: o, as: UInt32.self)
        : UInt32(iBuf.load(fromByteOffset: o, as: UInt16.self)))
    }
    let idxData = Data(bytes: idx, count: idx.count * 4)
    let elem    = SCNGeometryElement(data: idxData, primitiveType: .triangles,
                                     primitiveCount: fCount, bytesPerIndex: 4)
    let geo  = SCNGeometry(sources: [src], elements: [elem])
    let mat  = SCNMaterial()
    mat.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.3)
    mat.isDoubleSided = true
    mat.fillMode      = .lines
    geo.materials = [mat]
    return geo
  }

  // MARK: - LiDAR STL Export

  private func convertMeshToSTL(anchors: [ARMeshAnchor], filename: String) throws -> String {
    let allocator = MDLMeshBufferDataAllocator()
    let asset     = MDLAsset()
    for anchor in anchors {
      let g         = anchor.geometry
      let transform = anchor.transform
      let vCount    = g.vertices.count
      let vPtr      = g.vertices.buffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: vCount)
      let verts     = (0..<vCount).map { i -> SIMD3<Float> in
        let w = transform * SIMD4<Float>(vPtr[i].x, vPtr[i].y, vPtr[i].z, 1)
        return SIMD3<Float>(w.x, w.y, w.z)
      }
      let fCount = g.faces.count
      let iBuf   = g.faces.buffer.contents()
      let bpi    = g.faces.bytesPerIndex
      var idx: [UInt32] = []
      for i in 0..<(fCount * 3) {
        let o = i * bpi
        idx.append(bpi == 4
          ? iBuf.load(fromByteOffset: o, as: UInt32.self)
          : UInt32(iBuf.load(fromByteOffset: o, as: UInt16.self)))
      }
      if let mesh = buildMDLMesh(verts, idx, vCount, allocator) { asset.add(mesh) }
    }
    return try exportAsset(asset, filename: filename)
  }

  private func buildMDLMesh(_ verts: [SIMD3<Float>], _ idx: [UInt32],
                             _ vCount: Int,
                             _ alloc: MDLMeshBufferDataAllocator) -> MDLMesh? {
    let vData  = Data(bytes: verts, count: verts.count * MemoryLayout<SIMD3<Float>>.stride)
    let vBuf   = alloc.newBuffer(with: vData, type: .vertex)
    let desc   = MDLVertexDescriptor()
    desc.attributes = NSMutableArray(array: [
      MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
    ])
    desc.layouts = NSMutableArray(array: [
      MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)
    ])
    let iData  = Data(bytes: idx, count: idx.count * 4)
    let iBuf   = alloc.newBuffer(with: iData, type: .index)
    let sub    = MDLSubmesh(indexBuffer: iBuf, indexCount: idx.count,
                            indexType: .uInt32, geometryType: .triangles, material: nil)
    return MDLMesh(vertexBuffer: vBuf, vertexCount: vCount, descriptor: desc, submeshes: [sub])
  }

  private func exportAsset(_ asset: MDLAsset, filename: String) throws -> String {
    let docs  = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let name  = filename.hasSuffix(".stl") ? filename : "\(filename).stl"
    let url   = docs.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    try asset.export(to: url)
    return url.path
  }
}