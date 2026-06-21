import React, {useState, useCallback, useEffect} from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  Alert,
  ActivityIndicator,
} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {useFocusEffect} from '@react-navigation/native';
import {LiDARScannerView, ScannerMode} from '../native/LiDARScannerView';
import {addScanEventListener} from '../native/ScanEventEmitter';

type ScanPhase = 'select' | 'active';
type ScanState = 'idle' | 'scanning' | 'exporting';

const DIM_MIN = 0.1;
const DIM_MAX = 3.0;
const DIM_STEP = 0.05;
const clampDim = (v: number) =>
  Math.round(Math.min(DIM_MAX, Math.max(DIM_MIN, v)) * 100) / 100;

interface BoxDimRowProps {
  label: string;
  value: number;
  onChange: (v: number) => void;
  disabled?: boolean;
}

function BoxDimRow({label, value, onChange, disabled}: BoxDimRowProps) {
  return (
    <View style={styles.dimRow}>
      <Text style={styles.dimLabel}>{label}</Text>
      <TouchableOpacity
        style={[styles.dimButton, disabled && styles.disabledButton]}
        onPress={() => onChange(value - DIM_STEP)}
        disabled={disabled}>
        <Text style={styles.dimButtonText}>−</Text>
      </TouchableOpacity>
      <Text style={styles.dimValue}>{`${Math.round(value * 100)} cm`}</Text>
      <TouchableOpacity
        style={[styles.dimButton, disabled && styles.disabledButton]}
        onPress={() => onChange(value + DIM_STEP)}
        disabled={disabled}>
        <Text style={styles.dimButtonText}>＋</Text>
      </TouchableOpacity>
    </View>
  );
}

