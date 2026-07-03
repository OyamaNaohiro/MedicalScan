//
//  KeyframeRecorder.swift
//  ScanEngine / Export / GlobalOpt
//
//  スキャン中にキーフレームを「間引いて」保持する。大域最適化・TSDF 再統合の入力になる。
//
//  リアルタイム性能の担保:
//   - 既定は無効（enabled=false）＝ consider() は即 return（コストゼロ）。
//   - 有効時も、動き（並進/回転）と時間間隔のゲートを満たしたときだけ保持する。
//   - 深度は TrueDepthSource が毎フレーム新規確保する所有テクスチャを「参照保持」するだけ
//     （GPU コピーやブリットをしない）。よってホットパスに重い処理を足さない。
//   - メモリ上限（maxKeyframes）で保持を停止する。
//

import Metal
import simd

final class KeyframeRecorder {

    let store = KeyframeStore()
    var config: GlobalOptConfig

    /// 大域最適化が有効なときだけ true。false ならキーフレームを一切保持しない。
    var enabled = false

    private var lastPose: simd_float4x4?
    private var lastTime: TimeInterval = 0
    private var nextId = 0

    init(config: GlobalOptConfig = GlobalOptConfig()) {
        self.config = config
    }

    /// スキャン開始時に呼ぶ。保持済みキーフレームと間引き状態を破棄する。
    func reset() {
        store.clear()
        lastPose = nil
        lastTime = 0
        nextId = 0
    }

    /// リアルタイムの didOutput から呼ぶ。ゲートを満たしたときだけキーフレームを保持する。
    /// - Parameters:
    ///   - depth: 所有深度テクスチャ（TrueDepthSource が毎フレーム確保する r32Float。参照保持する）。
    ///   - pose:  統合に使うワールド姿勢（VIO or ICP 補正後）。
    func consider(depth: MTLTexture, pose: simd_float4x4, intrinsics: CameraIntrinsics,
                  width: Int, height: Int, timestamp: TimeInterval) {
        guard enabled else { return }
        guard store.count < config.maxKeyframes else { return }

        if let last = lastPose {
            let moved = PoseMath.distance(last, pose) >= config.keyframeMinTranslation
                     || PoseMath.angle(last, pose) >= config.keyframeMinRotation
            let spaced = (timestamp - lastTime) >= config.keyframeMinInterval
            guard moved && spaced else { return }
        }

        lastPose = pose
        lastTime = timestamp
        let kf = Keyframe(id: nextId, pose: pose, intrinsics: intrinsics,
                          width: width, height: height, depth: depth, timestamp: timestamp)
        nextId += 1
        store.append(kf)
    }
}
