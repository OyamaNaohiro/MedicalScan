# ScanEngine チューニング記録（ビルド93時点）

スキャン品質に関わる全処理と数値の記録。後の微調整の参照用。
値の場所（ファイル）と、増やす/減らすとどうなるか（チューニング方向）を併記する。

## 現在のベスト設定（トグル）

| トグル | 状態 | 備考 |
|---|---|---|
| **DepthOdom（深度オドメトリ主軸）** | **ON** | ICP をフレーム→モデルの主トラッカーに。二重壁/ドリフト解消の主因 |
| **World（ワールドトラッキング）** | **OFF** | 背面カメラVIO非依存。ARKitは相対運動priorにのみ使用 |
| **GlobalOpt（大域最適化）** | **OFF** | エクスポート時のPGO。現状は実効性なし（後述）ためOFF |
| Conf / Bila / Temp（深度フィルタ） | ON | ノイズ低減 |
| Smooth（SDF平滑化） | ON | 表面のさざ波低減 |
| Sparse（ブロックスパース統合） | ON | 高速化。品質はほぼ同等 |
| Gate（整合ゲート） | ON | **※DepthOdom ON時は不使用**（VIO主軸パス専用） |
| ICP | ON | **※DepthOdom ON時は不使用**（VIO主軸パス専用。odom側は常時ICP） |

> 重要: **DepthOdom ON のとき、Gate/ICP トグルは効きません**。姿勢決定は `trackDepthOdometry`（常時ICP）に一本化され、`connectGate`/`icpEnabled` を参照する分岐（`currentTracking == .normal` 側）には入らないため。

---

## リアルタイム・パイプライン（60fps側）

`TrueDepthSource → DepthFilterChain → (DepthOdometry/VIO) → TSDF統合 → SDF平滑化 → Marching Cubes`

### 1. 入力（TrueDepthSource.swift）
- センサー: 前面TrueDepth（`ARFaceTrackingConfiguration`）
- `isWorldTrackingEnabled`: Worldトグル（既定ON、現在OFFで運用）
- 深度は毎フレーム新規確保の r32Float 所有テクスチャへコピー（ARFrame寿命から切り離し）
- カラー取得（AR重ね用）: DepthOdom/AR時のみ。YCbCr→BGRA変換

### 2. 深度フィルタ（ScanConfig / *Filter.swift）
| 段 | パラメータ | 値 | 場所 | 方向 |
|---|---|---|---|---|
| Confidence | depthMin/Max | モード別 | ScanConfig | レンジ外を無効化。狭いほどノイズ減・欠け増 |
| | qualityMin | 0.5 | ScanConfig | フレーム品質足切り。上げると厳しく |
| | grazingCosMin | **0.1** | ScanConfig | 斜め縁の許容。低いほど側面つながる/ノイズ増 |
| Bilateral | radius | 2（固定） | BilateralFilter.swift | カーネル半径 |
| | sigmaSpace | 3 | ScanConfig | 空間平滑の広さ |
| | sigmaDepth | 0.02 (20mm) | ScanConfig | 深度差の許容。大きいほど平滑・エッジ甘い |
| Temporal | strategy | EMA | TemporalFilter.swift | |
| | baseAlpha | 0.2 | ScanConfig | 時間平滑。小さいほど過去重視（滑らか/残像） |
| | diffThresh | 0.03 (30mm) | TemporalFilter.swift | この差以上は混ぜない（ゴースト防止） |
| | translationMax/rotationMax | 0.02 / 0.05 | TemporalFilter.swift | 動きが大きいフレームはα→1 |

### 3. 姿勢（深度オドメトリ主軸 / ScanEngine.swift）
- prior = 前トラッキング姿勢 × ARKit相対運動（`odomArkitPrev⁻¹ · arkit`）
- ICP（frame-to-model）で補正 → 累積姿勢に積む（ARKit長期ドリフトから独立）
- ICP結果: `.ok`=ICP姿勢採用 / `.aborted`=予測姿勢で統合（初期育成）/ `.poor`=統合スキップ（モデル保護）
- ICPパラメータ（ScanConfig / ICPRefiner.swift）
  | パラメータ | 値 | 方向 |
  |---|---|---|
  | icpIterations | 5 | 反復数。多いほど収束/重い |
  | icpStride | 6 | 深度間引き。小さいほど密/重い |
  | icpMinWeight | 2 | モデルとして信頼する最小重み |
  | **icpPriorWeight** | **0（無効）** | ARKit事前分布。ビルド105で導入→引き戻し先のARKitがドリフトし全モード劣化→ビルド107で撤回。将来は定速度モデルへ引き戻すべき |
  | minCorrespondences | 200（ICPRefiner） | これ未満で中断 |
  | maxRotation / maxTranslation | 0.15rad / 0.05m per iter（ICPRefiner） | 発散検出 |
  | .ok/.poor閾値 | rms ≤ truncation（ICPRefiner） | ICP対応バンド＝truncation |