export default function ScanScreen() {
  const [phase, setPhase] = useState<ScanPhase>('select');
  const [scanState, setScanState] = useState<ScanState>('idle');
  const [showMesh, setShowMesh] = useState(true);
  const [boxEnabled, setBoxEnabled] = useState(false);
  const [boxW, setBoxW] = useState(0.6);
  const [boxH, setBoxH] = useState(1.2);
  const [boxD, setBoxD] = useState(0.6);
  const [scannerMode, setScannerMode] = useState<ScannerMode>('lidar');
  const [exportFilename, setExportFilename] = useState('');
  const [shareFilePath, setShareFilePath] = useState('');

  // Reset to selection screen on tab blur
  useFocusEffect(
    useCallback(() => {
      return () => {
        setScanState('idle');
        setPhase('select');
        setExportFilename('');
      };
    }, []),
  );

  useEffect(() => {
    const subscription = addScanEventListener(event => {
      if (event.type === 'exported') {
        setScanState('idle');
        setShareFilePath(event.path ?? '');
        setExportFilename('');
      } else if (event.type === 'error') {
        setScanState('idle');
        Alert.alert('エラー', event.message);
        setExportFilename('');
      }
    });
    return () => subscription.remove();
  }, []);

  const handleBackToSelect = useCallback(() => {
    setScanState('idle');
    setPhase('select');
    setExportFilename('');
  }, []);

  const handleStartScan = useCallback(() => {
    setScanState('scanning');
  }, []);

  const handleStopScan = useCallback(() => {
    setScanState('idle');
  }, []);

  const handleExport = useCallback(() => {
    setScanState('exporting');
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    setExportFilename(`scan_${timestamp}`);
  }, []);

  // ─── Phase: select ─────────────────────────────────────────────
  if (phase === 'select') {
    return (
      <SafeAreaView style={styles.selectContainer} edges={['top', 'bottom']}>
        <Text style={styles.selectTitle}>スキャンモードを選択</Text>
        <Text style={styles.selectSubtitle}>使用するカメラを選んでください</Text>

        <View style={styles.modeCards}>
          <TouchableOpacity
            style={[styles.modeCard, scannerMode === 'lidar' && styles.modeCardActive]}
            onPress={() => setScannerMode('lidar')}>
            <Text style={styles.modeCardIcon}>{'📡'}</Text>
            <Text
              style={[
                styles.modeCardTitle,
                scannerMode === 'lidar' && styles.modeCardTitleActive,
              ]}>
              LiDAR
            </Text>
            <Text style={styles.modeCardDesc}>
              環境・物体の高精度3Dスキャン{'\n'}iPhone 12 Pro以降
            </Text>
            {scannerMode === 'lidar' && (
              <View style={styles.modeCardCheck}>
                <Text style={styles.modeCardCheckText}>{'✓'}</Text>
              </View>
            )}
          </TouchableOpacity>

          <TouchableOpacity
            style={[
              styles.modeCard,
              scannerMode === 'trueDepthObject' && styles.modeCardActive,
            ]}
            onPress={() => setScannerMode('trueDepthObject')}>
            <Text style={styles.modeCardIcon}>{'🫁'}</Text>
            <Text
              style={[
                styles.modeCardTitle,
                scannerMode === 'trueDepthObject' && styles.modeCardTitleActive,
              ]}>
              TrueDepth（物体）
            </Text>
            <Text style={styles.modeCardDesc}>
              顔以外のオブジェクトの深度スキャン{'\n'}距離15〜120cm推奨
            </Text>
            {scannerMode === 'trueDepthObject' && (
              <View style={styles.modeCardCheck}>
                <Text style={styles.modeCardCheckText}>{'✓'}</Text>
              </View>
            )}
          </TouchableOpacity>

          <View style={[styles.modeCard, styles.modeCardDisabled]}>
            <Text style={styles.modeCardIcon}>{'🔭'}</Text>
            <Text style={[styles.modeCardTitle, styles.modeCardTitleDisabled]}>
              Structure Sensor
            </Text>
            <Text style={styles.modeCardDesc}>
              外付け赤外線深度センサー{'\n'}高精度・近距離スキャン対応
            </Text>
            <View style={styles.modeCardBadge}>
              <Text style={styles.modeCardBadgeText}>準備中</Text>
            </View>
          </View>
        </View>

        <TouchableOpacity
          style={styles.proceedButton}
          onPress={() => setPhase('active')}>
          <Text style={styles.proceedButtonText}>
            {scannerMode === 'lidar'
              ? 'LiDAR'
              : scannerMode === 'structureSensor'
              ? 'Structure Sensor'
              : 'TrueDepth（物体）'}
            でスキャン開始
          </Text>
        </TouchableOpacity>
      </SafeAreaView>
    );
  }

  // ─── Phase: active ─────────────────────────────────────────────
  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <LiDARScannerView
        style={styles.scanner}
        showMeshOverlay={showMesh}
        boundingBoxEnabled={scannerMode === 'lidar' && boxEnabled}
        boxWidth={boxW}
        boxHeight={boxH}
        boxDepth={boxD}
        scannerMode={scannerMode}
        isScanning={scanState === 'scanning'}
        exportFilename={exportFilename}
        shareFilePath={shareFilePath}
      />

      <TouchableOpacity
        style={styles.backButton}
        onPress={handleBackToSelect}
        disabled={scanState === 'exporting'}>
        <Text style={styles.backButtonText}>{'‹ モード選択'}</Text>
      </TouchableOpacity>

      <View style={styles.overlay}>
        {scanState === 'scanning' && (
          <View style={styles.statusBadge}>
            <View style={styles.recordingDot} />
            <Text style={styles.statusText}>スキャン中...</Text>
          </View>
        )}
        {scanState === 'exporting' && (
          <View style={styles.statusBadge}>
            <ActivityIndicator size="small" color="#fff" />
            <Text style={styles.statusText}>エクスポート中...</Text>
          </View>
        )}
      </View>

      {scannerMode === 'lidar' && boxEnabled && (
        <View style={styles.boxPanel}>
          <Text style={styles.boxHintText}>
            スマホを向けて範囲を合わせ、開始すると固定されます
          </Text>
          <BoxDimRow
            label="幅"
            value={boxW}
            onChange={v => setBoxW(clampDim(v))}
            disabled={scanState !== 'idle'}
          />
          <BoxDimRow
            label="高さ"
            value={boxH}
            onChange={v => setBoxH(clampDim(v))}
            disabled={scanState !== 'idle'}
          />
          <BoxDimRow
            label="奥行"
            value={boxD}
            onChange={v => setBoxD(clampDim(v))}
            disabled={scanState !== 'idle'}
          />
        </View>
      )}

      <View style={styles.controls}>
        <View style={styles.toggleColumn}>
          <TouchableOpacity
            style={styles.toggleButton}
            onPress={() => setShowMesh(prev => !prev)}>
            <Text style={styles.toggleText}>メッシュ {showMesh ? 'OFF' : 'ON'}</Text>
          </TouchableOpacity>
          {scannerMode === 'lidar' && (
            <TouchableOpacity
              style={[styles.toggleButton, boxEnabled && styles.toggleButtonActive]}
              onPress={() => setBoxEnabled(prev => !prev)}>
              <Text style={styles.toggleText}>範囲 {boxEnabled ? 'ON' : 'OFF'}</Text>
            </TouchableOpacity>
          )}
        </View>

        {scanState === 'idle' ? (
          <TouchableOpacity style={styles.scanButton} onPress={handleStartScan}>
            <Text style={styles.scanButtonText}>開始</Text>
          </TouchableOpacity>
        ) : scanState === 'scanning' ? (
          <TouchableOpacity
            style={[styles.scanButton, styles.stopButton]}
            onPress={handleStopScan}>
            <Text style={styles.scanButtonText}>停止</Text>
          </TouchableOpacity>
        ) : (
          <View style={[styles.scanButton, styles.disabledButton]}>
            <ActivityIndicator color="#fff" />
          </View>
        )}

        <TouchableOpacity
          style={[styles.exportButton, scanState === 'exporting' && styles.disabledButton]}
          onPress={handleExport}
          disabled={scanState === 'exporting'}>
          <Text style={styles.exportText}>STL保存</Text>
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  selectContainer: {
    flex: 1,
    backgroundColor: '#1a1a2e',
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 24,
  },
  selectTitle: {
    fontSize: 26,
    fontWeight: '800',
    color: '#fff',
    marginBottom: 8,
  },
  selectSubtitle: {
    fontSize: 14,
    color: '#888',
    marginBottom: 36,
  },
  modeCards: {
    width: '100%',
    gap: 14,
    marginBottom: 40,
  },
  modeCard: {
    backgroundColor: '#252540',
    borderRadius: 16,
    padding: 20,
    borderWidth: 2,
    borderColor: '#333',
    position: 'relative',
  },
  modeCardActive: {
    borderColor: '#007aff',
    backgroundColor: 'rgba(0,122,255,0.12)',
  },
  modeCardIcon: {
    fontSize: 32,
    marginBottom: 8,
  },
  modeCardTitle: {
    fontSize: 18,
    fontWeight: '700',
    color: '#aaa',
    marginBottom: 4,
  },
  modeCardTitleActive: {
    color: '#007aff',
  },
  modeCardDisabled: {
    opacity: 0.4,
  },
  modeCardTitleDisabled: {
    color: '#555',
  },
  modeCardBadge: {
    position: 'absolute',
    top: 16,
    right: 16,
    backgroundColor: '#444',
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderRadius: 8,
  },
  modeCardBadgeText: {
    color: '#aaa',
    fontSize: 11,
    fontWeight: '600',
  },
  modeCardDesc: {
    fontSize: 13,
    color: '#666',
    lineHeight: 18,
  },
  modeCardCheck: {
    position: 'absolute',
    top: 16,
    right: 16,
    width: 28,
    height: 28,
    borderRadius: 14,
    backgroundColor: '#007aff',
    alignItems: 'center',
    justifyContent: 'center',
  },
  modeCardCheckText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '700',
  },
  proceedButton: {
    backgroundColor: '#007aff',
    paddingHorizontal: 40,
    paddingVertical: 16,
    borderRadius: 16,
    shadowColor: '#007aff',
    shadowOffset: {width: 0, height: 4},
    shadowOpacity: 0.4,
    shadowRadius: 10,
    elevation: 6,
  },
  proceedButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '700',
  },
  scanner: {
    flex: 1,
  },
  backButton: {
    position: 'absolute',
    top: 16,
    left: 16,
    backgroundColor: 'rgba(0,0,0,0.55)',
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 20,
  },
  backButtonText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '600',
  },
  overlay: {
    position: 'absolute',
    top: 60,
    alignSelf: 'center',
  },
  statusBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.6)',
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: 20,
    gap: 8,
  },
  recordingDot: {
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: '#ff3b30',
  },
  statusText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '600',
  },
  controls: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-around',
    paddingVertical: 20,
    paddingHorizontal: 16,
    backgroundColor: 'rgba(0,0,0,0.8)',
  },
  toggleColumn: {
    gap: 8,
  },
  toggleButton: {
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 10,
    backgroundColor: '#333',
  },
  toggleButtonActive: {
    backgroundColor: '#007aff',
  },
  boxPanel: {
    position: 'absolute',
    bottom: 110,
    alignSelf: 'center',
    width: '90%',
    backgroundColor: 'rgba(0,0,0,0.7)',
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 16,
    gap: 8,
  },
  boxHintText: {
    color: '#ffd60a',
    fontSize: 12,
    fontWeight: '600',
    textAlign: 'center',
    marginBottom: 4,
  },
  dimRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  dimLabel: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '700',
    width: 48,
  },
  dimButton: {
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: '#007aff',
    alignItems: 'center',
    justifyContent: 'center',
  },
  dimButtonText: {
    color: '#fff',
    fontSize: 22,
    fontWeight: '700',
    lineHeight: 26,
  },
  dimValue: {
    color: '#fff',
    fontSize: 15,
    fontWeight: '600',
    width: 70,
    textAlign: 'center',
  },
  toggleText: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '600',
  },
  scanButton: {
    width: 80,
    height: 80,
    borderRadius: 40,
    backgroundColor: '#007aff',
    alignItems: 'center',
    justifyContent: 'center',
  },
  stopButton: {
    backgroundColor: '#ff3b30',
  },
  disabledButton: {
    opacity: 0.5,
  },
  scanButtonText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '700',
  },
  exportButton: {
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 10,
    backgroundColor: '#34c759',
  },
  exportText: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '600',
  },
});