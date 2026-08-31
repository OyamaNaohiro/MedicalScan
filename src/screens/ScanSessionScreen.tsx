import React, {useState, useEffect, useCallback} from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  Alert,
  useWindowDimensions,
} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {useFocusEffect} from '@react-navigation/native';
import {ScanEnginePreview, DepthDisplayMode, ScanMode} from '../native/ScanEnginePreview';
import {addScanEventListener} from '../native/ScanEventEmitter';

// 対象サイズ別モード（ネイティブ ScanMode と一致）。
const SCAN_MODES: {
  value: ScanMode;
  icon: string;
  title: string;
  desc: string;
  range: string;
}[] = [
  {
    value: ScanMode.Hand,
    icon: '✋',
    title: '手・小物',
    desc: '最も細かい解像度（1.5mm）\n15〜45cmで撮影',
    range: '15〜45cm',
  },
  {
    value: ScanMode.Foot,
    icon: '🦶',
    title: '足・部位',
    desc: '中解像度（2.0mm）\n20〜60cmで撮影',
    range: '20〜60cm',
  },
  {
    value: ScanMode.UpperBody,
    icon: '🧍',
    title: '上半身',
    desc: '広範囲（3.0mm）\n20〜90cmで撮影',
    range: '20〜90cm',
  },
];

// 距離ガイドの状態。
type DistState = 'none' | 'near' | 'ok' | 'far';

const DIST_STYLE: {[k in DistState]: {color: string; label: string}} = {
  none: {color: '#8e8e93', label: '対象なし'},
  near: {color: '#ff453a', label: '近すぎ → 離す'},
  ok: {color: '#30d158', label: '適正'},
  far: {color: '#ff9f0a', label: '遠すぎ → 近づく'},
};

