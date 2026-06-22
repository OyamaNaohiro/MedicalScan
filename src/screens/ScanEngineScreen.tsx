import React, {useState, useEffect, useCallback} from 'react';
import {View, Text, TouchableOpacity, StyleSheet} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {useFocusEffect} from '@react-navigation/native';
import {ScanEnginePreview, DepthDisplayMode} from '../native/ScanEnginePreview';
import {addScanEventListener} from '../native/ScanEventEmitter';

interface Metrics {
  renderFPS: number;
  depthFPS: number;
  gpuMs: number;
  cpuMs: number;
  validRatio: number;
  tracking: string;
  filterTimes: {[name: string]: number};
}

const EMPTY: Metrics = {
  renderFPS: 0,
  depthFPS: 0,
  gpuMs: 0,
  cpuMs: 0,
  validRatio: 0,
  tracking: '-',
  filterTimes: {},
};

const MODES: {label: string; value: DepthDisplayMode}[] = [
  {label: 'Raw', value: DepthDisplayMode.RawDepth},
  {label: 'Mask', value: DepthDisplayMode.ValidMask},
  {label: 'Filtered', value: DepthDisplayMode.Filtered},
  {label: 'Diff', value: DepthDisplayMode.Difference},
];

export default function ScanEngineScreen() {
  const [isScanning, setIsScanning] = useState(false);
  const [mode, setMode] = useState<DepthDisplayMode>(DepthDisplayMode.Filtered);
  const [confidenceOn, setConfidenceOn] = useState(true);
  const [bilateralOn, setBilateralOn] = useState(true);
  const [temporalOn, setTemporalOn] = useState(true);
  const [metrics, setMetrics] = useState<Metrics>(EMPTY);
  const [engineError, setEngineError] = useState<string | null>(null);
  const [lastEvent, setLastEvent] = useState<string>('');

  // 画面を離れたらスキャンを止める
  useFocusEffect(
    useCallback(() => {
      return () => {
        setIsScanning(false);
        setMetrics(EMPTY);
      };
    }, []),
  );

  useEffect(() => {
    const sub = addScanEventListener(event => {
      if (event.type === 'metrics') {
        setMetrics({
          renderFPS: event.renderFPS,
          depthFPS: event.depthFPS,
          gpuMs: event.gpuMs,
          cpuMs: event.cpuMs,
          validRatio: event.validRatio,
          tracking: event.tracking,
          filterTimes: event.filterTimes ?? {},
        });
      } else if (event.type === 'engineLog') {
        setLastEvent(`${event.kind}: ${event.message}`);
      } else if (event.type === 'engineError') {
        setEngineError(event.message);
        setIsScanning(false);
      }
    });
    return () => sub.remove();
  }, []);

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <ScanEnginePreview
        style={styles.preview}
        isScanning={isScanning}
        displayMode={mode}
        confidenceEnabled={confidenceOn}
        bilateralEnabled={bilateralOn}
        temporalEnabled={temporalOn}
      />

      {/* デバッグ HUD */}
      <View style={styles.hud} pointerEvents="none">
        <Text style={styles.hudTitle}>ScanEngine (Phase 3a)</Text>
        <HudRow label="Render FPS" value={metrics.renderFPS.toFixed(1)} />
        <HudRow label="Depth FPS" value={metrics.depthFPS.toFixed(1)} />
        <HudRow label="GPU" value={`${metrics.gpuMs.toFixed(2)} ms`} />
        <HudRow label="CPU" value={`${metrics.cpuMs.toFixed(2)} ms`} />
        <HudRow
          label="Conf GPU"
          value={`${(metrics.filterTimes.Confidence ?? 0).toFixed(2)} ms`}
        />
        <HudRow
          label="Bila GPU"
          value={`${(metrics.filterTimes.Bilateral ?? 0).toFixed(2)} ms`}
        />
        <HudRow
          label="Temp GPU"
          value={`${(metrics.filterTimes.Temporal ?? 0).toFixed(2)} ms`}
        />
        <HudRow
          label="Valid px"
          value={`${(metrics.validRatio * 100).toFixed(1)} %`}
        />
        <HudRow label="Tracking" value={metrics.tracking} />
        {lastEvent !== '' && <Text style={styles.hudEvent}>{lastEvent}</Text>}
      </View>

      {engineError && (
        <View style={styles.errorBox}>
          <Text style={styles.errorText}>{engineError}</Text>
        </View>
      )}

      {/* フィルタ ON/OFF */}
      <View style={styles.filterRow}>
        <FilterChip label="Conf" on={confidenceOn} onPress={() => setConfidenceOn(p => !p)} />
        <FilterChip label="Bila" on={bilateralOn} onPress={() => setBilateralOn(p => !p)} />
        <FilterChip label="Temp" on={temporalOn} onPress={() => setTemporalOn(p => !p)} />
      </View>

      {/* 表示モード切替 */}
      <View style={styles.modeRow}>
        {MODES.map(m => (
          <TouchableOpacity
            key={m.value}
            style={[styles.modeButton, mode === m.value && styles.modeButtonActive]}
            onPress={() => setMode(m.value)}>
            <Text
              style={[styles.modeText, mode === m.value && styles.modeTextActive]}>
              {m.label}
            </Text>
          </TouchableOpacity>
        ))}
      </View>

      {/* 開始/停止 */}
      <View style={styles.controls}>
        <TouchableOpacity
          style={[styles.scanButton, isScanning && styles.stopButton]}
          onPress={() => setIsScanning(prev => !prev)}>
          <Text style={styles.scanButtonText}>
            {isScanning ? '停止' : '開始'}
          </Text>
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
}

