import Foundation
import ARKit
import SceneKit
import ModelIO

@objc(LiDARScannerModule)
class LiDARScannerModule: NSObject {

  private var arSession: ARSession?
  private var collectedMeshAnchors: [ARMeshAnchor] = []
  private var collectedFaceAnchors: [ARFaceAnchor] = []
  private var isScanning = false
  private var currentMode: String = "lidar"

  // MARK: - React Native Bridge Methods

  @objc
  func startScan(_ mode: String,
                  resolver resolve: @escaping RCTPromiseResolveBlock,
                  rejecter reject: @escaping RCTPromiseRejectBlock) {
    let scanMode = mode.isEmpty ? "lidar" : mode

    if scanMode == "trueDepth" {
      guard ARFaceTrackingConfiguration.isSupported else {
        reject("TRUEDEPTH_NOT_AVAILABLE", "This device does not support TrueDepth face tracking.", nil)
        return
      }
    } else {
      guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
        reject("LIDAR_NOT_AVAILABLE", "This device does not support LiDAR scene reconstruction.", nil)
        return
      }
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }

      let session = ARSession()
      session.delegate = self
      self.arSession = session
      self.collectedMeshAnchors = []
      self.collectedFaceAnchors = []
      self.isScanning = true
      self.currentMode = scanMode

      if scanMode == "trueDepth" {
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = true
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
      } else {
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.environmentTexturing = .automatic
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
      }

      resolve(nil)
    }
  }

  @objc
  func stopScan(_ resolve: @escaping RCTPromiseResolveBlock,
                 rejecter reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.isScanning = false
      self.arSession?.pause()
      resolve(nil)
    }
  }

  @objc
  func exportToSTL(_ filename: String,
                    resolver resolve: @escaping RCTPromiseResolveBlock,
                    rejecter reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }

      do {
        let filePath: String
        if self.currentMode == "trueDepth" {
          guard !self.collectedFaceAnchors.isEmpty else {
            reject("NO_MESH_DATA", "No face mesh data has been captured. Run a scan first.", nil)
            return
          }
          filePath = try self.convertFaceMeshToSTL(anchors: self.collectedFaceAnchors, filename: filename)
        } else {
          guard !self.collectedMeshAnchors.isEmpty else {
            reject("NO_MESH_DATA", "No mesh data has been captured. Run a scan first.", nil)
            return
          }
          filePath = try self.convertMeshToSTL(anchors: self.collectedMeshAnchors, filename: filename)
        }
        resolve(filePath)
      } catch {
        reject("EXPORT_FAILED", "Failed to export STL: \(error.localizedDescription)", error)
      }
    }
  }

  // MARK: - Availability Checks

  @objc
  func isLiDARAvailable(_ resolve: @escaping RCTPromiseResolveBlock,
                         rejecter reject: @escaping RCTPromiseRejectBlock) {
    let available = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    resolve(available)
  }

  @objc
  func isTrueDepthAvailable(_ resolve: @escaping RCTPromiseResolveBlock,
                              rejecter reject: @escaping RCTPromiseRejectBlock) {
    let available = ARFaceTrackingConfiguration.isSupported
    resolve(available)
  }

  // MARK: - LiDAR Mesh → STL

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
        let localVertex = vertexPointer[i]
        let worldVertex = transform * SIMD4<Float>(localVertex.x, localVertex.y, localVertex.z, 1.0)
        vertices.append(SIMD3<Float>(worldVertex.x, worldVertex.y, worldVertex.z))
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

      if let mdlMesh = buildMDLMesh(vertices: vertices, indices: indices, vertexCount: vertexCount, allocator: allocator) {
        asset.add(mdlMesh)
      }
    }

    return try exportAsset(asset, filename: filename)
  }

  // MARK: - TrueDepth Face Mesh → STL

  private func convertFaceMeshToSTL(anchors: [ARFaceAnchor], filename: String) throws -> String {
    let allocator = MDLMeshBufferDataAllocator()
    let asset = MDLAsset()

    for anchor in anchors {
      let faceGeometry = anchor.geometry
      let transform = anchor.transform
      let vertexCount = faceGeometry.vertices.count

      var vertices: [SIMD3<Float>] = []
      for i in 0..<vertexCount {
        let localVertex = faceGeometry.vertices[i]
        let worldVertex = transform * SIMD4<Float>(localVertex.x, localVertex.y, localVertex.z, 1.0)
        vertices.append(SIMD3<Float>(worldVertex.x, worldVertex.y, worldVertex.z))
      }

      let triangleCount = faceGeometry.triangleCount
      var indices: [UInt32] = []
      for i in 0..<(triangleCount * 3) {
        indices.append(UInt32(faceGeometry.triangleIndices[i]))
      }

      if let mdlMesh = buildMDLMesh(vertices: vertices, indices: indices, vertexCount: vertexCount, allocator: allocator) {
        asset.add(mdlMesh)
      }
    }

    return try exportAsset(asset, filename: filename)
  }

  // MARK: - MDL Helpers

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

  // MARK: - Module Config

  @objc
  static func requiresMainQueueSetup() -> Bool {
    return false
  }
}

// MARK: - ARSessionDelegate

extension LiDARScannerModule: ARSessionDelegate {
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
}
