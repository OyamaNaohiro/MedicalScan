//
//  TemporalFilter.swift
//  ScanEngine / Filtering
//
//  フレーム間ノイズ低減。既定は EMA（α=0.2）。Strategy 化して将来 MovingAverage / Kalman /
//  None に切替可能。深度差ゲート（|cur-prev|>閾値は混ぜない）でゴーストを防ぐ。
//
//  MotionGate: camera.transform の並進・回転量から実効 α を調整する。
//  動きが大きいフレームは α→1（current 重視）にして残像を防ぐ。
//
//  履歴は 2 枚のテクスチャを ping-pong して保持（毎フレーム生成しない）。
//

import Metal
import simd

/// 時間統合の戦略。初期実装は EMA。MovingAverage/Kalman は将来拡張（現状 EMA にフォールバック）。
enum TemporalStrategy: Int {
    case none = 0          // 統合しない（passthrough）
    case ema = 1           // 指数移動平均（既定）
    case movingAverage = 2 // 単純移動平均（未実装→暫定 EMA）
    case kalman = 3        // カルマン（未実装→暫定 EMA）
}

final class TemporalFilter: DepthFilter {

    let name = "Temporal"
    var isEnabled = true
    let priority = 30

    var strategy: TemporalStrategy = .ema
    var baseAlpha: Float
    var diffThresh: Float = 0.03      // 3cm 以上違えば混ぜない

    // MotionGate のしきい値（1フレームあたり）。
    var translationMax: Float = 0.02  // 2cm
    var rotationMax: Float = 0.05      // ~2.9°

    private struct Uniforms {
        var alpha: Float
        var diffThresh: Float
        var hasHistory: UInt32
    }

    // ping-pong 履歴テクスチャ。
    private var texA: MTLTexture?
    private var texB: MTLTexture?
    private var writeToA = true
    private var lastOutput: MTLTexture?
    private var prevPose: simd_float4x4?
    private var hasHistory = false
    private var allocW = 0
    private var allocH = 0

    init(config: ScanConfig) {
        self.baseAlpha = config.temporalAlpha
    }

    func reset() {
        hasHistory = false
        prevPose = nil
        lastOutput = nil
        writeToA = true
    }

    func encode(_ frame: DepthFrame,
                commandBuffer: MTLCommandBuffer,
                context: MetalContext) -> DepthFrame {
        // None は素通し。
        if strategy == .none { return frame }

        guard let pso = context.computePipelineState(named: "temporalFilterKernel"),
              ensureOutputs(width: frame.width, height: frame.height, device: context.device),
              let texA, let texB,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return frame
        }

        let outTex = writeToA ? texA : texB
        let prevTex = lastOutput ?? texB   // 履歴なし時はダミー（hasHistory=0 で無視される）
        let alpha = effectiveAlpha(for: frame.cameraToWorld)

        var u = Uniforms(alpha: alpha, diffThresh: diffThresh,
                         hasHistory: hasHistory ? 1 : 0)
        encoder.setComputePipelineState(pso)
        encoder.setTexture(frame.depth, index: 0)
        encoder.setTexture(prevTex, index: 1)
        encoder.setTexture(outTex, index: 2)
        encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        let (groups, tpg) = context.threadgroup2D(for: pso, width: frame.width, height: frame.height)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tpg)
        encoder.endEncoding()

        // 次フレーム用に状態更新。
        lastOutput = outTex
        writeToA.toggle()
        hasHistory = true
        prevPose = frame.cameraToWorld

        var out = frame
        out.depth = outTex
        out.filterFlags |= FilterFlag.temporal
        return out
    }

    // MARK: - MotionGate

    /// 並進・回転量から実効 α を決める。静止時=baseAlpha（強い平滑化）、大きく動くと α→1（残像防止）。
    private func effectiveAlpha(for pose: simd_float4x4) -> Float {
        guard let prev = prevPose else { return 1.0 }

        let tCur = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let tPrev = SIMD3<Float>(prev.columns.3.x, prev.columns.3.y, prev.columns.3.z)
        let trans = simd_length(tCur - tPrev)
        let rot = relativeRotationAngle(prev, pose)

        // 並進・回転の正規化値のうち大きい方をゲートに採用。
        let gate = min(1.0, max(trans / translationMax, rot / rotationMax))
        return baseAlpha + gate * (1.0 - baseAlpha)
    }

    /// 2 姿勢間の相対回転角[rad]。R = Rp^T·Rc、angle = acos((trace(R)-1)/2)。
    private func relativeRotationAngle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let ra = simd_float3x3(SIMD3(a.columns.0.x, a.columns.0.y, a.columns.0.z),
                               SIMD3(a.columns.1.x, a.columns.1.y, a.columns.1.z),
                               SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z))
        let rb = simd_float3x3(SIMD3(b.columns.0.x, b.columns.0.y, b.columns.0.z),
                               SIMD3(b.columns.1.x, b.columns.1.y, b.columns.1.z),
                               SIMD3(b.columns.2.x, b.columns.2.y, b.columns.2.z))
        let r = ra.transpose * rb
        let trace = r.columns.0.x + r.columns.1.y + r.columns.2.z
        let c = max(-1.0, min(1.0, (trace - 1.0) * 0.5))
        return acos(c)
    }

    private func ensureOutputs(width: Int, height: Int, device: MTLDevice) -> Bool {
        if texA != nil, allocW == width, allocH == height { return true }
        func make() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let a = make(), let b = make() else { return false }
        texA = a; texB = b
        allocW = width; allocH = height
        hasHistory = false
        lastOutput = nil
        writeToA = true
        return true
    }
}