export default function ScanSessionScreen() {
  const [scanMode, setScanMode] = useState<ScanMode>(ScanMode.Hand);
  const [inSession, setInSession] = useState(false); // false:モード選択 true:スキャン画面
  const [isScanning, setIsScanning] = useState(false); // 実際の統合(engine.start/stop)
  const [view3D, setView3D] = useState(false); // false:深度 true:メッシュ(3D表示)
  const [mirror, setMirror] = useState(false); // 45°ミラー撮影モード
  const [exportFormat, setExportFormat] = useState(0); // 0:STLバイナリ 2:PLY(色付き)
  const [exportReq, setExportReq] = useState(0);

  // ミラーが画面上部の約2割を隠すため、表示・UIを下側8割へ寄せる（高さの20%だけ上を空ける）。
  const {height: winHeight} = useWindowDimensions();
  const stageStyle = mirror
    ? {position: 'absolute' as const, top: winHeight * 0.2, left: 0, right: 0, bottom: 0}
    : StyleSheet.absoluteFillObject;

  // 距離ガイド・進捗の計測値。
  const [centerDepth, setCenterDepth] = useState(0);
  const [rangeMin, setRangeMin] = useState(0.15);
  const [rangeMax, setRangeMax] = useState(0.45);
  const [tracking, setTracking] = useState('-');
  const [triangles, setTriangles] = useState(0);
  // 再ローカライズ状態: ok(通常) / lost(見失い中) / relocalized(再接続成功) / restart(リセット)
  const [relocStatus, setRelocStatus] = useState<
    'ok' | 'lost' | 'relocalized' | 'restart'
  >('ok');

  // タブを離れたら停止。
  useFocusEffect(
    useCallback(() => {
      return () => {
        setIsScanning(false);
        setInSession(false);
        setCenterDepth(0);
        setTriangles(0);
      };
    }, []),
  );

  useEffect(() => {
    const sub = addScanEventListener(event => {
      if (event.type === 'metrics') {
        setCenterDepth(event.centerDepthM ?? 0);
        setRangeMin(event.depthRangeMin ?? 0.15);
        setRangeMax(event.depthRangeMax ?? 0.45);
        setTracking(event.tracking ?? '-');
        setTriangles(event.meshTriangles ?? 0);
      } else if (event.type === 'exported') {
        Alert.alert('保存しました', event.path);
      } else if (event.type === 'engineError') {
        Alert.alert('エラー', event.message);
      } else if (event.type === 'engineLog') {
        // 再ローカライズの状態をバナー表示へ反映。
        if (event.kind === 'trackingLost') setRelocStatus('lost');
        else if (event.kind === 'relocalized') setRelocStatus('relocalized');
        else if (event.kind === 'scanRestart') setRelocStatus('restart');
      }
    });
    return () => sub.remove();
  }, []);

  // relocalized / restart は一時表示（2秒で ok に戻す）。lost はエンジンが解消するまで保持。
  useEffect(() => {
    if (relocStatus === 'relocalized' || relocStatus === 'restart') {
      const t = setTimeout(() => setRelocStatus('ok'), 2000);
      return () => clearTimeout(t);
    }
  }, [relocStatus]);

  // 距離状態の判定。
  let distState: DistState = 'none';
  if (centerDepth > 0) {
    if (centerDepth < rangeMin) distState = 'near';
    else if (centerDepth > rangeMax) distState = 'far';
    else distState = 'ok';
  }
  const dist = DIST_STYLE[distState];
  const cm = centerDepth > 0 ? `${Math.round(centerDepth * 100)}` : '--';
  const trackingOk = tracking === 'normal' || tracking === '-';

  // 保存要求。フォーマット prop を先に反映させてから次tickで要求を出す
  // （ネイティブが正しい形式で読むよう順序を保証する）。
  const requestExport = useCallback((format: number) => {
    setExportFormat(format);
    setTimeout(() => setExportReq(Date.now()), 0);
  }, []);

  const onSavePress = useCallback(() => {
    if (triangles <= 0) {
      Alert.alert('まだ保存できません', 'メッシュが生成されていません。対象を数秒スキャンしてください。');
      return;
    }
    Alert.alert('保存形式を選択', 'エクスポートする形式を選んでください。', [
      {text: 'STL（形状のみ）', onPress: () => requestExport(0)},
      {text: 'PLY（色付き）', onPress: () => requestExport(2)},
      {text: 'キャンセル', style: 'cancel'},
    ]);
  }, [triangles, requestExport]);

  return (
    <SafeAreaView style={styles.container} edges={['top', 'bottom']}>
     {/* ミラー時は表示・UIを下側8割へ寄せる（上2割はミラーで隠れるため）。 */}
     <View style={stageStyle}>
      {/* 常時マウント（エンジン・ボリュームを安定させる）。開始前は上に選択UIを重ねる。 */}
      {/* 推奨設定を固定適用: World OFF / GlobalOpt OFF / DepthOdom ON / Color ON。 */}
      <ScanEnginePreview
        style={styles.preview}
        isScanning={isScanning}
        displayMode={DepthDisplayMode.Filtered}
        scanMode={scanMode}
        meshView={view3D}
        cameraFollow={view3D}
        worldTracking={false}
        globalOptimize={false}
        depthOdometry={true}
        colorBaking={true}
        mirrorMode={mirror}
        exportFormat={exportFormat}
        exportRequest={exportReq}
      />

      {/* ─── 開始前: モード選択 ─────────────────────────── */}
      {!inSession && (
        <View style={styles.selectOverlay}>
          <Text style={styles.selectTitle}>3Dスキャン</Text>
          <Text style={styles.selectSubtitle}>対象のサイズを選んでください</Text>

          <View style={styles.modeCards}>
            {SCAN_MODES.map(m => {
              const active = scanMode === m.value;
              return (
                <TouchableOpacity
                  key={m.value}
                  style={[styles.modeCard, active && styles.modeCardActive]}
                  onPress={() => setScanMode(m.value)}>
                  <Text style={styles.modeIcon}>{m.icon}</Text>
                  <View style={styles.modeCardBody}>
                    <Text style={[styles.modeTitle, active && styles.modeTitleActive]}>
                      {m.title}
                    </Text>
                    <Text style={styles.modeDesc}>{m.desc}</Text>
                  </View>
                  {active && (
                    <View style={styles.modeCheck}>
                      <Text style={styles.modeCheckText}>✓</Text>
                    </View>
                  )}
                </TouchableOpacity>
              );
            })}
          </View>

          {/* ミラー撮影モード（45°ミラーで前面センサーを上方へ折り返す）。向き補正＋UIを下寄せ。 */}
          <TouchableOpacity
            style={[styles.mirrorToggle, mirror && styles.mirrorToggleActive]}
            onPress={() => setMirror(p => !p)}>
            <Text style={[styles.mirrorToggleText, mirror && styles.mirrorToggleTextActive]}>
              {mirror ? '🪞 ミラー撮影: ON' : '🪞 ミラー撮影: OFF'}
            </Text>
          </TouchableOpacity>

          {/* 画面を切り替えるだけ。スキャン(統合)はスキャン画面の開始ボタンで行う。 */}
          <TouchableOpacity
            style={styles.startButton}
            onPress={() => {
              setView3D(false);
              setInSession(true);
            }}>
            <Text style={styles.startButtonText}>スキャン画面へ</Text>
          </TouchableOpacity>
        </View>
      )}

      {/* ─── スキャン画面: 距離ガイド + 操作 ───────────────── */}
      {inSession && (
        <>
          {/* 再ローカライズ状態バナー（スキャン中・状態が ok 以外のとき優先表示） */}
          {isScanning && relocStatus !== 'ok' && (
            <View
              style={[
                styles.relocBanner,
                relocStatus === 'lost' && {backgroundColor: 'rgba(255,159,10,0.95)'},
                relocStatus === 'relocalized' && {backgroundColor: 'rgba(48,209,88,0.95)'},
                relocStatus === 'restart' && {backgroundColor: 'rgba(255,69,58,0.95)'},
              ]}>
              <Text style={styles.relocBannerText}>
                {relocStatus === 'lost'
                  ? '⚠ 追従を見失いました — 元の位置・向きに戻してください'
                  : relocStatus === 'relocalized'
                  ? '✓ 再接続しました'
                  : 'スキャンをリセットしました（最初から）'}
              </Text>
            </View>
          )}

          {/* トラッキング警告（スキャン中・再ローカライズ表示が無いときのみ） */}
          {isScanning && relocStatus === 'ok' && !trackingOk && (
            <View style={styles.trackWarn}>
              <Text style={styles.trackWarnText}>
                トラッキング不安定（{tracking}）: ゆっくり動かし、対象を画面内に保ってください
              </Text>
            </View>
          )}

          {/* 中央の距離リング（スキャン中のみ・色で適正距離を示す） */}
          {isScanning && (
            <View style={styles.ringWrap} pointerEvents="none">
              <View style={[styles.ring, {borderColor: dist.color}]}>
                <Text style={[styles.ringCm, {color: dist.color}]}>{cm}</Text>
                <Text style={styles.ringUnit}>cm</Text>
              </View>
              <View style={[styles.distBadge, {backgroundColor: dist.color}]}>
                <Text style={styles.distBadgeText}>{dist.label}</Text>
              </View>
              <Text style={styles.rangeHint}>
                適正 {Math.round(rangeMin * 100)}〜{Math.round(rangeMax * 100)}cm
              </Text>
            </View>
          )}

          {/* 上部: 戻る + ステータス */}
          <View style={styles.topBar}>
            <TouchableOpacity
              style={styles.backButton}
              onPress={() => {
                setIsScanning(false);
                setInSession(false);
              }}>
              <Text style={styles.backButtonText}>‹ 戻る</Text>
            </TouchableOpacity>
            {isScanning ? (
              <View style={styles.recBadge}>
                <View style={styles.recDot} />
                <Text style={styles.recText}>スキャン中</Text>
              </View>
            ) : (
              <View style={styles.recBadge}>
                <Text style={styles.recText}>準備完了 — 開始を押す</Text>
              </View>
            )}
            <View style={styles.triBadge}>
              <Text style={styles.triText}>{triangles.toLocaleString()} 面</Text>
            </View>
          </View>

          {/* 下部コントロール */}
          <View style={styles.controls}>
            <TouchableOpacity
              style={[styles.sideButton, view3D && styles.sideButtonActive]}
              onPress={() => setView3D(p => !p)}>
              <Text style={styles.sideButtonText}>{view3D ? 'メッシュ' : '深度'}</Text>
              <Text style={styles.sideButtonSub}>表示</Text>
            </TouchableOpacity>

            {/* 開始/停止トグル（Engineタブと同じ。画面は切り替えない） */}
            <TouchableOpacity
              style={[styles.scanToggle, isScanning && styles.scanToggleStop]}
              onPress={() => {
                setRelocStatus('ok');
                setIsScanning(p => !p);
              }}>
              <Text style={styles.scanToggleText}>{isScanning ? '停止' : '開始'}</Text>
            </TouchableOpacity>

            <TouchableOpacity style={styles.saveButton} onPress={onSavePress}>
              <Text style={styles.saveButtonText}>保存</Text>
              <Text style={styles.sideButtonSub}>STL/PLY</Text>
            </TouchableOpacity>
          </View>
        </>
      )}
     </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: '#000'},
  preview: {...StyleSheet.absoluteFillObject},

  // 選択オーバーレイ
  selectOverlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: '#101018',
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 24,
  },
  selectTitle: {fontSize: 28, fontWeight: '800', color: '#fff', marginBottom: 6},
  selectSubtitle: {fontSize: 14, color: '#8e8e93', marginBottom: 28},
  modeCards: {width: '100%', gap: 12, marginBottom: 32},
  modeCard: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#1c1c28',
    borderRadius: 16,
    padding: 16,
    borderWidth: 2,
    borderColor: '#2c2c3a',
  },
  modeCardActive: {borderColor: '#5e5ce6', backgroundColor: 'rgba(94,92,230,0.14)'},
  modeIcon: {fontSize: 34, marginRight: 14},
  modeCardBody: {flex: 1},
  modeTitle: {fontSize: 18, fontWeight: '700', color: '#ddd', marginBottom: 3},
  modeTitleActive: {color: '#fff'},
  modeDesc: {fontSize: 12, color: '#888', lineHeight: 17},
  modeCheck: {
    width: 28,
    height: 28,
    borderRadius: 14,
    backgroundColor: '#5e5ce6',
    alignItems: 'center',
    justifyContent: 'center',
  },
  modeCheckText: {color: '#fff', fontSize: 15, fontWeight: '800'},
  mirrorToggle: {
    paddingHorizontal: 20,
    paddingVertical: 12,
    borderRadius: 22,
    borderWidth: 2,
    borderColor: '#2c2c3a',
    backgroundColor: '#1c1c28',
    marginBottom: 20,
  },
  mirrorToggleActive: {borderColor: '#5e5ce6', backgroundColor: 'rgba(94,92,230,0.14)'},
  mirrorToggleText: {color: '#888', fontSize: 15, fontWeight: '700'},
  mirrorToggleTextActive: {color: '#fff'},
  startButton: {
    backgroundColor: '#5e5ce6',
    paddingHorizontal: 48,
    paddingVertical: 16,
    borderRadius: 28,
  },
  startButtonText: {color: '#fff', fontSize: 17, fontWeight: '800'},

  // トラッキング警告
  trackWarn: {
    position: 'absolute',
    top: 70,
    left: 16,
    right: 16,
    backgroundColor: 'rgba(255,159,10,0.92)',
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 12,
  },
  trackWarnText: {color: '#000', fontSize: 12, fontWeight: '600', textAlign: 'center'},

  // 再ローカライズ状態バナー
  relocBanner: {
    position: 'absolute',
    top: 70,
    left: 16,
    right: 16,
    paddingHorizontal: 14,
    paddingVertical: 10,
    borderRadius: 12,
  },
  relocBannerText: {color: '#000', fontSize: 13, fontWeight: '700', textAlign: 'center'},

  // 距離リング
  ringWrap: {
    ...StyleSheet.absoluteFillObject,
    alignItems: 'center',
    justifyContent: 'center',
  },
  ring: {
    width: 150,
    height: 150,
    borderRadius: 75,
    borderWidth: 6,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.15)',
  },
  ringCm: {fontSize: 46, fontWeight: '800', fontVariant: ['tabular-nums']},
  ringUnit: {color: '#ccc', fontSize: 14, fontWeight: '600', marginTop: -6},
  distBadge: {
    marginTop: 16,
    paddingHorizontal: 18,
    paddingVertical: 8,
    borderRadius: 18,
  },
  distBadgeText: {color: '#000', fontSize: 15, fontWeight: '800'},
  rangeHint: {color: '#aaa', fontSize: 12, marginTop: 10, fontWeight: '600'},

  // 上部
  topBar: {
    position: 'absolute',
    top: 12,
    left: 16,
    right: 16,
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  recBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.6)',
    paddingHorizontal: 14,
    paddingVertical: 7,
    borderRadius: 18,
    gap: 8,
  },
  recDot: {width: 10, height: 10, borderRadius: 5, backgroundColor: '#ff3b30'},
  recText: {color: '#fff', fontSize: 13, fontWeight: '700'},
  triBadge: {
    backgroundColor: 'rgba(0,0,0,0.6)',
    paddingHorizontal: 14,
    paddingVertical: 7,
    borderRadius: 18,
  },
  triText: {color: '#fff', fontSize: 13, fontWeight: '600', fontVariant: ['tabular-nums']},

  // 下部コントロール
  controls: {
    position: 'absolute',
    bottom: 24,
    left: 0,
    right: 0,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-around',
    paddingHorizontal: 20,
  },
  sideButton: {
    width: 66,
    height: 66,
    borderRadius: 33,
    backgroundColor: 'rgba(60,60,70,0.9)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  sideButtonActive: {backgroundColor: '#5e5ce6'},
  sideButtonText: {color: '#fff', fontSize: 16, fontWeight: '800'},
  sideButtonSub: {color: '#ddd', fontSize: 10, fontWeight: '600'},
  scanToggle: {
    width: 84,
    height: 84,
    borderRadius: 42,
    backgroundColor: '#0a84ff',
    alignItems: 'center',
    justifyContent: 'center',
  },
  scanToggleStop: {backgroundColor: '#ff3b30'},
  scanToggleText: {color: '#fff', fontSize: 18, fontWeight: '800'},
  backButton: {
    backgroundColor: 'rgba(0,0,0,0.6)',
    paddingHorizontal: 14,
    paddingVertical: 7,
    borderRadius: 18,
  },
  backButtonText: {color: '#fff', fontSize: 14, fontWeight: '700'},
  saveButton: {
    width: 66,
    height: 66,
    borderRadius: 33,
    backgroundColor: '#34c759',
    alignItems: 'center',
    justifyContent: 'center',
  },
  saveButtonText: {color: '#fff', fontSize: 16, fontWeight: '800'},
});