### 4. TSDF統合（ScanConfig / TSDFVolume.swift / (Sparse)TSDFIntegrator.swift）
| パラメータ | 値 | 場所 | 方向 |
|---|---|---|---|
| voxelSize | 手1.5 / 足2.0 / 上半身3.0 mm | ScanMode.makeConfig | 小さいほど細部/重い・ノイズ床(~1mm)以下は頭打ち |
| volumeExtent | 手0.3³ / 足0.5³ / 上半身0.6×1.2×0.6 m | ScanMode.makeConfig | 対象を覆う箱 |
| **truncationScale** | **4** | ScanConfig | truncation=voxel×4。大きいほど融合（つながり）/太る・二重壁減 |
| maxWeight | 64 | ScanConfig | 重み上限。大きいほど平均化（安定/適応遅い） |
| voxelStride | 8B（dist+weight） | TSDFVolume | |
| maxVoxels | 24,000,000 | TSDFVolume | メモリ上限 |
| blockEdge | 8 | TSDFVolume | スパースのブロック辺 |
| markStride / ring | 1 / 3×3×3 | SparseTSDFIntegrator | シェル被覆（穴あき防止） |

### 5. SDF平滑化（ScanConfig / TSDFSmoother.swift）— MC前・ボリューム空間
| パラメータ | 値 | 方向 |
|---|---|---|
| sdfSmoothIterations | **2** | 反復。多いほど滑らか/丸まる |
| sdfSmoothRadius | 1（3³） | 近傍半径 |
| sdfSmoothAmount | **0.8** | 近傍平均へのブレンド。大きいほど平滑 |
| sdfNoiseMinNeighbors | 5 | これ未満は孤立ノイズ除去 |
| sdfHoleFillMinNeighbors | 16 | これ以上で未観測穴を補完 |

### 6. メッシュ抽出（ScanConfig / MeshExtractor.swift）— GPU Marching Cubes
| パラメータ | 値 | 方向 |
|---|---|---|
| meshMinWeight | 3 | この重み未満は表面化しない。低いほど育つ/ノイズ増 |
| iso | 0 | 等値面 |
| maxTriangles | 500,000 | 出力上限 |
| meshExtractInterval | 5（ライブ）/ 15 | 抽出頻度（フレーム数） |
| winding | v0,v2,v1（反転） | 外向き法線用 |

---

## エクスポート・パイプライン（保存時のみ・リアルタイムと分離）

`頂点スープ → VertexWeld → HoleFilling → TaubinSmoothing → QEMDecimation → STL`

| 段 | パラメータ | 値 | 場所 | 実装 |
|---|---|---|---|---|
| VertexWeld | quantum | 1e-5 (10µm) | VertexWeld.swift | ✅ |
| HoleFilling | maxHoleEdges | 30 | HoleFilling.swift | ✅ 小穴のみ重心ファン充填 |
| TaubinSmoothing | iterations / λ / μ | 5 / 0.5 / -0.53 | TaubinSmoothing.swift | ✅ |
| QEMDecimation | targetRatio | 1.0（=無効） | QEMDecimation.swift | ✅ UIで1/2,1/4,1/10選択可 |
| STLExporter | 形式 | binary/ascii | STLExporter.swift | ✅ |

### 大域最適化（GlobalOpt・エクスポート専用 / GlobalOpt/*.swift）
| パラメータ | 値 | 場所 |
|---|---|---|
| keyframeMinTranslation / Rotation / Interval | 0.03m / 0.1rad / 0.2s | GlobalOptConfig |
| maxKeyframes | 400 | GlobalOptConfig |
| minFrameGap | 20 | GlobalOptConfig |
| maxPoseDistance / maxPoseAngle | 0.15m / 0.6rad | GlobalOptConfig |
| minFeatureMatch | 0.4 | GlobalOptConfig |
| pgoIterations / pgoConverge | 10 / 1e-5 | GlobalOptConfig |

---

## エクスポート処理の実装状況（「すべて実装済みか？」への回答）

| 処理 | 状態 |
|---|---|
| VertexWeld（溶接・インデックス化） | ✅ 実装済み |
| HoleFilling（小穴充填） | ✅ 実装済み |
| TaubinSmoothing（λ/μ平滑化） | ✅ 実装済み |
| QEMDecimation（削減） | ✅ 実装済み（既定OFF・UIで選択） |
| STL出力（binary/ascii） | ✅ 実装済み |
| **大域最適化: 構造・キーフレーム保持・再統合・再メッシュ** | ✅ 実装済み |
| **大域最適化: ループ候補の姿勢ゲート** | ✅ 実装済み |
| **大域最適化: PGOソルバ（SE(3)反復緩和＋安全ガード）** | ✅ 実装済み |
| 大域最適化: **ループ拘束の幾何推定（フレーム間ICP＝estimateRelative）** | ✅ 実装済み（LoopClosureICP: KF i の mini-TSDF に KF j を frame-to-model ICP で合わせて相対姿勢を推定→PGO で分配→再統合。ビルド118） |
| ⚠️ 大域最適化: **特徴一致率（featureMatch）** | ❌ 未実装（フックのみ） |
| LOD生成（多段解像度） | ❌ 未実装 |
| カラー/テクスチャ焼き込み（頂点色・STL/OBJ） | ❌ 未実装（カラーはAR重ね表示のみ） |

**結論**: エクスポートの後処理（Weld/HoleFilling/Taubin/QEM/STL）は**すべて実装済み**。
大域最適化は**枠組み・PGO本体まで実装済みだが、ループ拘束の幾何推定（フレーム間ICP）と特徴一致が未実装**のため、**現状PGOは実補正しない（＝GlobalOpt ONにしても姿勢は動かない）**。これを効かせるには estimateRelative にフレーム間ICPを実装する必要がある。LODとテクスチャは未着手。
