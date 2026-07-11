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
        var hasFiltered: UInt32
        var hasMask: UInt32
    }

    /// metal の CameraBGUniforms とレイアウト一致（float3x3）。
    private struct CameraBGUniforms {
        var uvTransform: simd_float3x3
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
    private var slicePipeline: MTLRenderPipelineState?
    private var meshPipeline: MTLRenderPipelineState?
    private var cameraBGPipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var bgDepthState: MTLDepthStencilState?
    private var rawDepth: MTLTexture?
    private var filteredDepth: MTLTexture?
    private var validMask: MTLTexture?
    private var sliceTexture: MTLTexture?   // 非nilなら TSDF スライスを優先表示
    private let fpsCounter = RateCounter(alpha: 0.15)

    // Mesh 3D 表示
    private var meshBuffer: MTLBuffer?
    private var meshCount = 0
    private var meshCenter = SIMD3<Float>(0, 0, 0)
    private var meshRadius: Float = 0.5
    /// 撮影中カメラの最新姿勢（ワールド）。カメラ位置リンク表示に使う。
    private var cameraToWorld: simd_float4x4?
    /// 方向追従の平滑化済み視線方向（メッシュ中心→視点）。ジッタ抑制用に保持。
    private var smoothedDir = SIMD3<Float>(0, 0, 1)
    /// true でメッシュを「撮影中カメラの向き」に方向追従して描画（中心固定・一定距離）。
    var followCamera = false

    // AR オーバーレイ（カメラ映像へメッシュを重ねるライブ表示）。
    private var colorTexture: MTLTexture?
    private var camView: simd_float4x4?
    private var camProj: simd_float4x4?
    private var camUVTransform = matrix_identity_float3x3
    /// true でメッシュ表示時にカメラ映像を背景に描画し、実カメラ行列でメッシュを重ねる。
    var arOverlay = false
    /// true で 3D メッシュ表示（連続描画して自動回転）。
    var meshEnabled = false {
        didSet {
            isPaused = !meshEnabled        // メッシュ表示中は連続描画
            if !meshEnabled { setNeedsDisplay() }
        }
    }

    // MARK: - Init

    init?(context: MetalContext) {
        self.context = context
        super.init(frame: .zero, device: context.device)

        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float   // メッシュ 3D 描画の深度テスト用
        framebufferOnly = true
        isOpaque = true
        // 新しい深度が来たときだけ描く（無駄な GPU 稼働を避ける）。メッシュ表示時は連続描画。
        isPaused = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 60
        delegate = self
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let library = context.library,
              let vfn = library.makeFunction(name: "depthPreviewVertex"),
              let ffn = library.makeFunction(name: "depthPreviewFragment") else {
            return nil
        }
        // 深度アタッチメントを持つパスで使うため、全パイプラインで depth フォーマットを一致させる。
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.depthAttachmentPixelFormat = depthStencilPixelFormat
        guard let pso = try? context.device.makeRenderPipelineState(descriptor: desc) else {
            return nil
        }
        pipeline = pso

        // TSDF スライス表示用パイプライン（同じ頂点 + RGBA そのまま表示）。
        if let sliceFn = library.makeFunction(name: "tsdfSlicePreviewFragment") {
            let sdesc = MTLRenderPipelineDescriptor()
            sdesc.vertexFunction = vfn
            sdesc.fragmentFunction = sliceFn
            sdesc.colorAttachments[0].pixelFormat = colorPixelFormat
            sdesc.depthAttachmentPixelFormat = depthStencilPixelFormat
            slicePipeline = try? context.device.makeRenderPipelineState(descriptor: sdesc)
        }

        // Mesh 3D 描画パイプライン（深度テスト付き）。
        if let mvfn = library.makeFunction(name: "meshVertex"),
           let mffn = library.makeFunction(name: "meshFragment") {
            let mdesc = MTLRenderPipelineDescriptor()
            mdesc.vertexFunction = mvfn
            mdesc.fragmentFunction = mffn
            mdesc.colorAttachments[0].pixelFormat = colorPixelFormat
            mdesc.depthAttachmentPixelFormat = depthStencilPixelFormat
            meshPipeline = try? context.device.makeRenderPipelineState(descriptor: mdesc)
        }
        // カメラ映像背景（AR オーバーレイ）パイプライン。フルスクリーン頂点 + YCbCr変換済みBGRA表示。
        if let cbgFn = library.makeFunction(name: "cameraBGFragment") {
            let cdesc = MTLRenderPipelineDescriptor()
            cdesc.vertexFunction = vfn
            cdesc.fragmentFunction = cbgFn
            cdesc.colorAttachments[0].pixelFormat = colorPixelFormat
            cdesc.depthAttachmentPixelFormat = depthStencilPixelFormat
            cameraBGPipeline = try? context.device.makeRenderPipelineState(descriptor: cdesc)
        }

        let dsd = MTLDepthStencilDescriptor()
        dsd.depthCompareFunction = .less
        dsd.isDepthWriteEnabled = true
        depthState = context.device.makeDepthStencilState(descriptor: dsd)

        // 背景は深度を書かない（メッシュを常に前面に）。
        let bgdsd = MTLDepthStencilDescriptor()
        bgdsd.depthCompareFunction = .always
        bgdsd.isDepthWriteEnabled = false
        bgDepthState = context.device.makeDepthStencilState(descriptor: bgdsd)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - 入力（描画のみ）

    /// 新しいフレームを受け取り、再描画を要求する。
    /// - Parameters:
    ///   - raw: 入力深度（Raw/Difference 用、常に存在）
    ///   - filtered: フィルタ後深度（Filtered/Difference 用、無ければ nil）
    ///   - mask: 有効画素マスク（ValidMask 用、無ければ nil）
    func update(raw: MTLTexture, filtered: MTLTexture?, mask: MTLTexture?,
                depthMin: Float, depthMax: Float) {
        self.rawDepth = raw
        self.filteredDepth = filtered
        self.validMask = mask
        self.depthMin = depthMin
        self.depthMax = depthMax
        setNeedsDisplay()
    }

    /// TSDF スライステクスチャを設定（nil で深度表示に戻る）。
    func updateSlice(_ texture: MTLTexture?) {
        self.sliceTexture = texture
        setNeedsDisplay()
    }

    /// 3D 表示するメッシュを設定（vertex soup = MCVertex 32B/頂点）。
    func updateMesh(buffer: MTLBuffer?, count: Int, center: SIMD3<Float>, radius: Float) {
        self.meshBuffer = buffer
        self.meshCount = count
        self.meshCenter = center
        self.meshRadius = max(0.05, radius)
    }

    /// 撮影中カメラの姿勢を更新（カメラ位置リンク表示用）。
    func updateCameraPose(_ pose: simd_float4x4) {
        self.cameraToWorld = pose
    }

    /// AR オーバーレイ用のカメラ映像・行列を更新（取得できたフレームのみ）。
    func updateCamera(color: MTLTexture?, view: simd_float4x4?,
                      projection: simd_float4x4?, uvTransform: simd_float3x3?) {
        self.colorTexture = color
        self.camView = view
        self.camProj = projection
        if let uvTransform { self.camUVTransform = uvTransform }
    }

    /// メッシュ描画の MVP を作る。
    /// followCamera かつ姿勢があれば「撮影中カメラの向き」に方向追従（中心固定・一定距離）。
    /// それ以外は時間で回る軌道カメラ（自動回転）。
    fileprivate func meshMVP(aspect: Float) -> simd_float4x4 {
        let proj = Self.perspective(fovY: 60 * .pi / 180, aspect: aspect,
                                    near: 0.02, far: meshRadius * 12 + 1)
        if followCamera, let c = cameraToWorld {
            // 「今カメラが見ている方向」だけを使い、距離は一定にしてメッシュ中心を見る。
            // 実距離を使う完全追従(AR)と違い、常に中心・一定サイズで映るので画面外に消えない。
            // ＝センサーが今観測している面が正面を向く、直感的な見え方になる。
            let camPos = SIMD3<Float>(c.columns.3.x, c.columns.3.y, c.columns.3.z)
            let toCam = camPos - meshCenter
            let len = simd_length(toCam)
            let unit = len > 1e-4 ? toCam / len : SIMD3<Float>(0, 0, 1)
            // 方向を平滑化して実カメラの向きに滑らかに追従（ジッタ抑制）。線形補間→正規化。
            smoothedDir = simd_length(smoothedDir) < 1e-4
                ? unit : simd_normalize(smoothedDir + (unit - smoothedDir) * Float(0.12))
            let dist = meshRadius * 2.2
            let eye = meshCenter + smoothedDir * dist
            // 真上/真下付近では up=(0,1,0) が退化するので水平軸に切り替える。
            let up = abs(smoothedDir.y) > 0.99 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
            let view = Self.lookAt(eye: eye, center: meshCenter, up: up)
            return proj * view
        }
        let t = Float(CACurrentMediaTime())
        let angle = t * 0.6
        let dist = meshRadius * 2.0   // 実メッシュ境界に寄せて大きく表示
        let eye = meshCenter + SIMD3<Float>(cos(angle) * dist, meshRadius * 0.5, sin(angle) * dist)
        let view = Self.lookAt(eye: eye, center: meshCenter, up: SIMD3<Float>(0, 1, 0))
        return proj * view
    }

    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)))
    }
}

