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
import UIKit
import simd

final class TrueDepthSource: NSObject, DepthFrameSource, ARSessionDelegate {

    let sensor: ScanSensor = .trueDepth
    weak var delegate: DepthFrameSourceDelegate?

    private let context: MetalContext
    private let session = ARSession()
    private let queue = DispatchQueue(label: "scanengine.truedepth.capture", qos: .userInitiated)
    private var lastTracking: ScanTrackingState?

    // AR オーバーレイ（カメラ映像へメッシュを重ねる）用。ON のときだけカラーと行列を取得する。
    private var wantsColor = false
    /// 表示ビューのサイズ[pt]（ARKit の投影/表示変換に使う）。既定は縦長端末の目安。
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

    func setColorCapture(_ enabled: Bool) { wantsColor = enabled }

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

        var outFrame = DepthFrame(
            depth: depthTex,
            confidence: nil,                    // TrueDepth は per-pixel confidence 非提供
            color: nil,                         // AR オーバーレイ ON のとき下で設定
            intrinsics: intrinsics,
            cameraToWorld: frame.camera.transform,
            width: w, height: h,
            quality: quality,
            timestamp: frame.timestamp,
            sensor: .trueDepth)

        // AR オーバーレイ用にカラー映像と表示行列を取得（ON のときだけ・負荷を避ける）。
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

    /// カメラ映像（420 YCbCr biplanar）を独立した BGRA MTLTexture へ GPU 変換する。
    /// 入力 CVPixelBuffer は ARFrame 寿命に縛られるため、CVMetalTexture を GPU 完了まで retain し、
    /// 出力は所有テクスチャに切り離す（同一 command queue 順序でプレビュー描画前に完了が保証される）。
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
        // 入力 CVMetalTexture を GPU 完了まで生かす（use-after-free 回避）。
        cb.addCompletedHandler { _ in _ = (yHold, cbcrHold) }
        cb.commit()
        return out
    }

    /// CVPixelBuffer の 1 プレーンを CVMetalTextureCache 経由でゼロコピー texture 化する。
    /// 戻り値の CVMetalTexture は GPU 完了まで保持する必要がある（呼び出し側で retain）。
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
            // 再ローカライズ中は区別（中断復帰など）。他は limited。
            return reason == .relocalizing ? .relocalizing : .limited
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
