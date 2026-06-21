//
//  ScanEnginePreviewView.swift
//  ScanEngine / Rendering
//
//  描画専用の MTKView。DepthFrame を受け取り、表示モードに応じて深度を可視化するだけ。
//  スキャン処理・解析は一切持たない（責務分離: 取得/融合は ScanEngine 側）。
//
//  自己計測（描画FPS・GPU時間）のみ onRenderMetrics で外へ通知する。
//

import MetalKit
import simd

final class ScanEnginePreviewView: MTKView {

    /// シェーダ uniforms（metal の PreviewUniforms とレイアウト一致）。
    private struct PreviewUniforms {
        var depthMin: Float
        var depthMax: Float
        var mode: UInt32
        var orientation: UInt32
        var mirror: UInt32
    }

    // MARK: - 公開設定

    var displayMode: DepthDisplayMode = .filtered
    var depthMin: Float = 0.2
    var depthMax: Float = 0.9
    /// 深度センサー（横長）→ ポートレート補正。前面 TrueDepth の既定。実機で要微調整。
    var orientation: UInt32 = 1
    var mirror: Bool = true

    /// 1 フレーム描画ごとの自己計測通知（GPU 時間[ms]・描画FPS）。メインスレッドで呼ぶ。
    var onRenderMetrics: ((_ gpuMs: Double, _ fps: Double) -> Void)?

    // MARK: - 内部

    private let context: MetalContext
    private var pipeline: MTLRenderPipelineState?
    private var latestDepth: MTLTexture?
    private let fpsCounter = RateCounter(alpha: 0.15)

    // MARK: - Init

    init?(context: MetalContext) {
        self.context = context
        super.init(frame: .zero, device: context.device)

        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isOpaque = true
        // 新しい深度が来たときだけ描く（無駄な GPU 稼働を避ける）。
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let library = context.library,
              let vfn = library.makeFunction(name: "depthPreviewVertex"),
              let ffn = library.makeFunction(name: "depthPreviewFragment") else {
            return nil
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        guard let pso = try? context.device.makeRenderPipelineState(descriptor: desc) else {
            return nil
        }
        pipeline = pso
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - 入力（描画のみ）

    /// 新しい深度フレームを受け取り、再描画を要求する。
    func update(depth: MTLTexture, depthMin: Float, depthMax: Float) {
        self.latestDepth = depth
        self.depthMin = depthMin
        self.depthMax = depthMax
        setNeedsDisplay()
    }
}

// MARK: - MTKViewDelegate（描画ループ）

extension ScanEnginePreviewView: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline,
              let depth = latestDepth,
              let drawable = currentDrawable,
              let passDescriptor = currentRenderPassDescriptor,
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }

        var uniforms = PreviewUniforms(depthMin: depthMin, depthMax: depthMax,
                                       mode: UInt32(displayMode.rawValue),
                                       orientation: orientation,
                                       mirror: mirror ? 1 : 0)

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(depth, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] cb in
            guard let self else { return }
            let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0
            DispatchQueue.main.async {
                self.fpsCounter.tick()
                self.onRenderMetrics?(gpuMs, self.fpsCounter.fps)
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
