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

  // MARK: - AVFoundation path (trueDepthObject)
  private var captureSession: AVCaptureSession?
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var depthDataOutput: AVCaptureDepthDataOutput?
  private let captureQueue = DispatchQueue(label: "com.medicalscan.truedepth", qos: .userInitiated)
  private var depthOverlayView: UIImageView?

  // Temporal fusion buffers (written on captureQueue)
  private var accumulatedSum: [Float] = []
  private var accumulatedCount: [Int32] = []
  private var depthW = 0, depthH = 0
  private var accumulatedCalibration: AVCameraCalibrationData?
  private var frameCount = 0

  // MARK: - React Props

  @objc var showMeshOverlay: Bool = true

  @objc var scannerMode: String = "lidar" {
    didSet {
      guard scannerMode != oldValue else { return }
      if isSessionRunning { pauseARSession() }
      if window != nil && scannerMode == "trueDepthObject" {
        startTrueDepthObjectSession()
      }
    }
  }

  @objc var isScanning: Bool = false {
    didSet {
      guard isScanning != oldValue else { return }
      if isScanning {
        collectedMeshAnchors = []
        // Clear fusion data before new scan (captureQueue is serial so this runs before new frames)
        captureQueue.async { [weak self] in
          guard let self = self else { return }
          self.accumulatedSum = []
          self.accumulatedCount = []
          self.depthW = 0; self.depthH = 0
          self.accumulatedCalibration = nil
          self.frameCount = 0
        }
        DispatchQueue.main.async { [weak self] in
          self?.depthOverlayView?.image = nil
        }
        if scannerMode != "trueDepthObject" {
          startARSession()
        }
        ScanEventEmitter.emitEvent(["type": "scanStarted"])
      } else {
        if scannerMode != "trueDepthObject" {
          pauseARSession()
        }
        // For trueDepthObject: keep preview running, just stop collecting
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

      if mode == "trueDepthObject" {
        // Copy accumulated arrays safely from captureQueue (ensures no in-flight writes)
        captureQueue.async { [weak self] in
          guard let self = self else { return }
          let sumCopy = self.accumulatedSum
          let cntCopy = self.accumulatedCount
          let w = self.depthW, h = self.depthH
          let cal = self.accumulatedCalibration
          DispatchQueue.global(qos: .userInitiated).async {
            do {
              guard !sumCopy.isEmpty else {
                ScanEventEmitter.emitEvent(["type": "error",
                  "message": "深度データがありません。スキャンを実行してください。"])
                return
              }
              let path = try self.convertFusedDepthToSTL(
                sum: sumCopy, count: cntCopy, width: w, height: h,
                calibration: cal, filename: filename)
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
    if window == nil {
      pauseARSession()
    } else if scannerMode == "trueDepthObject" && !isSessionRunning {
      startTrueDepthObjectSession()
    }
  }

  // MARK: - Session Management

  private func startARSession() {
    guard !isSessionRunning else { return }
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

  private func startTrueDepthObjectSession() {
    guard !isSessionRunning else { return }
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
    guard session.canAddOutput(depthOut) else {
      ScanEventEmitter.emitEvent(["type": "error",
        "message": "深度データ出力の設定に失敗しました。"])
      return
    }
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

      // Depth heatmap overlay (mirrors to match front camera preview)
      let overlay = UIImageView(frame: self.bounds)
      overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      overlay.contentMode = .scaleAspectFill
      overlay.alpha = 0.65
      overlay.transform = CGAffineTransform(scaleX: -1, y: 1)
      self.addSubview(overlay)
      self.depthOverlayView = overlay
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
        self?.depthOverlayView?.removeFromSuperview()
        self?.depthOverlayView = nil
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
    guard isScanning else { return }

    var data = depthData
    if data.depthDataType != kCVPixelFormatType_DepthFloat32 {
      data = data.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    }

    let map = data.depthDataMap
    CVPixelBufferLockBaseAddress(map, .readOnly)

    let w   = CVPixelBufferGetWidth(map)
    let h   = CVPixelBufferGetHeight(map)
    let bpr = CVPixelBufferGetBytesPerRow(map)

    // Initialize fusion buffers on first frame
    if accumulatedSum.isEmpty {
      depthW = w; depthH = h
      accumulatedSum   = [Float](repeating: 0, count: w * h)
      accumulatedCount = [Int32](repeating: 0, count: w * h)
      accumulatedCalibration = data.cameraCalibrationData
    }

    let base = CVPixelBufferGetBaseAddress(map)!
    for y in 0..<h {
      let row = base.advanced(by: y * bpr).assumingMemoryBound(to: Float.self)
      for x in 0..<w {
        let d = row[x]
        if d.isFinite && d > 0.15 && d < 1.5 {
          let i = y * w + x
          accumulatedSum[i]   += d
          accumulatedCount[i] += 1
        }
      }
    }

    CVPixelBufferUnlockBaseAddress(map, .readOnly)

    // Update overlay every 5 frames (~6 Hz)
    frameCount += 1
    if frameCount % 5 == 0, let img = makeOverlayImage() {
      DispatchQueue.main.async { [weak self] in
        self?.depthOverlayView?.image = img
      }
    }
  }

  // Depth heatmap: red=close(0.15m), green=mid, blue=far(1.5m)
  // Alpha builds up as more frames accumulate (solidifies over ~1.5 sec)
  private func makeOverlayImage() -> UIImage? {
    let w = depthW, h = depthH
    guard w > 0, h > 0 else { return nil }

    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    for i in 0..<(w * h) {
      let cnt = Int(accumulatedCount[i])
      guard cnt > 0 else { continue }
      let d = accumulatedSum[i] / Float(cnt)
      let t = max(0, min(1, (d - 0.15) / 1.35))  // 0=close, 1=far
      let r = UInt8(255 * max(0, min(1.0, 1 - t * 2)))
      let g = UInt8(255 * max(0, min(1.0, 1 - abs(t * 2 - 1))))
      let b = UInt8(255 * max(0, min(1.0, t * 2 - 1)))
      let a = UInt8(min(220, cnt * 5))
      let bi = i * 4
      rgba[bi] = r; rgba[bi+1] = g; rgba[bi+2] = b; rgba[bi+3] = a
    }

    guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let cg = CGImage(
      width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: w * 4, space: cs,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent) else { return nil }
    // Depth sensor is landscape; rotate to portrait
    return UIImage(cgImage: cg, scale: 1, orientation: .right)
  }

  // MARK: - ARSessionDelegate

  func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
    guard isScanning else { return }
    for anchor in anchors {
      if let meshAnchor = anchor as? ARMeshAnchor {
        collectedMeshAnchors.append(meshAnchor)
      }
    }
  }

  func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
    guard isScanning else { return }
    for anchor in anchors {
      if let meshAnchor = anchor as? ARMeshAnchor {
        collectedMeshAnchors.removeAll { $0.identifier == meshAnchor.identifier }
        collectedMeshAnchors.append(meshAnchor)
      }
    }
  }

  func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
    for anchor in anchors {
      collectedMeshAnchors.removeAll { $0.identifier == anchor.identifier }
    }
  }

  // MARK: - ARSCNViewDelegate

  func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
    guard showMeshOverlay, let meshAnchor = anchor as? ARMeshAnchor else { return SCNNode() }
    return SCNNode(geometry: createLiDARGeometry(from: meshAnchor.geometry))
  }

  func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
    if let meshAnchor = anchor as? ARMeshAnchor {
      node.geometry = showMeshOverlay ? createLiDARGeometry(from: meshAnchor.geometry) : nil
    }
  }

  // MARK: - LiDAR Overlay Geometry

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

  // MARK: - Fused Depth → STL Export

  private func convertFusedDepthToSTL(
    sum: [Float], count: [Int32],
    width: Int, height: Int,
    calibration: AVCameraCalibrationData?,
    filename: String) throws -> String {

    var fx: Float = Float(width) * 1.1
    var fy: Float = Float(width) * 1.1
    var cx: Float = Float(width)  / 2.0
    var cy: Float = Float(height) / 2.0

    if let cal = calibration {
      let refW  = Float(cal.intrinsicMatrixReferenceDimensions.width)
      let scale = Float(width) / refW
      let m = cal.intrinsicMatrix
      fx = m[0][0] * scale; fy = m[1][1] * scale
      cx = m[2][0] * scale; cy = m[2][1] * scale
    }

    let sampleStride = 2
    let cols = (width  - 1) / sampleStride + 1
    let rows = (height - 1) / sampleStride + 1

    var grid = [[SIMD3<Float>?]](
      repeating: [SIMD3<Float>?](repeating: nil, count: cols),
      count: rows)

    for gy in 0..<rows {
      let py = gy * sampleStride
      for gx in 0..<cols {
        let px = gx * sampleStride
        let i  = py * width + px
        guard i < count.count, count[i] > 0 else { continue }
        let d = sum[i] / Float(count[i])
        guard d.isFinite, d > 0.15, d < 1.5 else { continue }
        grid[gy][gx] = SIMD3<Float>(
          (Float(px) - cx) * d / fx,
          -(Float(py) - cy) * d / fy,
          -d)
      }
    }

    let maxGap: Float = 0.03
    func zGap(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { abs(a.z - b.z) }

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
      bytes[offset]     = src[0]; bytes[offset + 1] = src[1]
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
      let transform    = anchor.transform
      let vertexCount  = meshGeometry.vertices.count
      let faceCount    = meshGeometry.faces.count
      var vertices: [SIMD3<Float>] = []
      let vertexPointer = meshGeometry.vertices.buffer.contents()
        .bindMemory(to: SIMD3<Float>.self, capacity: vertexCount)
      for i in 0..<vertexCount {
        let local = vertexPointer[i]
        let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1.0)
        vertices.append(SIMD3<Float>(world.x, world.y, world.z))
      }
      let indexBuffer   = meshGeometry.faces.buffer.contents()
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

  private func buildMDLMesh(vertices: [SIMD3<Float>], indices: [UInt32],
                             vertexCount: Int,
                             allocator: MDLMeshBufferDataAllocator) -> MDLMesh? {
    let vertexData   = Data(bytes: vertices, count: vertices.count * MemoryLayout<SIMD3<Float>>.stride)
    let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)
    let vertexDescriptor = MDLVertexDescriptor()
    let posAttr = MDLVertexAttribute(name: MDLVertexAttributePosition,
                                     format: .float3, offset: 0, bufferIndex: 0)
    vertexDescriptor.attributes = NSMutableArray(array: [posAttr])
    vertexDescriptor.layouts    = NSMutableArray(array: [
      MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)
    ])
    let indexData   = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.stride)
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
    let fileURL   = documentsDir.appendingPathComponent(sanitized)
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
    try asset.export(to: fileURL)
    return fileURL.path
  }
}