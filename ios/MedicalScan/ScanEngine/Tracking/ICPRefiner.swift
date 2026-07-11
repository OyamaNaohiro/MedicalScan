//
//  ICPRefiner.swift
//  ScanEngine / Tracking
//
//  SDF ベース frame-to-model ICP。VIO 姿勢を初期値に、深度点を TSDF 表面へスナップする
//  point-to-plane 最小化を数回反復し、ドリフトを微調整した姿勢を返す。
//  位置合わせの主基準はあくまで VIO。ICP は Refinement のみ（破綻時は VIO 姿勢へフォールバック）。
//
//  GPU カーネルが点ごとの正規方程式寄与(29値)を出力 → CPU で総和・6x6 求解・姿勢更新。
//

import Metal
import simd

/// ICP の結果。pose は採用すべき姿勢、status で統合可否を判断する。
struct ICPResult {
    var pose: simd_float4x4
    var rms: Float            // 残差 RMS [m]
    var correspondences: Int
    /// .aborted=モデル不足(VIO で統合/ブートストラップ), .ok=整合良好(pose で統合),
    /// .poor=整合不良(統合スキップして既存メッシュを保護)
    enum Status { case aborted, ok, poor }
    var status: Status
}

final class ICPRefiner {

    private struct Uniforms {
        var cameraToWorld: simd_float4x4
        var fx: Float; var fy: Float; var cx: Float; var cy: Float
        var depthW: UInt32; var depthH: UInt32
        var stride: UInt32
        var dimX: Int32; var dimY: Int32; var dimZ: Int32
        var ox: Float; var oy: Float; var oz: Float
        var voxelSize: Float
        var truncation: Float
        var minWeight: Float
        var depthMin: Float; var depthMax: Float
    }

    // しきい値（発散検出）。
    private let minCorrespondences = 200
    private let maxRotation: Float = 0.15     // rad/iter
    private let maxTranslation: Float = 0.05  // m/iter

    private var partial: MTLBuffer?
    private var partialCapacity = 0

