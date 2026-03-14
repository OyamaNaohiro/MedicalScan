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
  private var worldVoxels: [SIMD3<Int32>: (center: SIMD3<Float>, count: Int32)] = [:]
  private let voxelSize: Float = 0.005        // 5 mm per voxel (TrueDepth accuracy floor)
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

  @objc var shareFilePath: String = "" {
    didSet {
      guard !shareFilePath.isEmpty else { return }
      let url = URL(fileURLWithPath: shareFilePath)
      DispatchQueue.main.async { [weak self] in
        guard let self = self,
              let rootVC = self.window?.rootViewController else { return }
        var topVC = rootVC
        while let presented = topVC.presentedViewController { topVC = presented }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
          pop.sourceView = self
          pop.sourceRect = CGRect(x: self.bounds.midX, y: self.bounds.midY, width: 0, height: 0)
        }
        topVC.present(vc, animated: true)
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

    // ── Foreground detection: depth histogram with stride-8 pass ──────────
    // Find the dominant depth cluster, then only integrate pixels within
    // ±18 cm of it. This keeps the target object and discards background.
    let dMin: Float = 0.15, dMax: Float = 0.85
    let nBins = 14
    var hist = [Int](repeating: 0, count: nBins)
    for py8 in Swift.stride(from: 0, to: dh, by: 8) {
      let r8 = base.advanced(by: py8 * bpr).assumingMemoryBound(to: Float.self)
      for px8 in Swift.stride(from: 0, to: dw, by: 8) {
        let d8 = r8[px8]
        guard d8.isFinite, d8 > dMin, d8 < dMax else { continue }
        hist[min(nBins - 1, Int((d8 - dMin) / (dMax - dMin) * Float(nBins)))] += 1
      }
    }
    let peakBin  = hist.indices.max(by: { hist[$0] < hist[$1] })!
    let peakD    = dMin + (Float(peakBin) + 0.5) * (dMax - dMin) / Float(nBins)
    let filterLo = max(dMin, peakD - 0.18)
    let filterHi = min(dMax, peakD + 0.18)
    // ──────────────────────────────────────────────────────────────────────

    let step = 3  // sample every 3rd pixel for speed/quality balance

    for py in Swift.stride(from: 0, to: dh, by: step) {
      let row = base.advanced(by: py * bpr).assumingMemoryBound(to: Float.self)
      for px in Swift.stride(from: 0, to: dw, by: step) {
        let d = row[px]
        guard d.isFinite, d > filterLo, d < filterHi else { continue }

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

        // Temporal smoothing: EMA blend + jitter rejection
        let rejectDist = voxelSize * 2.5
        if var e = worldVoxels[key] {
          guard simd_distance(wp, e.center) < rejectDist else { continue }
          e.center += 0.2 * (wp - e.center)  // EMA: 20% new, 80% stable
          e.count  += 1
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
    let pts = Array(worldVoxels.values.prefix(40000)).map { $0.center }
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
    _ voxels: [SIMD3<Int32>: (center: SIMD3<Float>, count: Int32)],
    filename: String) throws -> String {

    // ── 1. Filter: keep only voxels seen in ≥3 frames (removes noise) ─────
    let filtered = voxels.filter { $0.value.count >= 5 }
    let occupied = Set(filtered.keys)
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

    // ── 2. Build shared-vertex mesh ────────────────────────────────────────
    // Face vertices are grid-aligned (based on integer key, not centroid)
    // so adjacent cube faces share exact float positions → perfect dedup.
    var vertPos  = [SIMD3<Float>]()
    var vertKey  = [SIMD3<Int32>: Int]()   // half-voxel grid index → vertex index
    var triIdx   = [(Int, Int, Int)]()

    // Convert world pos → half-voxel integer key (exact for grid vertices)
    let invHS = 1.0 / hs
    func vkey(_ v: SIMD3<Float>) -> SIMD3<Int32> {
      SIMD3<Int32>(Int32(round(v.x * invHS)),
                   Int32(round(v.y * invHS)),
                   Int32(round(v.z * invHS)))
    }
    func addVert(_ v: SIMD3<Float>) -> Int {
      let k = vkey(v)
      if let i = vertKey[k] { return i }
      let i = vertPos.count
      vertPos.append(v); vertKey[k] = i; return i
    }

    for (key, _) in filtered {
      // Use grid-aligned voxel centre (not data centroid) for exact sharing
      let vc = SIMD3<Float>((Float(key.x) + 0.5) * voxelSize,
                             (Float(key.y) + 0.5) * voxelSize,
                             (Float(key.z) + 0.5) * voxelSize)
      for f in faceDefs {
        let nk = SIMD3<Int32>(key.x + f.offset.x, key.y + f.offset.y, key.z + f.offset.z)
        guard !occupied.contains(nk) else { continue }
        let fc = vc + f.normal * hs
        let (u, v) = perpVectors(f.normal)
        let ia = addVert(fc + (u + v) * hs),  ib = addVert(fc + (u - v) * hs)
        let ic = addVert(fc + (-u - v) * hs), id = addVert(fc + (-u + v) * hs)
        triIdx.append((ia, ib, ic))
        triIdx.append((ia, ic, id))
      }
    }

    guard !triIdx.isEmpty else {
      throw NSError(domain: "Scan", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "メッシュを生成できませんでした。スキャンデータが少なすぎます。"])
    }

    // ── 3. Midpoint subdivision (1 level: each triangle → 4) ─────────
    var midCache = [SIMD3<Int32>: Int]()
    func midpoint(_ a: Int, _ b: Int) -> Int {
      let lo = min(a, b), hi = max(a, b)
      let mk = SIMD3<Int32>(Int32(lo), Int32(hi), 0)
      if let i = midCache[mk] { return i }
      let m = (vertPos[a] + vertPos[b]) * 0.5
      let i = vertPos.count
      vertPos.append(m); midCache[mk] = i; return i
    }
    var subdTri = [(Int, Int, Int)]()
    subdTri.reserveCapacity(triIdx.count * 4)
    for (i0, i1, i2) in triIdx {
      let m01 = midpoint(i0, i1)
      let m12 = midpoint(i1, i2)
      let m20 = midpoint(i2, i0)
      subdTri.append((i0,  m01, m20))
      subdTri.append((i1,  m12, m01))
      subdTri.append((i2,  m20, m12))
      subdTri.append((m01, m12, m20))
    }
    triIdx = subdTri
    // ────────────────────────────────────────────────────────────────────

    // ── 4. Taubin smoothing (λ/μ alternating — no volume shrinkage) ───────
    var adjacency = [Set<Int>](repeating: [], count: vertPos.count)
    for (i0, i1, i2) in triIdx {
      adjacency[i0].insert(i1); adjacency[i0].insert(i2)
      adjacency[i1].insert(i0); adjacency[i1].insert(i2)
      adjacency[i2].insert(i0); adjacency[i2].insert(i1)
    }
    func smoothStep(factor: Float) {
      var next = vertPos
      for i in 0..<vertPos.count {
        guard !adjacency[i].isEmpty else { continue }
        let avg = adjacency[i].reduce(SIMD3<Float>.zero) { $0 + vertPos[$1] }
                  / Float(adjacency[i].count)
        next[i] = vertPos[i] + factor * (avg - vertPos[i])
      }
      vertPos = next
    }
    let lambda: Float = 0.5, mu: Float = -0.53
    for _ in 0..<8 {          // 8 Taubin iterations
      smoothStep(factor: lambda)
      smoothStep(factor: mu)
    }

    // ── 5. Write binary STL with recomputed normals ────────────────────────
    let triCount = triIdx.count
    var bytes = [UInt8](repeating: 0, count: 84 + triCount * 50)
    let tc = UInt32(triCount)
    bytes[80] = UInt8(tc & 0xFF);         bytes[81] = UInt8((tc >> 8)  & 0xFF)
    bytes[82] = UInt8((tc >> 16) & 0xFF); bytes[83] = UInt8((tc >> 24) & 0xFF)
    var off = 84

    for (i0, i1, i2) in triIdx {
      let v0 = vertPos[i0], v1 = vertPos[i1], v2 = vertPos[i2]
      var n = simd_cross(v1 - v0, v2 - v0)
      let len = simd_length(n); if len > 0 { n /= len }
      writeTriangle(&bytes, &off, n, v0, v1, v2)
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