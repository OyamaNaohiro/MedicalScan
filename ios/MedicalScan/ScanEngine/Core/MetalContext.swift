//
//  MetalContext.swift
//  ScanEngine / Core
//
//  GPU 資源（device / commandQueue / library / CVMetalTextureCache）を一元保持し、
//  パイプライン全段（Filtering・Fusion(TSDF)・Meshing）で共有する。
//
//  設計意図（Phase 4 で再設計しないための布石）:
//   - Compute Pipeline は関数名でキャッシュして再利用 → 将来 TSDF / Marching Cubes /
//     Bilateral の各 compute kernel を `computePipelineState(named:)` で取得するだけで足りる。
//   - BufferPool / TexturePool を内蔵 → 毎フレームの確保/解放を避け、メモリコピーと
//     アロケーションコストを削減（GPU最適化方針）。
//   - library は遅延・任意（.metal 未追加でも基盤がビルド/起動できる）。
//

import Metal
import CoreVideo

/// アプリ全体で 1 つだけ生成して共有する GPU コンテキスト。
final class MetalContext {

    // MARK: - Core objects

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    /// default.metallib（.metal を 1 つ以上ターゲットに追加すると生成される）。
    /// 基盤フェーズでは未追加のため nil 許容。compute kernel 利用時に解決する。
    let library: MTLLibrary?

    /// CVPixelBuffer（カメラ depth / color）→ MTLTexture のゼロコピー変換に使う。
    let textureCache: CVMetalTextureCache

    // MARK: - Reuse pools（GPU最適化: 再確保を避ける）

    let bufferPool: BufferPool
    let texturePool: TexturePool

    // MARK: - Compute pipeline cache

    private var computePipelines: [String: MTLComputePipelineState] = [:]
    private let pipelineLock = NSLock()

    // MARK: - Init

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let textureCache = cache else { return nil }

        self.device = device
        self.commandQueue = queue
        self.textureCache = textureCache
        // .metal 未追加なら nil（throws）。基盤フェーズでは正常。
        self.library = try? device.makeDefaultLibrary(bundle: .main)
        self.bufferPool = BufferPool(device: device)
        self.texturePool = TexturePool(device: device)
    }

    // MARK: - Compute pipeline (将来の各 kernel 用。関数名でキャッシュ)

    /// 関数名から compute pipeline を取得（生成済みなら再利用）。
    /// TSDF integrate / bilateral / marching cubes 等を追加するときの唯一の入口。
    func computePipelineState(named functionName: String) -> MTLComputePipelineState? {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }

        if let cached = computePipelines[functionName] { return cached }
        guard let library, let fn = library.makeFunction(name: functionName) else { return nil }
        guard let pso = try? device.makeComputePipelineState(function: fn) else { return nil }
        computePipelines[functionName] = pso
        return pso
    }

    /// 1スレッドグループあたりのスレッド数を pipeline から決める補助（2D ディスパッチ用）。
    func threadgroup2D(for pso: MTLComputePipelineState,
                       width: Int, height: Int) -> (MTLSize, MTLSize) {
        let w = pso.threadExecutionWidth
        let h = max(1, pso.maxTotalThreadsPerThreadgroup / w)
        let tpg = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(width: (width + w - 1) / w,
                             height: (height + h - 1) / h,
                             depth: 1)
        return (groups, tpg)
    }
}

// MARK: - BufferPool

/// 同サイズの MTLBuffer を使い回す軽量プール。length をバケットに丸めて管理する。
final class BufferPool {
    private let device: MTLDevice
    private var free: [Int: [MTLBuffer]] = [:]
    private let lock = NSLock()

    init(device: MTLDevice) { self.device = device }

    /// 指定長以上のバッファを取得（プールにあれば再利用）。
    func acquire(length: Int,
                 options: MTLResourceOptions = .storageModeShared) -> MTLBuffer? {
        let bucket = BufferPool.bucket(for: length)
        lock.lock()
        if var list = free[bucket], let buf = list.popLast() {
            free[bucket] = list
            lock.unlock()
            return buf
        }
        lock.unlock()
        return device.makeBuffer(length: bucket, options: options)
    }

    /// 使い終わったバッファをプールへ返す。
    func release(_ buffer: MTLBuffer) {
        let bucket = BufferPool.bucket(for: buffer.length)
        lock.lock()
        free[bucket, default: []].append(buffer)
        lock.unlock()
    }

    func drain() {
        lock.lock(); free.removeAll(); lock.unlock()
    }

    /// 2 の冪の近傍に丸めて断片化を抑える。
    private static func bucket(for length: Int) -> Int {
        var b = 256
        while b < length { b <<= 1 }
        return b
    }
}

// MARK: - TexturePool

/// 同一ディスクリプタの MTLTexture を使い回すプール。中間テクスチャ（フィルタ出力等）向け。
final class TexturePool {
    private let device: MTLDevice
    private var free: [String: [MTLTexture]] = [:]
    private let lock = NSLock()

    init(device: MTLDevice) { self.device = device }

    func acquire(width: Int, height: Int,
                 pixelFormat: MTLPixelFormat,
                 usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) -> MTLTexture? {
        let key = "\(width)x\(height)x\(pixelFormat.rawValue)x\(usage.rawValue)"
        lock.lock()
        if var list = free[key], let tex = list.popLast() {
            free[key] = list
            lock.unlock()
            return tex
        }
        lock.unlock()

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = usage
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    func release(_ texture: MTLTexture) {
        let key = "\(texture.width)x\(texture.height)x\(texture.pixelFormat.rawValue)x\(texture.usage.rawValue)"
        lock.lock()
        free[key, default: []].append(texture)
        lock.unlock()
    }

    func drain() {
        lock.lock(); free.removeAll(); lock.unlock()
    }
}