    /// VIO 姿勢 `vioPose` を初期値に ICP で微調整。結果（姿勢・残差・統合可否）を返す。
    func refine(depth: MTLTexture, mask: MTLTexture?, volume: TSDFVolume,
                intrinsics: CameraIntrinsics, width: Int, height: Int,
                vioPose: simd_float4x4, config: ScanConfig, context: MetalContext) -> ICPResult {

        let abortResult = ICPResult(pose: vioPose, rms: 0, correspondences: 0, status: .aborted)
        guard let pso = context.computePipelineState(named: "icpReduceKernel") else { return abortResult }
        let stride = max(2, config.icpStride)
        let gw = (width + stride - 1) / stride
        let gh = (height + stride - 1) / stride
        let needed = gw * gh * 30
        guard ensurePartial(count: needed, device: context.device), let partial else { return abortResult }

        var T = vioPose
        var improved = false
        var lastRms: Float = 0
        var lastCount = 0

        for _ in 0..<max(1, config.icpIterations) {
            var u = Uniforms(
                cameraToWorld: T,
                fx: intrinsics.fx, fy: intrinsics.fy, cx: intrinsics.cx, cy: intrinsics.cy,
                depthW: UInt32(width), depthH: UInt32(height), stride: UInt32(stride),
                dimX: volume.dims.x, dimY: volume.dims.y, dimZ: volume.dims.z,
                ox: volume.origin.x, oy: volume.origin.y, oz: volume.origin.z,
                voxelSize: volume.voxelSize, truncation: config.truncation,
                minWeight: config.icpMinWeight, depthMin: config.depthMin, depthMax: config.depthMax)
            var hasMask: UInt32 = mask != nil ? 1 : 0

            guard let cb = context.commandQueue.makeCommandBuffer(),
                  let enc = cb.makeComputeCommandEncoder() else {
                return improved ? makeResult(T, lastRms, lastCount, config) : abortResult
            }
            enc.setComputePipelineState(pso)
            enc.setTexture(depth, index: 0)
            enc.setTexture(mask ?? depth, index: 1)
            enc.setBuffer(volume.voxelBuffer, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setBuffer(partial, offset: 0, index: 2)
            enc.setBytes(&hasMask, length: MemoryLayout<UInt32>.stride, index: 3)
            let tg = MTLSize(width: 8, height: 8, depth: 1)
            let groups = MTLSize(width: (gw + 7) / 8, height: (gh + 7) / 8, depth: 1)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()

            // 総和（A 上三角21, b 6, err 1, agree 1, observed 1）。
            let ptr = partial.contents().bindMemory(to: Float.self, capacity: needed)
            var acc = [Double](repeating: 0, count: 30)
            let entries = gw * gh
            for i in 0..<entries {
                let base = i * 30
                for k in 0..<30 { acc[k] += Double(ptr[base + k]) }
            }
            let count = Int(acc[28])
            lastCount = count
            lastRms = count > 0 ? Float((acc[27] / Double(count)).squareRoot()) : 0
            if count < minCorrespondences {
                return improved ? makeResult(T, lastRms, lastCount, config) : abortResult
            }

            // 6x6 対称 A・b を構築。
            var A = [Double](repeating: 0, count: 36)
            var o = 0
            for j in 0..<6 {
                for k in j..<6 {
                    A[j * 6 + k] = acc[o]; A[k * 6 + j] = acc[o]; o += 1
                }
            }
            var b = [Double](repeating: 0, count: 6)
            for j in 0..<6 { b[j] = acc[21 + j] }

            // --- #1 ARKit 事前分布 + #2 劣決定ダンピング ---
            // 滑らかな側面では point-to-plane が接線方向に拘束を持たず（劣決定）、ICP が滑って
            // 観測がにじむ。現在姿勢 T から予測姿勢 vioPose(=ARKit予測) へ移す増分ツイスト
            // ξ_prior = log(vioPose·T⁻¹) を求め、これへ引き戻す事前分布を法線方程式に加える。
            // 重みは回転/並進ブロックごとに「測定情報の平均対角」でスケール（単位差を吸収）するため、
            // 拘束の強い方向では相対的に無視でき、拘束の弱い方向では支配的になって ARKit へ収束する。
            if config.icpPriorWeight > 0 {
                let M = vioPose * T.inverse   // 予測へ移す残差変換（小角）
                // delta(ω,t) 規約に整合する反対称成分から ω を、並進列から t を取り出す。
                let prior: [Double] = [
                    Double(0.5 * (M.columns.1.z - M.columns.2.y)),
                    Double(0.5 * (M.columns.2.x - M.columns.0.z)),
                    Double(0.5 * (M.columns.0.y - M.columns.1.x)),
                    Double(M.columns.3.x), Double(M.columns.3.y), Double(M.columns.3.z)]
                let rotScale = (A[0] + A[7] + A[14]) / 3.0
                let transScale = (A[21] + A[28] + A[35]) / 3.0
                let w = Double(config.icpPriorWeight)
                let lambda = [w * rotScale, w * rotScale, w * rotScale,
                              w * transScale, w * transScale, w * transScale]
                for d in 0..<6 {
                    A[d * 6 + d] += lambda[d]
                    b[d] += lambda[d] * prior[d]
                }
            }

            // 正則化（数値安定）。
            for d in 0..<6 { A[d * 6 + d] += 1e-4 * A[d * 6 + d] + 1e-7 }

            guard let xi = ICPRefiner.solve6x6(A, b) else { break }
            let omega = SIMD3<Float>(Float(xi[0]), Float(xi[1]), Float(xi[2]))
            let trans = SIMD3<Float>(Float(xi[3]), Float(xi[4]), Float(xi[5]))
            if !omega.x.isFinite || !trans.x.isFinite {
                return improved ? makeResult(T, lastRms, lastCount, config) : abortResult
            }
            if simd_length(omega) > maxRotation || simd_length(trans) > maxTranslation {
                return improved ? makeResult(T, lastRms, lastCount, config) : abortResult  // 発散
            }

            T = ICPRefiner.orthonormalized(ICPRefiner.delta(omega: omega, trans: trans) * T)
            improved = true
        }
        return improved ? makeResult(T, lastRms, lastCount, config) : abortResult
    }

    /// 残差 RMS が truncation 以下なら .ok（pose で統合）、超なら .poor（統合スキップ）。
    private func makeResult(_ pose: simd_float4x4, _ rms: Float, _ corr: Int,
                            _ config: ScanConfig) -> ICPResult {
        let status: ICPResult.Status = rms <= config.truncation ? .ok : .poor
        return ICPResult(pose: pose, rms: rms, correspondences: corr, status: status)
    }

    /// 姿勢は動かさず、与えた pose での既存モデルとの整合度のみ評価する（整合ゲート用）。
    /// 返り値: agree=表面近傍に乗った点数, observed=既存モデルと重なった点数, rms=一致点の残差[m]。
    func evaluate(depth: MTLTexture, mask: MTLTexture?, volume: TSDFVolume,
                  intrinsics: CameraIntrinsics, width: Int, height: Int,
                  pose: simd_float4x4, config: ScanConfig, context: MetalContext)
        -> (rms: Float, agree: Int, observed: Int) {

        guard let pso = context.computePipelineState(named: "icpReduceKernel") else { return (0, 0, 0) }
        let stride = max(2, config.icpStride)
        let gw = (width + stride - 1) / stride
        let gh = (height + stride - 1) / stride
        let needed = gw * gh * 30
        guard ensurePartial(count: needed, device: context.device), let partial else { return (0, 0, 0) }

        var u = Uniforms(
            cameraToWorld: pose,
            fx: intrinsics.fx, fy: intrinsics.fy, cx: intrinsics.cx, cy: intrinsics.cy,
            depthW: UInt32(width), depthH: UInt32(height), stride: UInt32(stride),
            dimX: volume.dims.x, dimY: volume.dims.y, dimZ: volume.dims.z,
            ox: volume.origin.x, oy: volume.origin.y, oz: volume.origin.z,
            voxelSize: volume.voxelSize, truncation: config.truncation,
            minWeight: config.icpMinWeight, depthMin: config.depthMin, depthMax: config.depthMax)
        var hasMask: UInt32 = mask != nil ? 1 : 0

        guard let cb = context.commandQueue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return (0, 0, 0) }
        enc.setComputePipelineState(pso)
        enc.setTexture(depth, index: 0)
        enc.setTexture(mask ?? depth, index: 1)
        enc.setBuffer(volume.voxelBuffer, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setBuffer(partial, offset: 0, index: 2)
        enc.setBytes(&hasMask, length: MemoryLayout<UInt32>.stride, index: 3)
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(width: (gw + 7) / 8, height: (gh + 7) / 8, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        let ptr = partial.contents().bindMemory(to: Float.self, capacity: needed)
        var sumErr = 0.0, sumAgree = 0.0, sumObs = 0.0
        let entries = gw * gh
        for i in 0..<entries {
            let base = i * 30
            sumErr += Double(ptr[base + 27])
            sumAgree += Double(ptr[base + 28])
            sumObs += Double(ptr[base + 29])
        }
        let agree = Int(sumAgree), observed = Int(sumObs)
        let rms = agree > 0 ? Float((sumErr / Double(agree)).squareRoot()) : 999
        return (rms, agree, observed)
    }

    private func ensurePartial(count: Int, device: MTLDevice) -> Bool {
        if partial != nil, partialCapacity >= count { return true }
        guard let buf = device.makeBuffer(length: count * MemoryLayout<Float>.stride,
                                          options: .storageModeShared) else { return false }
        partial = buf
        partialCapacity = count
        return true
    }

    // MARK: - 線形代数

    /// 小角近似の増分変換 ΔT（ワールド点に p' = p + ω×p + t）。
    private static func delta(omega w: SIMD3<Float>, trans t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(1,    w.z, -w.y, 0),
            SIMD4<Float>(-w.z, 1,    w.x, 0),
            SIMD4<Float>(w.y, -w.x,  1,   0),
            SIMD4<Float>(t.x,  t.y,  t.z, 1)))
    }