function FilterChip({
  label,
  on,
  onPress,
}: {
  label: string;
  on: boolean;
  onPress: () => void;
}) {
  return (
    <TouchableOpacity
      style={[styles.filterChip, on && styles.filterChipActive]}
      onPress={onPress}>
      <Text style={[styles.filterText, on && styles.filterTextActive]}>
        {label} {on ? 'ON' : 'OFF'}
      </Text>
    </TouchableOpacity>
  );
}

function HudRow({label, value}: {label: string; value: string}) {
  return (
    <View style={styles.hudRow}>
      <Text style={styles.hudLabel}>{label}</Text>
      <Text style={styles.hudValue}>{value}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: '#000'},
  preview: {flex: 1},
  hud: {
    position: 'absolute',
    top: 16,
    left: 16,
    backgroundColor: 'rgba(0,0,0,0.6)',
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderRadius: 12,
    minWidth: 180,
  },
  hudTitle: {
    color: '#0af',
    fontSize: 12,
    fontWeight: '700',
    marginBottom: 6,
  },
  hudRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 1,
  },
  hudLabel: {color: '#aaa', fontSize: 12, marginRight: 12},
  hudValue: {color: '#fff', fontSize: 12, fontWeight: '600', fontVariant: ['tabular-nums']},
  hudEvent: {color: '#ffd60a', fontSize: 11, marginTop: 6, maxWidth: 200},
  filterRow: {
    flexDirection: 'row',
    justifyContent: 'center',
    gap: 8,
    paddingTop: 10,
    backgroundColor: 'rgba(0,0,0,0.85)',
  },
  filterChip: {
    paddingHorizontal: 16,
    paddingVertical: 6,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: '#555',
  },
  filterChipActive: {backgroundColor: '#0a84ff', borderColor: '#0a84ff'},
  filterText: {color: '#bbb', fontSize: 12, fontWeight: '600'},
  filterTextActive: {color: '#fff'},
  errorBox: {
    position: 'absolute',
    top: 16,
    right: 16,
    maxWidth: 200,
    backgroundColor: 'rgba(200,0,0,0.8)',
    padding: 10,
    borderRadius: 10,
  },
  errorText: {color: '#fff', fontSize: 12},
  modeRow: {
    flexDirection: 'row',
    justifyContent: 'center',
    gap: 8,
    paddingVertical: 10,
    backgroundColor: 'rgba(0,0,0,0.85)',
  },
  modeButton: {
    paddingHorizontal: 18,
    paddingVertical: 8,
    borderRadius: 10,
    backgroundColor: '#333',
  },
  modeButtonActive: {backgroundColor: '#007aff'},
  modeText: {color: '#bbb', fontSize: 13, fontWeight: '600'},
  modeTextActive: {color: '#fff'},
  controls: {
    alignItems: 'center',
    paddingVertical: 16,
    backgroundColor: 'rgba(0,0,0,0.85)',
  },
  scanButton: {
    width: 88,
    height: 88,
    borderRadius: 44,
    backgroundColor: '#007aff',
    alignItems: 'center',
    justifyContent: 'center',
  },
  stopButton: {backgroundColor: '#ff3b30'},
  scanButtonText: {color: '#fff', fontSize: 16, fontWeight: '700'},
});
