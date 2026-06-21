# ScanEngine 設計書（Phase 1）

商用品質（Polycam / STL Maker 相当）のリアルタイム3Dスキャンエンジン。
KinectFusion 型の **TSDF + Metal Compute + Marching Cubes** パイプラインを、
SOLID / MVVM を意識した保守しやすい構成で実装する。

---

## 0. 確定した設計判断（レビュー済み 2026-06-21）

### 0.1 入力センサーは「TrueDepth 前面カメラ」を主軸にする（決定）

TrueDepth（前面）を主軸とする。品質改善の本質は **TSDF 融合**にあり、入力が TrueDepth でも
KinectFusion 型の重み付き統合で「途切れ・ガタガタ・ノイズ」は大きく改善できる。

TrueDepth 固有の扱い：

- 入力は `ARFaceTrackingConfiguration(isWorldTrackingEnabled: true)` の
  `frame.capturedDepthData`（AVDepthData, TrueDepth 640×480 級）。iPhone 14 Pro は
  `ARFaceTrackingConfiguration.supportsWorldTracking == true` なのでワールド姿勢も取れる。
- **per-pixel の confidenceMap は ARKit から出ない**（これは LiDAR 専用 API）。
  → TrueDepth では **「有効性マスク」で代替**する：
    - 深度が有限値か（NaN/Inf 除外）
    - 距離レンジ内か（既定 0.2–0.9 m、調整可）
    - `AVDepthData.depthDataQuality`（フレーム全体の品質）でフレーム単位の足切り
    - 法線が視線に対して極端に斜め（grazing）な画素を除外（縁のノイズ対策）
- 姿勢は `frame.camera.transform`。`ARCamera.trackingState` を監視し limited/notAvailable 中は統合停止。

> 設計上は `DepthFrameSource` プロトコルで抽象化を維持。将来 `LiDARDepthSource`
> （sceneDepth/confidence）を追加すれば同じ TSDF パイプラインに差し替え可能（拡張点として残す）。

### 0.2 スキャン領域は「バウンディングボックス」で限定する（決定）

対象は **〜1m 級（義足〜上半身）** を主想定。既存の範囲ボックス UI を再利用し、
TSDF Volume をその箱に一致させる。このサイズなら**密ボリュームで安全**（メモリは §5、~128MB 級）。
全身（2m）対応は当面スコープ外（必要時に voxel hashing を別途検討）。

---

## 1. アーキテクチャ全体像

```
React Native (TypeScript) ── UIのみ
        │  start / stop / requestPreview / exportSTL  （軽量コマンドのみ）
        ▼
Swift Bridge (RCT)  ScanEngineModule / ScanEngineView
        │
        ▼
ScanEngine (facade, MVVM の Model)  ──── ScanEngineState を @Published で公開
        │
        ├── Capture:   DepthFrameSource → DepthFrame(depth, confidence, pose, intrinsics, image, t)
        ├── Filtering: DepthFilterChain（Confidence → Bilateral → Temporal）  [Metal]
        ├── Fusion:    TSDFVolume.integrate(frame)                            [Metal]
        ├── Meshing:   MeshExtractor.extract(volume) → Mesh                   [Metal/CPU]
        ├── PostProc:  MeshProcessor（Smoothing / HoleFill / Decimation / Normals）
        └── Export:    STLExporter.write(mesh, .binary/.ascii)               [CPU]
```

各段は**プロトコル**で定義し、実装を差し替え可能にする（Open/Closed・Dependency Inversion）。

---

## 2. フォルダ構成（Swift Package 化しやすい単位）

```
ios/MedicalScan/ScanEngine/
  DESIGN.md
  Core/
    ScanEngine.swift          // facade。パイプライン統括。状態を@Published公開（MVVMのModel）
    ScanEngineTypes.swift     // DepthFrame, ScanConfig, Mesh, ScanEngineState など値型
    MetalContext.swift        // MTLDevice/CommandQueue/Library 共有。確保したバッファ再利用
  Capture/
    DepthFrameSource.swift    // protocol（入力抽象）
    LiDARDepthSource.swift    // ARWorldTracking + smoothedSceneDepth（主軸）
    TrueDepthSource.swift     // ARFaceTracking capturedDepthData（補助）
  Filtering/
    DepthFilter.swift         // protocol。ConfidenceFilter/BilateralFilter/TemporalFilter
    Shaders/DepthFilters.metal
  Fusion/
    TSDFVolume.swift          // protocol + Metal実装。SDF/Weight/Color/Pose統合
    Shaders/TSDFIntegrate.metal
  Meshing/
    MeshExtractor.swift       // protocol。MarchingCubes実装
    MeshProcessor.swift       // Smoothing/HoleFill/Decimation/Normals
    Shaders/MarchingCubes.metal
  Export/
    STLExporter.swift         // Binary/ASCII STL
  Bridge/
    ScanEngineViewManager.m / .swift   // RNへ最小API公開（既存ブリッジを置換）
```

