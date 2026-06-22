//
//  TrueDepthSource.swift
//  ScanEngine / Capture
//
//  前面 TrueDepth カメラ（主軸センサー）の DepthFrameSource 実装。
//  ARFaceTrackingConfiguration を使い、フレーム毎に AVDepthData とカメラ姿勢を取り出して
//  DepthFrame に詰め替える。per-pixel confidence は無いので quality + レンジで代替する。
//
//  数学的メモ:
//   - AVDepthData.cameraCalibrationData の内部パラメータは「参照解像度」基準なので、
//     実 depth 解像度へ線形スケールして CameraIntrinsics を作る。
//   - 深度 CVPixelBuffer は ARFrame 寿命に縛られるため、独立した MTLTexture へコピーして
//     渡す（use-after-free を回避。サイズ ~1.2MB/frame、Phase 8 で二重バッファ最適化）。
//

import ARKit
import AVFoundation
import Metal
import simd

final class TrueDepthSource: NSObject, DepthFrameSource, ARSessionDelegate {

    let sensor: ScanSensor = .trueDepth
    weak var delegate: DepthFrameSourceDelegate?

    private let context: MetalContext
    private let session = ARSession()
    private let queue = DispatchQueue(label: "scanengine.truedepth.capture", qos: .userInitiated)
    private var lastTracking: ScanTrackingState?

    // 深度ロスト検知用。
    private var lastDepthTime: TimeInterval = 0
    private var everReceivedDepth = false
    private var depthLost = false
    private let depthLostTimeout: TimeInterval = 0.5

    init(context: MetalContext) {
        self.context = context
        super.init()
        session.delegate = self
        session.delegateQueue = queue   // 通知を専用直列キューに集約
    }

    // MARK: - DepthFrameSource

    func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            delegate?.depthFrameSource(self, didFail: ScanEngineError.sensorUnavailable(
                "この端末は TrueDepth（Face ID）に対応していません。"))
            return
        }
        let config = ARFaceTrackingConfiguration()
        // 端末が対応していればワールド姿勢を有効化（TSDF への姿勢統合に必要）。
        if ARFaceTrackingConfiguration.supportsWorldTracking {
            config.isWorldTrackingEnabled = true
        }
        config.isLightEstimationEnabled = false
        config.maximumNumberOfTrackedFaces = 1
        lastTracking = nil
        lastDepthTime = 0
        everReceivedDepth = false
        depthLost = false
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // 1) トラッキング状態の変化を通知
        let tracking = Self.map(frame.camera.trackingState)
        if tracking != lastTracking {
            lastTracking = tracking
            delegate?.depthFrameSource(self, didChangeTracking: tracking)
        }

        // 2) 深度が無いフレームはスキップ。一定時間来なければ「depthLost」を通知。
        let now = frame.timestamp
        guard let avDepth = frame.capturedDepthData else {
            if everReceivedDepth, !depthLost, now - lastDepthTime > depthLostTimeout {
                depthLost = true
                delegate?.depthFrameSource(self, didLogEvent: "depthLost",
                    message: "深度が取得できません（覆われている/範囲外）")
            }
            return
        }
        lastDepthTime = now
        everReceivedDepth = true
        if depthLost {
            depthLost = false
            delegate?.depthFrameSource(self, didLogEvent: "depthResumed", message: "深度を再取得しました")
        }

        // 3) Float32 深度へ正規化
        var depthData = avDepth
        if depthData.depthDataType != kCVPixelFormatType_DepthFloat32 {
            depthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }
        let pb = depthData.depthDataMap
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)

        guard let depthTex = makeDepthTexture(from: pb, width: w, height: h) else { return }

        // 4) 内部パラメータ（depth 解像度へスケール）
        let intrinsics: CameraIntrinsics
        if let calib = depthData.cameraCalibrationData {
            intrinsics = CameraIntrinsics.scaled(
                from: calib.intrinsicMatrix,
                referenceWidth: Float(calib.intrinsicMatrixReferenceDimensions.width),
                referenceHeight: Float(calib.intrinsicMatrixReferenceDimensions.height),
                toWidth: w, toHeight: h)
        } else {
            // フォールバック: 焦点距離を画素幅相当で推定
            intrinsics = CameraIntrinsics(fx: Float(w), fy: Float(w),
                                          cx: Float(w) / 2, cy: Float(h) / 2)
        }

        // 5) 品質スコア（フレーム単位の足切りに使用）
        let quality: Float
        switch depthData.depthDataQuality {
        case .high: quality = 1.0
        case .low:  quality = 0.4
        @unknown default: quality = 0.6
        }

        let outFrame = DepthFrame(
            depth: depthTex,
            confidence: nil,                    // TrueDepth は per-pixel confidence 非提供
            color: nil,                         // Phase 2 ではカラー未取得
            intrinsics: intrinsics,
            cameraToWorld: frame.camera.transform,
            width: w, height: h,
            quality: quality,
            timestamp: frame.timestamp,
            sensor: .trueDepth)

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

    /// 深度 CVPixelBuffer を独立した r32Float MTLTexture へコピーする。
    /// ARFrame の寿命に依存しないようにコピーで切り離す。
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

    private static func map(_ s: ARCamera.TrackingState) -> ScanTrackingState {
        switch s {
        case .normal: return .normal
        case .limited: return .limited
        case .notAvailable: return .notAvailable
        }
    }
}

// MARK: - エラー型

enum ScanEngineError: LocalizedError {
    case sensorUnavailable(String)
    case metalUnavailable

    var errorDescription: String? {
        switch self {
        case .sensorUnavailable(let m): return m
        case .metalUnavailable: return "Metal を初期化できませんでした。"
        }
    }
}
