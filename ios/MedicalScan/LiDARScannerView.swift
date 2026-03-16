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
  private let voxelSize: Float = 0.003        // 3 mm per voxel (better 360 stability)
  private var pointCloudNode: SCNNode?
  private var realtimeMeshNode: SCNNode?
  private var fusedFrameCount   = 0
  private var lastVisualizeCount = 0
  private var lastMeshCount      = 0

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
          self?.realtimeMeshNode?.removeFromParentNode()
          self?.realtimeMeshNode = nil
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
        config.isWorldTrackingEnabled = true
      }
      config.isLightEstimationEnabled = false
      sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

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
    }
    isSessionRunning = true
  }

  private func pauseARSession() {
    guard isSessionRunning else { return }
    sceneView.session.pause()
    DispatchQueue.main.async { [weak self] in
      self?.pointCloudNode?.removeFromParentNode()
      self?.pointCloudNode = nil
      self?.realtimeMeshNode?.removeFromParentNode()
      self?.realtimeMeshNode = nil
    }
    isSessionRunning = false
  }

  // MARK: - ARSessionDelegate

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard isScanning, scannerMode == "trueDepthObject" else { return }
    guard let capturedDepth = frame.capturedDepthData else { return }

    let transform = frame.camera.transform
    let depth     = capturedDepth
    fusionQueue.async { [weak self] in
      self?.integrateDepth(depth, cameraTransform: transform)
    }
  }

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

    var fx: Float, fy: Float, cx: Float, cy: Float
    if let cal = depthData.cameraCalibrationData {
      let refW  = Float(cal.intrinsicMatrixReferenceDimensions.width)
      let scale = Float(dw) / refW
      let m = cal.intrinsicMatrix
      fx = m[0][0] * scale
      fy = m[1][1] * scale
      cx = m[2][0] * scale
      cy = m[2][1] * scale
    } else {
      fx = Float(dw) * 1.1;  fy = Float(dw) * 1.1
      cx = Float(dw) / 2.0;  cy = Float(dh) / 2.0
    }

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

    let step = 3

    for py in Swift.stride(from: 0, to: dh, by: step) {
      let row = base.advanced(by: py * bpr).assumingMemoryBound(to: Float.self)
      for px in Swift.stride(from: 0, to: dw, by: step) {
        let d = row[px]
        guard d.isFinite, d > filterLo, d < filterHi else { continue }

        let xc = (Float(px) - cx) * d / fx
        let yc = -(Float(py) - cy) * d / fy
        let zc = -d

        let w4 = cameraTransform * SIMD4<Float>(xc, yc, zc, 1.0)
        let wp = SIMD3<Float>(w4.x, w4.y, w4.z)

        let key = SIMD3<Int32>(
          Int32(floor(wp.x / voxelSize)),
          Int32(floor(wp.y / voxelSize)),
          Int32(floor(wp.z / voxelSize)))

        let rejectDist = voxelSize * 4.0
        if var e = worldVoxels[key] {
          guard simd_distance(wp, e.center) < rejectDist else { continue }
          e.center += 0.2 * (wp - e.center)
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

    let pts = Array(worldVoxels.values.prefix(40000)).map { $0.center }
    DispatchQueue.main.async { [weak self] in self?.updatePointCloud(pts) }

    guard fusedFrameCount - lastMeshCount >= 60 else { return }
    lastMeshCount = fusedFrameCount
    let snapVoxels = worldVoxels
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self = self else { return }
      let geo = self.buildRealtimeMesh(snapVoxels)
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.realtimeMeshNode?.removeFromParentNode()
        if let geo = geo {
          let node = SCNNode(geometry: geo)
          self.sceneView.scene.rootNode.addChildNode(node)
          self.realtimeMeshNode = node
        }
      }
    }
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


  // MARK: - Realtime Mesh Preview (lightweight binary MC, runs on background queue)

  private func buildRealtimeMesh(
    _ voxels: [SIMD3<Int32>: (center: SIMD3<Float>, count: Int32)]
  ) -> SCNGeometry? {
    let occupied = Set(voxels.filter { $0.value.count >= 3 }.keys)
    guard occupied.count > 10 else { return nil }

    let mcCorners: [SIMD3<Int32>] = [
      SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,1,0), SIMD3(0,1,0),
      SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(1,1,1), SIMD3(0,1,1)
    ]
    let mcEdgeA   = [0,1,2,3, 4,5,6,7, 0,1,2,3]
    let mcEdgeB   = [1,2,3,0, 5,6,7,4, 4,5,6,7]
    let mcEdgeOff: [SIMD3<Int32>] = [
      SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,0),
      SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(0,1,1), SIMD3(0,0,1),
      SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,1,0), SIMD3(0,1,0)
    ]
    let mcEdgeAxis: [Int32] = [0,1,0,1, 0,1,0,1, 2,2,2,2]

    var vertPos   = [SIMD3<Float>]()
    var vertCache = [SIMD4<Int32>: Int]()
    var indices   = [Int32]()

    var cellSet = Set<SIMD3<Int32>>()
    for key in occupied {
      for dz in -1...0 { for dy in -1...0 { for dx in -1...0 {
        cellSet.insert(SIMD3(key.x+Int32(dx), key.y+Int32(dy), key.z+Int32(dz)))
      }}}
    }

    for cell in cellSet {
      var cubeIdx = 0
      for (i, c) in mcCorners.enumerated() {
        if occupied.contains(SIMD3(cell.x+c.x, cell.y+c.y, cell.z+c.z)) { cubeIdx |= (1 << i) }
      }
      guard cubeIdx > 0 && cubeIdx < 255 else { continue }

      func mcVert(_ edge: Int) -> Int32 {
        let off = mcEdgeOff[edge]
        let gk  = SIMD4<Int32>(cell.x+off.x, cell.y+off.y, cell.z+off.z, mcEdgeAxis[edge])
        if let idx = vertCache[gk] { return Int32(idx) }
        let ca = mcCorners[mcEdgeA[edge]], cb = mcCorners[mcEdgeB[edge]]
        let p  = SIMD3<Float>(
          Float(cell.x) + Float(ca.x+cb.x)*0.5,
          Float(cell.y) + Float(ca.y+cb.y)*0.5,
          Float(cell.z) + Float(ca.z+cb.z)*0.5) * voxelSize
        let idx = vertPos.count
        vertPos.append(p); vertCache[gk] = idx; return Int32(idx)
      }

      var ti = 0
      let tbl = LiDARScannerView.mcTriTable[cubeIdx]
      while ti < tbl.count, tbl[ti] >= 0 {
        indices.append(mcVert(Int(tbl[ti])))
        indices.append(mcVert(Int(tbl[ti+1])))
        indices.append(mcVert(Int(tbl[ti+2])))
        ti += 3
      }
    }

    guard !indices.isEmpty else { return nil }

    let verts  = vertPos.map { SCNVector3($0.x, $0.y, $0.z) }
    let src    = SCNGeometrySource(vertices: verts)
    let idxData = Data(bytes: indices, count: indices.count * 4)
    let elem   = SCNGeometryElement(data: idxData, primitiveType: .triangles,
                                    primitiveCount: indices.count / 3, bytesPerIndex: 4)
    let geo    = SCNGeometry(sources: [src], elements: [elem])
    let mat    = SCNMaterial()
    mat.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.55)
    mat.isDoubleSided    = true
    mat.lightingModel    = .constant
    geo.materials = [mat]
    return geo
  }

  // MARK: - PCA Normal Estimation

  private func pcaNormal(_ pts: [SIMD3<Float>]) -> SIMD3<Float> {
    guard pts.count >= 3 else { return SIMD3<Float>(0, 1, 0) }
    let n = Float(pts.count)
    let mean = pts.reduce(SIMD3<Float>.zero, +) / n
    var xx: Float=0, xy: Float=0, xz: Float=0
    var yy: Float=0, yz: Float=0, zz: Float=0
    for p in pts {
      let d = p - mean
      xx += d.x*d.x; xy += d.x*d.y; xz += d.x*d.z
      yy += d.y*d.y; yz += d.y*d.z; zz += d.z*d.z
    }
    xx /= n; xy /= n; xz /= n; yy /= n; yz /= n; zz /= n
    func matvec(_ v: SIMD3<Float>) -> SIMD3<Float> {
      SIMD3(xx*v.x+xy*v.y+xz*v.z,
            xy*v.x+yy*v.y+yz*v.z,
            xz*v.x+yz*v.y+zz*v.z)
    }
    // Power iteration: largest eigenvector
    var v1 = simd_normalize(SIMD3<Float>(1, 1, 1))
    for _ in 0..<12 { let t = matvec(v1); let l = simd_length(t); if l > 0 { v1 = t/l } }
    let lam1 = simd_dot(v1, matvec(v1))
    // Second eigenvector via deflation
    var v2: SIMD3<Float> = abs(v1.x) < 0.8 ? SIMD3(1,0,0) : SIMD3(0,1,0)
    v2 = simd_normalize(v2 - simd_dot(v2, v1)*v1)
    for _ in 0..<12 {
      var t = matvec(v2); t -= lam1 * simd_dot(v1, v2) * v1; t -= simd_dot(t, v1)*v1
      let l = simd_length(t); if l > 0 { v2 = t/l }
    }
    // Normal = 3rd eigenvector (smallest eigenvalue) = cross product
    return simd_normalize(simd_cross(v1, v2))
  }

  // MARK: - Voxel Surface → STL Export (Poisson Surface Reconstruction)

  private func voxelsToSTL(
    _ voxels: [SIMD3<Int32>: (center: SIMD3<Float>, count: Int32)],
    filename: String) throws -> String {

    // ── 1. Filter: keep only voxels seen in ≥8 frames ─────────────────────
    let filtered = voxels.filter { $0.value.count >= 5 }
    guard !filtered.isEmpty else {
      throw NSError(domain: "Scan", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "スキャンデータがありません。スキャンを実行してください。"])
    }

    // ── 2. Build oriented point cloud via PCA normals ──────────────────────
    var points  = [SIMD3<Float>](); points.reserveCapacity(filtered.count)
    var normals = [SIMD3<Float>](); normals.reserveCapacity(filtered.count)
    for (key, (center, _)) in filtered {
      var neighbors = [SIMD3<Float>](); neighbors.reserveCapacity(125)
      for dz in -2...2 { for dy in -2...2 { for dx in -2...2 {
        let nk = SIMD3<Int32>(key.x+Int32(dx), key.y+Int32(dy), key.z+Int32(dz))
        if let nv = filtered[nk] { neighbors.append(nv.center) }
      }}}
      points.append(center)
      normals.append(pcaNormal(neighbors))
    }

    // ── 3. Orient normals away from scan centroid ──────────────────────────
    let centroid = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
    for i in 0..<normals.count {
      if simd_dot(normals[i], points[i] - centroid) < 0 { normals[i] = -normals[i] }
    }

    // ── 4. Build Poisson grid ──────────────────────────────────────────────
    let gridStep: Float = voxelSize * 1.5   // 4.5 mm grid for 3 mm voxels
    var minP = SIMD3<Float>(repeating:  Float.infinity)
    var maxP = SIMD3<Float>(repeating: -Float.infinity)
    for p in points { minP = simd_min(minP, p); maxP = simd_max(maxP, p) }
    let pad: Float = gridStep * 3
    minP -= SIMD3<Float>(repeating: pad)
    maxP += SIMD3<Float>(repeating: pad)
    let fDims = (maxP - minP) / gridStep
    let gx = max(4, Int(fDims.x.rounded(.up)) + 1)
    let gy = max(4, Int(fDims.y.rounded(.up)) + 1)
    let gz = max(4, Int(fDims.z.rounded(.up)) + 1)
    let cellCount = gx * gy * gz
    guard cellCount < 3_000_000 else {
      throw NSError(domain: "Scan", code: 3, userInfo: [
        NSLocalizedDescriptionKey: "スキャン範囲が広すぎます。対象物に近づいてください。"])
    }
    let strideY = gx, strideZ = gx * gy
    func fi(_ x: Int, _ y: Int, _ z: Int) -> Int { z * strideZ + y * strideY + x }

    // ── 5. Splat divergence of normal field onto grid (∇·N) ────────────────
    var rhs = [Float](repeating: 0, count: cellCount)
    let invH: Float = 1.0 / gridStep
    for (p, nm) in zip(points, normals) {
      let lp = (p - minP) * invH
      let ix = max(0, min(gx-2, Int(lp.x)))
      let iy = max(0, min(gy-2, Int(lp.y)))
      let iz = max(0, min(gz-2, Int(lp.z)))
      let fx = lp.x - Float(ix), fy = lp.y - Float(iy), fz = lp.z - Float(iz)
      for dz in 0...1 { for dy in 0...1 { for dx in 0...1 {
        let wx: Float  = dx == 0 ? 1-fx : fx
        let wy: Float  = dy == 0 ? 1-fy : fy
        let wz: Float  = dz == 0 ? 1-fz : fz
        let dwx: Float = dx == 0 ? -invH : invH
        let dwy: Float = dy == 0 ? -invH : invH
        let dwz: Float = dz == 0 ? -invH : invH
        rhs[fi(ix+dx, iy+dy, iz+dz)] +=
          nm.x*dwx*wy*wz + nm.y*wx*dwy*wz + nm.z*wx*wy*dwz
      }}}
    }

    // ── 6. Poisson solve: ∇²f = rhs (Gauss-Seidel, 80 iterations) ─────────
    var f = [Float](repeating: 0, count: cellCount)
    let h2 = gridStep * gridStep
    for _ in 0..<120 {
      for iz in 1..<gz-1 { for iy in 1..<gy-1 { for ix in 1..<gx-1 {
        let i = fi(ix, iy, iz)
        f[i] = (f[i+1]+f[i-1]+f[i+strideY]+f[i-strideY]+f[i+strideZ]+f[i-strideZ] - h2*rhs[i]) / 6
      }}}
    }

    // ── 7. Isovalue: mean of f sampled at oriented points ─────────────────
    var isoSum: Float = 0
    for p in points {
      let lp = (p - minP) * invH
      let ix = max(0, min(gx-2, Int(lp.x)))
      let iy = max(0, min(gy-2, Int(lp.y)))
      let iz = max(0, min(gz-2, Int(lp.z)))
      let fx = lp.x-Float(ix), fy = lp.y-Float(iy), fz = lp.z-Float(iz)
      let w000=f[fi(ix,iy,iz)]*(1-fx)*(1-fy)*(1-fz); let w100=f[fi(ix+1,iy,iz)]*fx*(1-fy)*(1-fz)
      let w010=f[fi(ix,iy+1,iz)]*(1-fx)*fy*(1-fz); let w110=f[fi(ix+1,iy+1,iz)]*fx*fy*(1-fz)
      let w001=f[fi(ix,iy,iz+1)]*(1-fx)*(1-fy)*fz; let w101=f[fi(ix+1,iy,iz+1)]*fx*(1-fy)*fz
      let w011=f[fi(ix,iy+1,iz+1)]*(1-fx)*fy*fz;   let w111=f[fi(ix+1,iy+1,iz+1)]*fx*fy*fz
      isoSum += w000+w100+w010+w110+w001+w101+w011+w111
    }
    let isoValue = isoSum / Float(points.count)

    // ── 8. Marching Cubes on Poisson field (linear edge interpolation) ─────
    let mcCorners: [SIMD3<Int32>] = [
      SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,1,0), SIMD3(0,1,0),
      SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(1,1,1), SIMD3(0,1,1)
    ]
    let mcEdgeA    = [0,1,2,3, 4,5,6,7, 0,1,2,3]
    let mcEdgeB    = [1,2,3,0, 5,6,7,4, 4,5,6,7]
    let mcEdgeOff: [SIMD3<Int32>] = [
      SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,0),
      SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(0,1,1), SIMD3(0,0,1),
      SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,1,0), SIMD3(0,1,0)
    ]
    let mcEdgeAxis: [Int32] = [0,1,0,1, 0,1,0,1, 2,2,2,2]

    var vertPos   = [SIMD3<Float>]()
    var vertCache = [SIMD4<Int32>: Int]()
    var triIdx    = [(Int, Int, Int)]()

    for iz in 0..<gz-1 { for iy in 0..<gy-1 { for ix in 0..<gx-1 {
      var cubeIdx = 0
      for (ci, c) in mcCorners.enumerated() {
        if f[fi(ix+Int(c.x), iy+Int(c.y), iz+Int(c.z))] > isoValue { cubeIdx |= (1 << ci) }
      }
      guard cubeIdx > 0 && cubeIdx < 255 else { continue }

      func mcVert(_ edge: Int) -> Int {
        let off = mcEdgeOff[edge]
        let gk  = SIMD4<Int32>(Int32(ix)+off.x, Int32(iy)+off.y, Int32(iz)+off.z, mcEdgeAxis[edge])
        if let idx = vertCache[gk] { return idx }
        let ca = mcCorners[mcEdgeA[edge]], cb = mcCorners[mcEdgeB[edge]]
        let fa = f[fi(ix+Int(ca.x), iy+Int(ca.y), iz+Int(ca.z))]
        let fb = f[fi(ix+Int(cb.x), iy+Int(cb.y), iz+Int(cb.z))]
        let t  = abs(fa-fb) > 1e-6 ? max(0, min(1, (isoValue-fa)/(fb-fa))) : 0.5
        let pa = SIMD3<Float>(Float(ix)+Float(ca.x), Float(iy)+Float(ca.y), Float(iz)+Float(ca.z)) * gridStep + minP
        let pb = SIMD3<Float>(Float(ix)+Float(cb.x), Float(iy)+Float(cb.y), Float(iz)+Float(cb.z)) * gridStep + minP
        let idx = vertPos.count
        vertPos.append(pa + t*(pb-pa)); vertCache[gk] = idx; return idx
      }

      var ti = 0
      let tbl = LiDARScannerView.mcTriTable[cubeIdx]
      while ti < tbl.count, tbl[ti] >= 0 {
        triIdx.append((mcVert(Int(tbl[ti])), mcVert(Int(tbl[ti+1])), mcVert(Int(tbl[ti+2]))))
        ti += 3
      }
    }}}

    guard !triIdx.isEmpty else {
      throw NSError(domain: "Scan", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "メッシュを生成できませんでした。スキャンデータが少なすぎます。"])
    }

    // ── 9. Keep only largest connected component ───────────────────────────
    do {
      var vertToTri = [Int: [Int]]()
      for (ti, (i0, i1, i2)) in triIdx.enumerated() {
        vertToTri[i0, default: []].append(ti)
        vertToTri[i1, default: []].append(ti)
        vertToTri[i2, default: []].append(ti)
      }
      var visited = [Bool](repeating: false, count: triIdx.count)
      var components = [[Int]]()
      for start in 0..<triIdx.count {
        guard !visited[start] else { continue }
        var comp = [Int](); var queue = [start]; visited[start] = true
        while !queue.isEmpty {
          let ti = queue.removeFirst(); comp.append(ti)
          let (ia, ib, ic) = triIdx[ti]
          for v in [ia, ib, ic] {
            for nb in vertToTri[v, default: []] where !visited[nb] {
              visited[nb] = true; queue.append(nb)
            }
          }
        }
        components.append(comp)
      }
      if let largest = components.max(by: { $0.count < $1.count }) {
        triIdx = largest.map { triIdx[$0] }
      }
    }

    // ── 10. Taubin smoothing (4 iterations — Poisson field already smooth) ─
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
    for _ in 0..<2 { smoothStep(factor: lambda); smoothStep(factor: mu) }

    // ── 11. Orient normals outward (open mesh, single-sided) ──────────────
    let meshCentroid: SIMD3<Float> = vertPos.reduce(.zero, +) / Float(max(vertPos.count, 1))
    triIdx = triIdx.map { (i0, i1, i2) in
      let v0 = vertPos[i0], v1 = vertPos[i1], v2 = vertPos[i2]
      let n  = simd_cross(v1 - v0, v2 - v0)
      let fc = (v0 + v1 + v2) / 3.0
      return simd_dot(n, fc - meshCentroid) >= 0 ? (i0, i1, i2) : (i0, i2, i1)
    }

    // ── 12. Write binary STL ───────────────────────────────────────────────
    let triCount = triIdx.count
    var bytes = [UInt8](repeating: 0, count: 84 + triCount * 50)
    let tc = UInt32(triCount)
    bytes[80]=UInt8(tc&0xFF); bytes[81]=UInt8((tc>>8)&0xFF)
    bytes[82]=UInt8((tc>>16)&0xFF); bytes[83]=UInt8((tc>>24)&0xFF)
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

  // MARK: - Marching Cubes lookup table (Lorensen & Cline 1987 / Bourke)
  private static let mcTriTable: [[Int8]] = [
    [-1],
    [0,8,3,-1],
    [0,1,9,-1],
    [1,8,3,9,8,1,-1],
    [1,2,10,-1],
    [0,8,3,1,2,10,-1],
    [9,2,10,0,2,9,-1],
    [2,8,3,2,10,8,10,9,8,-1],
    [3,11,2,-1],
    [0,11,2,8,11,0,-1],
    [1,9,0,2,3,11,-1],
    [1,11,2,1,9,11,9,8,11,-1],
    [3,10,1,11,10,3,-1],
    [0,10,1,0,8,10,8,11,10,-1],
    [3,9,0,3,11,9,11,10,9,-1],
    [9,8,10,10,8,11,-1],
    [4,7,8,-1],
    [4,3,0,7,3,4,-1],
    [0,1,9,8,4,7,-1],
    [4,1,9,4,7,1,7,3,1,-1],
    [1,2,10,8,4,7,-1],
    [3,4,7,3,0,4,1,2,10,-1],
    [9,2,10,9,0,2,8,4,7,-1],
    [2,10,9,2,9,7,2,7,3,7,9,4,-1],
    [8,4,7,3,11,2,-1],
    [11,4,7,11,2,4,2,0,4,-1],
    [9,0,1,8,4,7,2,3,11,-1],
    [4,7,11,9,4,11,9,11,2,9,2,1,-1],
    [3,10,1,3,11,10,7,8,4,-1],
    [1,11,10,1,4,11,1,0,4,7,11,4,-1],
    [4,7,8,9,0,11,9,11,10,11,0,3,-1],
    [4,7,11,4,11,9,9,11,10,-1],
    [9,5,4,-1],
    [9,5,4,0,8,3,-1],
    [0,5,4,1,5,0,-1],
    [8,5,4,8,3,5,3,1,5,-1],
    [1,2,10,9,5,4,-1],
    [3,0,8,1,2,10,4,9,5,-1],
    [5,2,10,5,4,2,4,0,2,-1],
    [2,10,5,3,2,5,3,5,4,3,4,8,-1],
    [9,5,4,2,3,11,-1],
    [0,11,2,0,8,11,4,9,5,-1],
    [0,5,4,0,1,5,2,3,11,-1],
    [2,1,5,2,5,8,2,8,11,4,8,5,-1],
    [10,3,11,10,1,3,9,5,4,-1],
    [4,9,5,0,8,1,8,10,1,8,11,10,-1],
    [5,4,0,5,0,11,5,11,10,11,0,3,-1],
    [5,4,8,5,8,10,10,8,11,-1],
    [9,7,8,5,7,9,-1],
    [9,3,0,9,5,3,5,7,3,-1],
    [0,7,8,0,1,7,1,5,7,-1],
    [1,5,3,3,5,7,-1],
    [9,7,8,9,5,7,10,1,2,-1],
    [10,1,2,9,5,0,5,3,0,5,7,3,-1],
    [8,0,2,8,2,5,8,5,7,10,5,2,-1],
    [2,10,5,2,5,3,3,5,7,-1],
    [7,9,5,7,8,9,3,11,2,-1],
    [9,5,7,9,7,2,9,2,0,2,7,11,-1],
    [2,3,11,0,1,8,1,7,8,1,5,7,-1],
    [11,2,1,11,1,7,7,1,5,-1],
    [9,5,8,8,5,7,10,1,3,10,3,11,-1],
    [5,7,0,5,0,9,7,11,0,1,0,10,11,10,0,-1],
    [11,10,0,11,0,3,10,5,0,8,0,7,5,7,0,-1],
    [11,10,5,7,11,5,-1],
    [10,6,5,-1],
    [0,8,3,5,10,6,-1],
    [9,0,1,5,10,6,-1],
    [1,8,3,1,9,8,5,10,6,-1],
    [1,6,5,2,6,1,-1],
    [1,6,5,1,2,6,3,0,8,-1],
    [9,6,5,9,0,6,0,2,6,-1],
    [5,9,8,5,8,2,5,2,6,3,2,8,-1],
    [2,3,11,10,6,5,-1],
    [11,0,8,11,2,0,10,6,5,-1],
    [0,1,9,2,3,11,5,10,6,-1],
    [5,10,6,1,9,2,9,11,2,9,8,11,-1],
    [6,3,11,6,5,3,5,1,3,-1],
    [0,8,11,0,11,5,0,5,1,5,11,6,-1],
    [3,11,6,0,3,6,0,6,5,0,5,9,-1],
    [6,5,9,6,9,11,11,9,8,-1],
    [5,10,6,4,7,8,-1],
    [4,3,0,4,7,3,6,5,10,-1],
    [1,9,0,5,10,6,8,4,7,-1],
    [10,6,5,1,9,7,1,7,3,7,9,4,-1],
    [6,1,2,6,5,1,4,7,8,-1],
    [1,2,5,5,2,6,3,0,4,3,4,7,-1],
    [8,4,7,9,0,5,0,6,5,0,2,6,-1],
    [7,3,9,7,9,4,3,2,9,5,9,6,2,6,9,-1],
    [3,11,2,7,8,4,10,6,5,-1],
    [5,10,6,4,7,2,4,2,0,2,7,11,-1],
    [0,1,9,4,7,8,2,3,11,5,10,6,-1],
    [9,2,1,9,11,2,9,4,11,7,11,4,5,10,6,-1],
    [8,4,7,3,11,5,3,5,1,5,11,6,-1],
    [5,1,11,5,11,6,1,0,11,7,11,4,0,4,11,-1],
    [0,5,9,0,6,5,0,3,6,11,6,3,8,4,7,-1],
    [6,5,9,6,9,11,4,7,9,7,11,9,-1],
    [10,4,9,6,4,10,-1],
    [4,10,6,4,9,10,0,8,3,-1],
    [10,0,1,10,6,0,6,4,0,-1],
    [8,3,1,8,1,6,8,6,4,6,1,10,-1],
    [1,4,9,1,2,4,2,6,4,-1],
    [3,0,8,1,2,9,2,4,9,2,6,4,-1],
    [0,2,4,4,2,6,-1],
    [8,3,2,8,2,4,4,2,6,-1],
    [10,4,9,10,6,4,11,2,3,-1],
    [0,8,2,2,8,11,4,9,10,4,10,6,-1],
    [3,11,2,0,1,6,0,6,4,6,1,10,-1],
    [6,4,1,6,1,10,4,8,1,2,1,11,8,11,1,-1],
    [9,6,4,9,3,6,9,1,3,11,6,3,-1],
    [8,11,1,8,1,0,11,6,1,9,1,4,6,4,1,-1],
    [3,11,6,3,6,0,0,6,4,-1],
    [6,4,8,11,6,8,-1],
    [7,10,6,7,8,10,8,9,10,-1],
    [0,7,3,0,10,7,0,9,10,6,7,10,-1],
    [10,6,7,1,10,7,1,7,8,1,8,0,-1],
    [10,6,7,10,7,1,1,7,3,-1],
    [1,2,6,1,6,8,1,8,9,8,6,7,-1],
    [2,6,9,2,9,1,6,7,9,0,9,3,7,3,9,-1],
    [7,8,0,7,0,6,6,0,2,-1],
    [7,3,2,6,7,2,-1],
    [2,3,11,10,6,8,10,8,9,8,6,7,-1],
    [2,0,7,2,7,11,0,9,7,6,7,10,9,10,7,-1],
    [1,8,0,1,7,8,1,10,7,6,7,10,2,3,11,-1],
    [11,2,1,11,1,7,10,6,1,6,7,1,-1],
    [8,9,6,8,6,7,9,1,6,11,6,3,1,3,6,-1],
    [0,9,1,11,6,7,-1],
    [7,8,0,7,0,6,3,11,0,11,6,0,-1],
    [7,11,6,-1],
    [7,6,11,-1],
    [3,0,8,11,7,6,-1],
    [0,1,9,11,7,6,-1],
    [8,1,9,8,3,1,11,7,6,-1],
    [10,1,2,6,11,7,-1],
    [1,2,10,3,0,8,6,11,7,-1],
    [2,9,0,2,10,9,6,11,7,-1],
    [6,11,7,2,10,3,10,8,3,10,9,8,-1],
    [7,2,3,6,2,7,-1],
    [7,0,8,7,6,0,6,2,0,-1],
    [2,7,6,2,3,7,0,1,9,-1],
    [1,6,2,1,8,6,1,9,8,8,7,6,-1],
    [10,7,6,10,1,7,1,3,7,-1],
    [10,7,6,1,7,10,1,8,7,1,0,8,-1],
    [0,3,7,0,7,10,0,10,9,6,10,7,-1],
    [7,6,10,7,10,8,8,10,9,-1],
    [6,8,4,11,8,6,-1],
    [3,6,11,3,0,6,0,4,6,-1],
    [8,6,11,8,4,6,9,0,1,-1],
    [9,4,6,9,6,3,9,3,1,11,3,6,-1],
    [6,8,4,6,11,8,2,10,1,-1],
    [1,2,10,3,0,11,0,6,11,0,4,6,-1],
    [4,11,8,4,6,11,0,2,9,2,10,9,-1],
    [10,9,3,10,3,2,9,4,3,11,3,6,4,6,3,-1],
    [8,2,3,8,4,2,4,6,2,-1],
    [0,4,2,4,6,2,-1],
    [1,9,0,2,3,4,2,4,6,4,3,8,-1],
    [1,9,4,1,4,2,2,4,6,-1],
    [8,1,3,8,6,1,8,4,6,6,10,1,-1],
    [10,1,0,10,0,6,6,0,4,-1],
    [4,6,3,4,3,8,6,10,3,0,3,9,10,9,3,-1],
    [10,9,4,6,10,4,-1],
    [4,9,5,7,6,11,-1],
    [0,8,3,4,9,5,11,7,6,-1],
    [5,0,1,5,4,0,7,6,11,-1],
    [11,7,6,8,3,4,3,5,4,3,1,5,-1],
    [9,5,4,10,1,2,7,6,11,-1],
    [6,11,7,1,2,10,0,8,3,4,9,5,-1],
    [7,6,11,5,4,10,4,2,10,4,0,2,-1],
    [3,4,8,3,5,4,3,2,5,10,5,2,11,7,6,-1],
    [7,2,3,7,6,2,5,4,9,-1],
    [9,5,4,0,8,6,0,6,2,6,8,7,-1],
    [3,6,2,3,7,6,1,5,0,5,4,0,-1],
    [6,2,8,6,8,7,2,1,8,4,8,5,1,5,8,-1],
    [9,5,4,10,1,6,1,7,6,1,3,7,-1],
    [1,6,10,1,7,6,1,0,7,8,7,0,9,5,4,-1],
    [4,0,10,4,10,5,0,3,10,6,10,7,3,7,10,-1],
    [7,6,10,7,10,8,5,4,10,4,8,10,-1],
    [6,9,5,6,11,9,11,8,9,-1],
    [3,6,11,0,6,3,0,5,6,0,9,5,-1],
    [0,11,8,0,5,11,0,1,5,5,6,11,-1],
    [6,11,3,6,3,5,5,3,1,-1],
    [1,2,10,9,5,11,9,11,8,11,5,6,-1],
    [0,11,3,0,6,11,0,9,6,5,6,9,1,2,10,-1],
    [11,8,5,11,5,6,8,0,5,10,5,2,0,2,5,-1],
    [6,11,3,6,3,5,2,10,3,10,5,3,-1],
    [5,8,9,5,2,8,5,6,2,3,8,2,-1],
    [9,5,6,9,6,0,0,6,2,-1],
    [1,5,8,1,8,0,5,6,8,3,8,2,6,2,8,-1],
    [1,5,6,2,1,6,-1],
    [1,3,6,1,6,10,3,8,6,5,6,9,8,9,6,-1],
    [10,1,0,10,0,6,9,5,0,5,6,0,-1],
    [0,3,8,5,6,10,-1],
    [10,5,6,-1],
    [11,5,10,7,5,11,-1],
    [11,5,10,11,7,5,8,3,0,-1],
    [5,11,7,5,10,11,1,9,0,-1],
    [10,7,5,10,11,7,9,8,1,8,3,1,-1],
    [11,1,2,11,7,1,7,5,1,-1],
    [0,8,3,1,2,7,1,7,5,7,2,11,-1],
    [9,7,5,9,2,7,9,0,2,2,11,7,-1],
    [7,5,2,7,2,11,5,9,2,3,2,8,9,8,2,-1],
    [2,5,10,2,3,5,3,7,5,-1],
    [8,2,0,8,5,2,8,7,5,10,2,5,-1],
    [9,0,1,2,3,5,2,5,10,5,3,7,-1],
    [8,2,9,8,9,7,2,10,9,5,9,3,10,3,9,-1],
    [1,7,5,1,3,7,-1],
    [0,8,7,0,7,1,1,7,5,-1],
    [9,0,3,9,3,5,5,3,7,-1],
    [9,8,7,5,9,7,-1],
    [5,8,4,5,10,8,10,11,8,-1],
    [5,0,4,5,11,0,5,10,11,11,3,0,-1],
    [0,1,9,8,4,10,8,10,11,10,4,5,-1],
    [10,11,4,10,4,5,11,3,4,9,4,1,3,1,4,-1],
    [2,5,1,2,8,5,2,11,8,4,5,8,-1],
    [0,4,11,0,11,3,4,5,11,2,11,1,5,1,11,-1],
    [0,2,5,0,5,9,2,11,5,4,5,8,11,8,5,-1],
    [9,4,5,2,11,3,-1],
    [2,5,10,3,5,2,3,4,5,3,8,4,-1],
    [5,10,2,5,2,4,4,2,0,-1],
    [3,10,2,3,5,10,3,8,5,4,5,8,0,1,9,-1],
    [5,10,2,5,2,4,1,9,2,9,4,2,-1],
    [8,4,5,8,5,3,3,5,1,-1],
    [0,4,5,1,0,5,-1],
    [8,4,5,8,5,3,9,0,5,0,3,5,-1],
    [9,4,5,-1],
    [4,11,7,4,9,11,9,10,11,-1],
    [0,8,3,4,9,7,9,11,7,9,10,11,-1],
    [1,10,11,1,11,4,1,4,0,7,4,11,-1],
    [3,1,4,3,4,8,1,10,4,7,4,11,10,11,4,-1],
    [4,11,7,9,11,4,9,2,11,9,1,2,-1],
    [9,7,4,9,11,7,9,1,11,2,11,1,0,8,3,-1],
    [11,7,4,11,4,2,2,4,0,-1],
    [11,7,4,11,4,2,8,3,4,3,2,4,-1],
    [2,9,10,2,7,9,2,3,7,7,4,9,-1],
    [9,10,7,9,7,4,10,2,7,8,7,0,2,0,7,-1],
    [3,7,10,3,10,2,7,4,10,1,10,0,4,0,10,-1],
    [1,10,2,8,7,4,-1],
    [4,9,1,4,1,7,7,1,3,-1],
    [4,9,1,4,1,7,0,8,1,8,7,1,-1],
    [4,0,3,7,4,3,-1],
    [4,8,7,-1],
    [9,10,8,10,11,8,-1],
    [3,0,9,3,9,11,11,9,10,-1],
    [0,1,10,0,10,8,8,10,11,-1],
    [3,1,10,11,3,10,-1],
    [1,2,11,1,11,9,9,11,8,-1],
    [3,0,9,3,9,11,1,2,9,2,11,9,-1],
    [0,2,11,8,0,11,-1],
    [3,2,11,-1],
    [2,3,8,2,8,10,10,8,9,-1],
    [9,10,2,0,9,2,-1],
    [2,3,8,2,8,10,0,1,8,1,10,8,-1],
    [1,10,2,-1],
    [1,3,8,9,1,8,-1],
    [0,9,1,-1],
    [0,3,8,-1],
    [-1]
  ]

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
