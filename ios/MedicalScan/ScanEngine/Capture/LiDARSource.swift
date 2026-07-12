//
//  LiDARSource.swift
//  ScanEngine / Capture
//
//  背面 LiDAR（sceneDepth）の DepthFrameSource 実装。
//  ARWorldTrackingConfiguration + frameSemantics(.sceneDepth/.smoothedSceneDepth) を使い、
//  フレーム毎に ARDepthData とカメラ姿勢を取り出して DepthFrame に詰め替える。
//
//  TrueDepth 版との違い:
//   - 背面カメラ + ワールドトラッキング（VIO 6DOF）なので並進追従が強い（人体/物体の周回に有利）。
//   - 深度は 256x192 と低解像だが、per-pixel confidence（confidenceMap）を持つ。
//   - 建物ではなく人体/オブジェクトが対象。背景・床は TSDF ボリューム（箱）の外として自然に除外。
//
//  数学的メモ:
//   - camera.intrinsics は imageResolution 基準なので depth 解像度へ線形スケールして使う。
//   - depthMap CVPixelBuffer は ARFrame 寿命に縛られるため独立テクスチャへコピーして渡す。
//

import ARKit
import Metal
import UIKit
import simd

final class LiDARSource: NSObject, DepthFrameSource, ARSessionDelegate {

    let sensor: ScanSensor = .lidar
    weak var delegate: DepthFrameSourceDelegate?

    private let context: MetalContext
    private let session = ARSession()
    private let queue = DispatchQueue(label: "scanengine.lidar.capture", qos: .userInitiated)
    private var lastTracking: ScanTrackingState?

    // AR オーバーレイ／カラー焼き込み用。ON のときだけカラーを取得する。
    private var wantsColor = false
    private var viewportSize = CGSize(width: 390, height: 844)

    // 深度ロスト検知用。
    private var lastDepthTime: TimeInterval = 0
    private var everReceivedDepth = false
    private var depthLost = false
    private let depthLostTimeout: TimeInterval = 0.5