// MARK: - MTKViewDelegate（描画ループ）

extension ScanEnginePreviewView: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let passDescriptor = currentRenderPassDescriptor,
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }

        if meshEnabled, let meshPipeline, let meshBuffer, meshCount > 0 {
            // AR オーバーレイ ON: まずカメラ映像を背景に描画（深度は書かない）。
            if arOverlay, let cameraBGPipeline, let colorTexture {
                var bgU = CameraBGUniforms(uvTransform: camUVTransform)
                encoder.setRenderPipelineState(cameraBGPipeline)
                if let bgDepthState { encoder.setDepthStencilState(bgDepthState) }
                encoder.setFragmentTexture(colorTexture, index: 0)
                encoder.setFragmentBytes(&bgU, length: MemoryLayout<CameraBGUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            // メッシュ描画（深度テスト付き）。
            // AR オーバーレイ時は実カメラ行列で映像に重ね、それ以外は軌道/カメラ位置リンク。
            let aspect = Float(max(1, drawableSize.width) / max(1, drawableSize.height))
            var mvp: simd_float4x4
            if arOverlay, let camProj, let camView {
                mvp = camProj * camView
            } else {
                mvp = meshMVP(aspect: aspect)
            }
            encoder.setRenderPipelineState(meshPipeline)
            if let depthState { encoder.setDepthStencilState(depthState) }
            encoder.setCullMode(.none)   // vertex soup は向き不定
            encoder.setVertexBuffer(meshBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: meshCount)
            encoder.endEncoding()
        } else if let slicePipeline, let slice = sliceTexture, !meshEnabled {
            // TSDF スライス表示（RGBA そのまま）。
            encoder.setRenderPipelineState(slicePipeline)
            encoder.setFragmentTexture(slice, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        } else if let pipeline, let raw = rawDepth {
            // 深度表示。nil テクスチャは raw で代替バインドし、フラグで有無を伝える。
            var uniforms = PreviewUniforms(depthMin: depthMin, depthMax: depthMax,
                                           mode: UInt32(displayMode.rawValue),
                                           orientation: orientation,
                                           mirror: mirror ? 1 : 0,
                                           hasFiltered: filteredDepth != nil ? 1 : 0,
                                           hasMask: validMask != nil ? 1 : 0)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(raw, index: 0)
            encoder.setFragmentTexture(filteredDepth ?? raw, index: 1)
            encoder.setFragmentTexture(validMask ?? raw, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        } else {
            encoder.endEncoding()
        }

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