依存方向は常に **外側（Bridge/UI）→ ScanEngine（Core）→ 各段プロトコル**。
Core は UIKit/React に依存しない（テスト・パッケージ化容易）。

---

## 3. データフロー型（ScanEngineTypes）

```swift
struct DepthFrame {            // 1フレーム分の入力（GPUテクスチャ参照を保持）
  let depth: MTLTexture        // r32Float [m]
  let confidence: MTLTexture?  // LiDAR時のみ。TrueDepthはnil（validityで代替）
  let color: MTLTexture?       // capturedImage（YCbCr→RGB or 参照）
  let intrinsics: simd_float3x3
  let cameraToWorld: simd_float4x4
  let resolution: SIMD2<Int>
  let quality: Float           // AVDepthData.depthDataQuality 由来(0..1)
  let timestamp: TimeInterval
}

struct ScanConfig {            // 全パラメータを一元管理（Reactから一部調整可）
  var voxelSize: Float = 0.003          // 3 mm
  var volumeExtent: SIMD3<Float> = [0.6,1.2,0.6]
  var truncation: Float = 0.012         // = 4 * voxelSize（経験則）
  // TrueDepth 有効性マスク（confidenceMapの代替）
  var depthMin: Float = 0.20            // m。未満は除外
  var depthMax: Float = 0.90            // m。超は除外
  var qualityMin: Float = 0.5           // フレーム品質の足切り
  var grazingCosMin: Float = 0.2        // 視線と法線の|cos|下限（斜め縁除外）
  // フィルタ / 融合
  var bilateralSigmaSpace: Float = 3
  var bilateralSigmaDepth: Float = 0.02
  var temporalAlpha: Float = 0.2        // 深度マップ側EMA
  var maxWeight: Float = 64             // TSDF重み上限
}

struct Mesh {                  // 抽出メッシュ（GPUバッファ）
  var positions: MTLBuffer; var normals: MTLBuffer
  var indices: MTLBuffer; var vertexCount: Int; var indexCount: Int
}
```

---

## 4. アルゴリズム選定と理由

| 項目 | 採用 | 理由（要点） |
|---|---|---|
| Temporal | **TSDFの重み付き平均＋深度EMA(α=0.2)** | TSDF統合自体が指数移動平均＝最適な時間統合。Kalmanは voxel毎の状態保持でメモリ/計算過大。深度マップ側に軽いEMAを足すだけで十分 |
| Depth Denoise | **Bilateral（Metal）** | エッジ保持しつつ平滑化。Gaussianは輪郭がボケる。Joint bilateral も将来拡張可 |
| Fusion | **TSDF（KinectFusion）** | 複数視点を符号付き距離場へ統合し、ノイズ平均化・穴埋め・滑らかさを同時達成。点群直接より圧倒的に綺麗 |
| Mesh抽出 | **Marching Cubes** | 有機形状（人体）に最適で実装/GPU並列が素直。Dual Contouringは鋭角再現に強いがHermiteデータ+QEFが必要で実時間には重い |
| 法線 | **TSDF勾配（trilinear）** | SDFの勾配＝表面法線。MC頂点で直接得られ高品質・低コスト。面法線/頂点法線も別途提供 |
| Smoothing | **Taubin(λ/μ)** | Laplacianの収縮を打ち消す。HCより軽量で実時間向き |
| Decimation | **QEM（Garland-Heckbert）** | 誤差最小の頂点削減。実時間プレビューでは無効、**STL書き出し時のみ**任意適用。LODは Phase 8 で検討 |
| Hole Filling | **TSDF重み拡散＋Morphology closing** | TSDFが本質的に穴を埋める。残る欠損は近傍SDF外挿で補完。Nearest単体は段差が出る |

---

## 5. 計算量・メモリ（iPhone 14 Pro 想定）

記号：深度解像度 `N`（LiDAR sceneDepth ≒ 256×192 ≈ 49,152 画素）、ボクセル数 `V`。