    /// 回転部を Gram-Schmidt で正規直交化（小角近似の累積誤差対策）。
    private static func orthonormalized(_ m: simd_float4x4) -> simd_float4x4 {
        var x = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        var y = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        x = simd_normalize(x)
        y = simd_normalize(y - simd_dot(x, y) * x)
        let z = simd_cross(x, y)
        return simd_float4x4(columns: (
            SIMD4<Float>(x.x, x.y, x.z, 0),
            SIMD4<Float>(y.x, y.y, y.z, 0),
            SIMD4<Float>(z.x, z.y, z.z, 0),
            m.columns.3))
    }

    /// 6x6 連立をガウス消去（部分ピボット）で解く。特異なら nil。
    private static func solve6x6(_ Ain: [Double], _ bin: [Double]) -> [Double]? {
        var A = Ain, b = bin
        let n = 6
        for col in 0..<n {
            var piv = col
            var best = abs(A[col * n + col])
            for r in (col + 1)..<n {
                let v = abs(A[r * n + col]); if v > best { best = v; piv = r }
            }
            if best < 1e-12 { return nil }
            if piv != col {
                for c in 0..<n { A.swapAt(col * n + c, piv * n + c) }
                b.swapAt(col, piv)
            }
            let d = A[col * n + col]
            for r in 0..<n where r != col {
                let factor = A[r * n + col] / d
                if factor == 0 { continue }
                for c in col..<n { A[r * n + c] -= factor * A[col * n + c] }
                b[r] -= factor * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n { x[i] = b[i] / A[i * n + i] }
        return x
    }
}
