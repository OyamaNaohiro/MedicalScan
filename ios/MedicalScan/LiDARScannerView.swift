import UIKit
import ARKit
import SceneKit
import ModelIO
import AVFoundation

class LiDARScannerView: UIView, ARSessionDelegate, ARSCNViewDelegate,
                        AVCaptureDepthDataOutputDelegate {

  // MARK: - ARKit path
  private var sceneView: ARSCNView!
  private var isSessionRunning = false
  private var collectedMeshAnchors: [ARMeshAnchor] = []
  private var collectedFaceAnchors: [ARFaceAnchor] = []

  // MARK: - AVFoundation path (trueDepthObject)
  private var captureSession: AVCaptureSession?
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var depthDataOutput: AVCaptureDepthDataOutput?
  private let captureQueue = DispatchQueue(label: "com.medicalscan.truedepth", qos: .userInitiated)
  private var collectedDepthSamples: [(AVDepthData, AVCameraCalibrationData?)] = []
  private let maxDepthSamples = 60

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
        collectedDepthSamples = []
        startARSession()
        ScanEventEmitter.emitEvent(["type": "scanStarted"])
      } else {
        pauseARSession()
        ScanEventEmitter.emitEvent(["type": "scanStopped"])
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
      let depthSamples = collectedDepthSamples
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        do {
          let filePath: String
          if mode == "trueDepth" {
            guard !faceAnchors.isEmpty else {
              ScanEventEmitter.emitEvent(["type": "error", "message": "顔メッシュデータがありません。"])
              return
            }
            filePath = try self.convertFaceMeshToSTL(anchors: faceAnchors, filename: filename)
          } else if mode == "trueDepthObject" {
            guard !depthSamples.isEmpty else {
              ScanEventEmitter.emitEvent(["type": "error", "message": "深度データがありません。スキャンを実行してください。"])
              return
            }
            filePath = try self.convertDepthSamplesToSTL(samples: depthSamples, filename: filename)
          } else {
            guard !meshAnchors.isEmpty else {
              ScanEventEmitter.emitEvent(["type": "error", "message": "メッシュデータがありません。スキャンを実行してください。"])
              return
            }
            filePath = try self.convertMeshToSTL(anchors: meshAnchors, filename: filename)
          }
          ScanEventEmitter.emitEvent(["type": "exported", "path": filePath])
        } catch {
          ScanEventEmitter.emitEvent(["type": "error", "message": error.localizedDescription])
        }
      }
    }
  }

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
    previewLayer?.frame = bounds
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { pauseARSession() }
  }

  // MARK: - Session Management

  private func startARSession() {
    guard !isSessionRunning else { return }

    if scannerMode == "trueDepthObject" {
      startTrueDepthObjectSession()

    } else if scannerMode == "trueDepth" {
      guard ARFaceTrackingConfiguration.isSupported else {
        ScanEventEmitter.emitEvent(["type": "error",
                                    "message": "TrueDepthカメラはこのデバイスでは利用できません。"])
        return
      }
      let config = ARFaceTrackingConfiguration()
      config.isLightEstimationEnabled = true
      sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
      isSessionRunning = true

    } else {
      guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
        ScanEventEmitter.emitEvent(["type": "error",
                                    "message": "LiDARスキャナーはこのデバイスでは利用できません。"])
        return
      }
      let config = ARWorldTrackingConfiguration()
      config.sceneReconstruction = .mesh
      config.environmentTexturing = .automatic
      sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
      isSessionRunning = true
    }
  }

  private func startTrueDepthObjectSession() {
    guard let device = AVCaptureDevice.default(
      .builtInTrueDepthCamera, for: .video, position: .front) else {
      ScanEventEmitter.emitEvent(["type": "error",
                                  "message": "TrueDepthカメラが利用できません。"])
      return
    }

    let session = AVCaptureSession()
    session.beginConfiguration()
    session.sessionPreset = .vga640x480

    guard let input = try? AVCaptureDeviceInput(device: device),
          session.canAddInput(input) else {
      ScanEventEmitter.emitEvent(["type": "error",
                                  "message": "カメラ入力の設定に失敗しました。"])
      return
    }
    session.addInput(input)

    let depthOut = AVCaptureDepthDataOutput()
    depthOut.isFilteringEnabled = true
    guard session.canAddOutput(depthOut) else { return }
    session.addOutput(depthOut)
    depthOut.setDelegate(self, callbackQueue: captureQueue)

    session.commitConfiguration()

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.sceneView.isHidden = true
      self.previewLayer?.removeFromSuperlayer()
      let preview = AVCaptureVideoPreviewLayer(session: session)
      preview.videoGravity = .resizeAspectFill
      preview.frame = self.bounds
      self.layer.insertSublayer(preview, at: 0)
      self.previewLayer = preview
    }

    captureQueue.async { session.startRunning() }
    captureSession = session
    depthDataOutput = depthOut
    isSessionRunning = true
  }

  private func pauseARSession() {
    guard isSessionRunning else { return }
    if let session = captureSession {
      let s = session
      captureQueue.async { s.stopRunning() }
      captureSession = nil
      depthDataOutput = nil
      DispatchQueue.main.async { [weak self] in
        self?.previewLayer?.removeFromSuperlayer()
        self?.previewLayer = nil
        self?.sceneView.isHidden = false
      }
    } else {
      sceneView.session.pause()
    }
    isSessionRunning = false
  }

  // MARK: - AVCaptureDepthDataOutputDelegate

  func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                       didOutput depthData: AVDepthData,
                       timestamp: CMTime,
                       connection: AVCaptureConnection) {
    guard isScanning, collectedDepthSamples.count < maxDepthSamples else { return }
    collectedDepthSamples.append((depthData, depthData.cameraCalibrationData))
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

  // MARK: - Geometry Builders (AR overlay)

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
    return buildARGeometry(vertexSource: vertexSource, indices: indices, faceCount: faceCount)
  }

  private func createFaceGeometry(from faceGeometry: ARFaceGeometry) -> SCNGeometry {
    let vertices = faceGeometry.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
    let vertexSource = SCNGeometrySource(vertices: vertices)
    let indices = faceGeometry.triangleIndices.map { UInt32($0) }
    return buildARGeometry(vertexSource: vertexSource, indices: indices,
                           faceCount: faceGeometry.triangleCount)
  }

  private func buildARGeometry(vertexSource: SCNGeometrySource,
                                indices: [UInt32], faceCount: Int) -> SCNGeometry {
    let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.stride)
    let element = SCNGeometryElement(data: indexData, primitiveType: .triangles,
                                     primitiveCount: faceCount,
                                     bytesPerIndex: MemoryLayout<UInt32>.stride)
    let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
    let material = SCNMaterial()
    material.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.3)
    material.isDoubleSided = true
    material.fillMode = .lines
    geometry.materials = [material]
    return geometry
  }

  // MARK: - TrueDepth Object Export (depth map → STL)

  private func convertDepthSamplesToSTL(
    samples: [(AVDepthData, AVCameraCalibrationData?)],
    filename: String) throws -> String {

    // Use middle sample for best temporal stability
    let (rawDepth, calibration) = samples[samples.count / 2]

    var depthData = rawDepth
    if depthData.depthDataType != kCVPixelFormatType_DepthFloat32 {
      depthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    }

    let depthMap = depthData.depthDataMap
    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

    let width       = CVPixelBufferGetWidth(depthMap)
    let height      = CVPixelBufferGetHeight(depthMap)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
    let base        = CVPixelBufferGetBaseAddress(depthMap)!

    // Camera intrinsics, scaled to depth-map resolution
    var fx: Float = Float(width) * 1.1
    var fy: Float = Float(width) * 1.1
    var cx: Float = Float(width)  / 2.0
    var cy: Float = Float(height) / 2.0

    if let cal = calibration {
      let refW  = Float(cal.intrinsicMatrixReferenceDimensions.width)
      let scale = Float(width) / refW
      let m = cal.intrinsicMatrix   // column-major: m[col][row]
      fx = m[0][0] * scale
      fy = m[1][1] * scale
      cx = m[2][0] * scale
      cy = m[2][1] * scale
    }

    // Sample every sampleStride pixels to balance resolution vs. memory
    let sampleStride = 2
    let cols = (width  - 1) / sampleStride + 1
    let rows = (height - 1) / sampleStride + 1

    // Back-project depth pixels to 3D (right-handed, Y-up, Z toward viewer)
    var grid = [[SIMD3<Float>?]](
      repeating: [SIMD3<Float>?](repeating: nil, count: cols),
      count: rows)

    for gy in 0..<rows {
      let py = gy * sampleStride
      let rowPtr = base.advanced(by: py * bytesPerRow)
        .assumingMemoryBound(to: Float.self)
      for gx in 0..<cols {
        let px = gx * sampleStride
        let d  = rowPtr[px]
        guard d.isFinite, d > 0.15, d < 1.2 else { continue }
        grid[gy][gx] = SIMD3<Float>(
          (Float(px) - cx) * d / fx,
          -(Float(py) - cy) * d / fy,
          -d
        )
      }
    }

    // Skip triangles that bridge depth discontinuities
    let maxGap: Float = 0.03
    func zGap(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { abs(a.z - b.z) }

    // Pass 1: count triangles
    var triCount = 0
    for gy in 0..<(rows - 1) {
      for gx in 0..<(cols - 1) {
        let tl = grid[gy][gx],     tr = grid[gy][gx + 1]
        let bl = grid[gy + 1][gx], br = grid[gy + 1][gx + 1]
        if let a = tl, let b = tr, let c = bl,
           zGap(a, b) < maxGap, zGap(a, c) < maxGap { triCount += 1 }
        if let a = tr, let b = br, let c = bl,
           zGap(a, b) < maxGap, zGap(a, c) < maxGap { triCount += 1 }
      }
    }

    guard triCount > 0 else {
      throw NSError(domain: "TrueDepth", code: 1, userInfo: [
        NSLocalizedDescriptionKey:
          "有効な深度データを取得できませんでした。オブジェクトを15〜120cm以内に近づけてください。"
      ])
    }

    // Pass 2: write binary STL
    var bytes = [UInt8](repeating: 0, count: 84 + triCount * 50)
    let tc = UInt32(triCount)
    bytes[80] = UInt8(tc & 0xFF)
    bytes[81] = UInt8((tc >> 8)  & 0xFF)
    bytes[82] = UInt8((tc >> 16) & 0xFF)
    bytes[83] = UInt8((tc >> 24) & 0xFF)

    var offset = 84
    for gy in 0..<(rows - 1) {
      for gx in 0..<(cols - 1) {
        let tl = grid[gy][gx],     tr = grid[gy][gx + 1]
        let bl = grid[gy + 1][gx], br = grid[gy + 1][gx + 1]
        if let a = tl, let b = tr, let c = bl,
           zGap(a, b) < maxGap, zGap(a, c) < maxGap {
          writeDepthTriangle(into: &bytes, at: &offset, v0: a, v1: b, v2: c)
        }
        if let a = tr, let b = br, let c = bl,
           zGap(a, b) < maxGap, zGap(a, c) < maxGap {
          writeDepthTriangle(into: &bytes, at: &offset, v0: a, v1: b, v2: c)
        }
      }
    }

    let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let sanitized = filename.hasSuffix(".stl") ? filename : "\(filename).stl"
    let url = docsDir.appendingPathComponent(sanitized)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    try Data(bytes).write(to: url)
    return url.path
  }

  private func writeDepthFloat(_ v: Float, into bytes: inout [UInt8], at offset: inout Int) {
    withUnsafeBytes(of: v) { src in
      bytes[offset]   = src[0]; bytes[offset + 1] = src[1]
      bytes[offset + 2] = src[2]; bytes[offset + 3] = src[3]
    }
    offset += 4
  }

  private func writeDepthTriangle(into bytes: inout [UInt8], at offset: inout Int,
                                   v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>) {
    let e1 = v1 - v0, e2 = v2 - v0
    var n  = simd_cross(e1, e2)
    let len = simd_length(n)
    if len > 0 { n /= len }
    writeDepthFloat(n.x,  into: &bytes, at: &offset)
    writeDepthFloat(n.y,  into: &bytes, at: &offset)
    writeDepthFloat(n.z,  into: &bytes, at: &offset)
    writeDepthFloat(v0.x, into: &bytes, at: &offset)
    writeDepthFloat(v0.y, into: &bytes, at: &offset)
    writeDepthFloat(v0.z, into: &bytes, at: &offset)
    writeDepthFloat(v1.x, into: &bytes, at: &offset)
    writeDepthFloat(v1.y, into: &bytes, at: &offset)
    writeDepthFloat(v1.z, into: &bytes, at: &offset)
    writeDepthFloat(v2.x, into: &bytes, at: &offset)
    writeDepthFloat(v2.y, into: &bytes, at: &offset)
    writeDepthFloat(v2.z, into: &bytes, at: &offset)
    bytes[offset] = 0; bytes[offset + 1] = 0; offset += 2
  }

  // MARK: - LiDAR STL Export

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
        let off = i * bytesPerIndex
        if bytesPerIndex == 4 {
          indices.append(indexBuffer.load(fromByteOffset: off, as: UInt32.self))
        } else if bytesPerIndex == 2 {
          indices.append(UInt32(indexBuffer.load(fromByteOffset: off, as: UInt16.self)))
        }
      }
      if let mdlMesh = buildMDLMesh(vertices: vertices, indices: indices,
                                    vertexCount: vertexCount, allocator: allocator) {
        asset.add(mdlMesh)
      }
    }
    return try exportAsset(asset, filename: filename)
  }

  // MARK: - Face STL Export

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

  private func buildMDLMesh(vertices: [SIMD3<Float>], indices: [UInt32],
                             vertexCount: Int,
                             allocator: MDLMeshBufferDataAllocator) -> MDLMesh? {
    let vertexData = Data(bytes: vertices,
                          count: vertices.count * MemoryLayout<SIMD3<Float>>.stride)
    let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)
    let vertexDescriptor = MDLVertexDescriptor()
    let posAttr = MDLVertexAttribute(name: MDLVertexAttributePosition,
                                     format: .float3, offset: 0, bufferIndex: 0)
    vertexDescriptor.attributes = NSMutableArray(array: [posAttr])
    vertexDescriptor.layouts = NSMutableArray(array: [
      MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)
    ])
    let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.stride)
    let indexBuffer = allocator.newBuffer(with: indexData, type: .index)
    let submesh = MDLSubmesh(indexBuffer: indexBuffer, indexCount: indices.count,
                             indexType: .uInt32, geometryType: .triangles, material: nil)
    return MDLMesh(vertexBuffer: vertexBuffer, vertexCount: vertexCount,
                   descriptor: vertexDescriptor, submeshes: [submesh])
  }

  private func exportAsset(_ asset: MDLAsset, filename: String) throws -> String {
    let documentsDir = FileManager.default.urls(for: .documentDirectory,
                                                in: .userDomainMask).first!
    let sanitized = filename.hasSuffix(".stl") ? filename : "\(filename).stl"
    let fileURL = documentsDir.appendingPathComponent(sanitized)
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
    try asset.export(to: fileURL)
    return fileURL.path
  }
}