| 段 | 計算量 | 備考 |
|---|---|---|
| Confidence/Bilateral | O(N·r²) | r=半径3で N·49。GPUで <1ms |
| TSDF Integrate | O(V_frustum) | 視錐台内ボクセルのみ更新。GPUで数ms |
| Marching Cubes | O(V) | 変更ブリックのみ再抽出で削減可 |
| Taubin | O(E·iter) | E=辺数。2〜4反復 |
| QEM | O(E log E) | 書き出し時のみ |

**メモリ（密ボリューム）**：1ボクセル = SDF(2B half) + Weight(2B half) + Color(任意) ≈ 4–8B。

| 範囲 | voxel | V | メモリ(8B) |
|---|---|---|---|
| 義足 0.4³ m | 2 mm | 200³=8M | 64 MB |
| 上半身 0.6×1.2×0.6 | 3 mm | 200×400×200=16M | 128 MB |
| 全身 0.7×2×0.7 | 3 mm | 233×667×233≈36M | 290 MB（要hashing） |

→ ~1m級は密ボリュームで安全。全身は **voxel hashing**（占有ブロックのみ確保）を Phase 4 で導入。

---

## 6. ボトルネックと対策

1. **毎フレームのMesh抽出** → 変更のあったボクセルブロックのみ再抽出＋プレビューは間引き（10–15fps）
2. **密ボリュームのメモリ** → half精度・範囲限定・必要なら hashing
3. **CPU↔GPUコピー** → DepthFrameはMTLTexture参照のまま。Mesh も MTLBuffer のまま SceneKit/Metal 描画。RNへは数値（頂点数等）のみ返す
4. **Tracking Lost** → `ARCamera.trackingState` 監視。limited/notAvailable中は統合を停止し、復帰後に再開（誤統合を防ぐ）

---

## 7. React Native 公開 API（最小）

```ts
ScanEngine.start(config?)      // スキャン開始
ScanEngine.stop()             // 停止
ScanEngine.reset()            // ボリューム破棄
ScanEngine.exportSTL(opts)    // {format:'binary'|'ascii'} → ファイルパス返却
// プレビューは Native View（ScanEngineView）が直接Metal描画。重いデータはRNに渡さない
```

---

## 8. フェーズ計画（このプロジェクトの進め方）

- **Phase 1（本書）**：構成・フォルダ・依存・設計レビュー ← 今ここ。要承認
- **Phase 2**：Depth取得（LiDAR/TrueDepth source）＋ Metal導入＋リアルタイム深度プレビュー
- **Phase 3**：Confidence / Bilateral / Temporal フィルタ（Metal）
- **Phase 4**：TSDF統合・Pose統合・Voxel管理
- **Phase 5**：Marching Cubes・Mesh生成・Normal生成
- **Phase 6**：Smoothing・Hole Filling・Decimation
- **Phase 7**：STL Export・RN Bridge
- **Phase 8**：GPU/メモリ最適化・LOD

各フェーズ完了時に：実装内容／選定理由／計算量／メモリ／ボトルネック／改善案／次フェーズ を提示。

---

## 9. 既存コードの扱い

- 既存 `LiDARScannerView.swift`（ARMeshAnchor方式＋TrueDepthボクセル方式）は **当面そのまま温存**し、
  新エンジンを `ScanEngine/` に並行構築。動作確認後にスキャン画面を切替える（後方互換・段階移行）。
- 範囲ボックス UI / STLビューア / 共有機能は再利用。

## 10. Phase 2 で着手する内容（承認後）

1. `MetalContext`（device/queue/library 共有）
2. `DepthFrameSource` プロトコル ＋ `TrueDepthSource`
   （`ARFaceTrackingConfiguration(isWorldTrackingEnabled:true)` + `capturedDepthData` + `camera.transform` + `depthDataQuality`）
3. AVDepthData(Float32)→ depth MTLTexture 化、capturedImage(YCbCr)→RGB MTLTexture 化、intrinsics を深度解像度へスケール
4. `ScanEngineView`（Metal で深度を有効性マスク付きカラーマップ表示するリアルタイムプレビュー）
5. RN へ `start/stop` の最小ブリッジ、`ARCamera.trackingState` の状態通知

> Phase 2 の成果物：**TrueDepthの深度マップ＋有効性マスクがリアルタイムにGPU描画される**ところまで（TSDF前の土台）。
> 拡張点として `LiDARDepthSource` は同プロトコルで後から追加可能。