    init(context: MetalContext) {
        self.context = context
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    // MARK: - DepthFrameSource

    func start() {
        guard ARWorldTrackingConfiguration.isSupported,
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            delegate?.depthFrameSource(self, didFail: ScanEngineError.sensorUnavailable(
                "この端末は LiDAR（sceneDepth）に対応していません。"))
            return
        }
        let config = ARWorldTrackingConfiguration()
        // 平滑済み深度が使えれば優先（時間平滑でスキャン向き）。無ければ生 sceneDepth。
        var semantics: ARConfiguration.FrameSemantics = .sceneDepth
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            semantics.insert(.smoothedSceneDepth)
        }
        config.frameSemantics = semantics
        config.planeDetection = []
        config.environmentTexturing = .none
        config.isLightEstimationEnabled = false
        lastTracking = nil
        lastDepthTime = 0
        everReceivedDepth = false
        depthLost = false
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
    }

    func setColorCapture(_ enabled: Bool) { wantsColor = enabled }

    // LiDAR は背面ワールドトラッキングが本質なので常に 6DOF（トグルは無視）。
    func setWorldTracking(_ enabled: Bool) {}

    func setViewport(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        viewportSize = size
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // 1) トラッキング状態の変化を通知
        let tracking = Self.map(frame.camera.trackingState)
        if tracking != lastTracking {
            lastTracking = tracking
            delegate?.depthFrameSource(self, didChangeTracking: tracking)
        }

        // 2) 深度（平滑優先）。無ければ depthLost 通知。
        let now = frame.timestamp
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            if everReceivedDepth, !depthLost, now - lastDepthTime > depthLostTimeout {
                depthLost = true
                delegate?.depthFrameSource(self, didLogEvent: "depthLost",
                    message: "深度が取得できません（範囲外/暗所）")
            }
            return
        }
        lastDepthTime = now
        everReceivedDepth = true
        if depthLost {
            depthLost = false
            delegate?.depthFrameSource(self, didLogEvent: "depthResumed", message: "深度を再取得しました")
        }

        let pb = sceneDepth.depthMap   // Float32, 256x192
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        guard let depthTex = makeDepthTexture(from: pb, width: w, height: h) else { return }

        // 3) 内部パラメータ（imageResolution 基準 → depth 解像度へスケール）
        let imageRes = frame.camera.imageResolution
        let intrinsics = CameraIntrinsics.scaled(
            from: frame.camera.intrinsics,
            referenceWidth: Float(imageRes.width), referenceHeight: Float(imageRes.height),
            toWidth: w, toHeight: h)

        // 4) per-pixel confidence（0:low 1:mid 2:high）を r8Unorm(0/0.5/1.0)へ。将来のフィルタ用。
        let confTex = sceneDepth.confidenceMap.flatMap { makeConfidenceTexture(from: $0) }

        var outFrame = DepthFrame(
            depth: depthTex,
            confidence: confTex,
            color: nil,
            intrinsics: intrinsics,
            cameraToWorld: frame.camera.transform,
            width: w, height: h,
            quality: 1.0,               // LiDAR は概ね安定。per-pixel は confidence に委ねる
            timestamp: frame.timestamp,
            sensor: .lidar)

        // カラー映像＋表示行列（カラー焼き込み/オーバーレイ ON のときだけ）。
        if wantsColor {
            let orient: UIInterfaceOrientation = .portrait
            let vp = viewportSize
            outFrame.color = makeColorTexture(from: frame.capturedImage)
            outFrame.cameraView = frame.camera.viewMatrix(for: orient)
            outFrame.cameraProjection = frame.camera.projectionMatrix(
                for: orient, viewportSize: vp, zNear: 0.01, zFar: 10)
            let dt = frame.displayTransform(for: orient, viewportSize: vp).inverted()
            outFrame.displayTransformInv = simd_float3x3(
                SIMD3<Float>(Float(dt.a), Float(dt.b), 0),
                SIMD3<Float>(Float(dt.c), Float(dt.d), 0),
                SIMD3<Float>(Float(dt.tx), Float(dt.ty), 1))
        }

        delegate?.depthFrameSource(self, didOutput: outFrame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        delegate?.depthFrameSource(self, didFail: error)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        delegate?.depthFrameSource(self, didLogEvent: "sessionInterrupted",
                                   message: "セッションが中断されました")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        delegate?.depthFrameSource(self, didLogEvent: "sessionResumed",
                                   message: "セッションが再開しました")
    }

    // MARK: - Helpers

    /// 深度 CVPixelBuffer（Float32）を独立した r32Float MTLTexture へコピーする。
    private func makeDepthTexture(from pb: CVPixelBuffer, width w: Int, height h: Int) -> MTLTexture? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = context.device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
        return tex
    }

    /// confidence CVPixelBuffer（UInt8: 0/1/2）を r8Unorm(0/0.5/1.0)へ正規化コピーする。
    private func makeConfidenceTexture(from pb: CVPixelBuffer) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        let srcRow = CVPixelBufferGetBytesPerRow(pb)
        // 0..2 → 0..255 に伸ばして r8Unorm（0, 0.5, 1.0）に。
        var buf = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base + y * srcRow
            for x in 0..<w {
                let v = row[x]              // 0,1,2
                buf[y * w + x] = v >= 2 ? 255 : (v == 1 ? 128 : 0)
            }
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = context.device.makeTexture(descriptor: desc) else { return nil }
        buf.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                        mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w)
        }
        return tex
    }

    /// カメラ映像（420 YCbCr biplanar）を独立した BGRA MTLTexture へ GPU 変換する。
    private func makeColorTexture(from pb: CVPixelBuffer) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        guard CVPixelBufferGetPlaneCount(pb) >= 2,
              let (yTex, yHold) = cvTexture(pb, plane: 0, format: .r8Unorm),
              let (cbcrTex, cbcrHold) = cvTexture(pb, plane: 1, format: .rg8Unorm),
              let pso = context.computePipelineState(named: "ycbcrToBGRA") else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let out = context.device.makeTexture(descriptor: desc),
              let cb = context.commandQueue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return nil }

        enc.setComputePipelineState(pso)
        enc.setTexture(yTex, index: 0)
        enc.setTexture(cbcrTex, index: 1)
        enc.setTexture(out, index: 2)
        let (groups, tpg) = context.threadgroup2D(for: pso, width: w, height: h)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tpg)
        enc.endEncoding()
        cb.addCompletedHandler { _ in _ = (yHold, cbcrHold) }
        cb.commit()
        return out
    }

    private func cvTexture(_ pb: CVPixelBuffer, plane: Int,
                           format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        let w = CVPixelBufferGetWidthOfPlane(pb, plane)
        let h = CVPixelBufferGetHeightOfPlane(pb, plane)
        var cvTexOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, context.textureCache, pb, nil,
            format, w, h, plane, &cvTexOut)
        guard status == kCVReturnSuccess, let cvTex = cvTexOut,
              let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (tex, cvTex)
    }

    private static func map(_ s: ARCamera.TrackingState) -> ScanTrackingState {
        switch s {
        case .normal: return .normal
        case .notAvailable: return .notAvailable
        case .limited(let reason):
            return reason == .relocalizing ? .relocalizing : .limited
        }
    }
}
