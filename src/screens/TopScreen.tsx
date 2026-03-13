import React from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  useColorScheme,
} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {useNavigation} from '@react-navigation/native';

export default function TopScreen() {
  const isDarkMode = useColorScheme() === 'dark';
  const navigation = useNavigation<any>();

  return (
    <SafeAreaView
      style={[
        styles.container,
        {backgroundColor: isDarkMode ? '#1a1a2e' : '#f0f4ff'},
      ]}>
      <View style={styles.inner}>
        <View style={styles.iconBox}>
          <Text style={styles.icon}>{'🔬'}</Text>
        </View>

        <Text style={[styles.title, {color: isDarkMode ? '#fff' : '#1c1c1e'}]}>
          STLscan
        </Text>
        <Text
          style={[styles.subtitle, {color: isDarkMode ? '#aaa' : '#555'}]}>
          LiDAR / TrueDepthカメラで{'\n'}3Dスキャンを行いSTLで保存します
        </Text>

        <View style={styles.featureList}>
          <FeatureRow
            icon="📡"
            label="LiDARスキャン"
            desc="環境・物体の高精度3Dスキャン"
            dark={isDarkMode}
          />
          <FeatureRow
            icon="👤"
            label="TrueDepthスキャン"
            desc="顔・近距離オブジェクトのスキャン"
            dark={isDarkMode}
          />
          <FeatureRow
            icon="💾"
            label="STLエクスポート"
            desc="3Dプリンタ・CADで使えるSTL形式で保存"
            dark={isDarkMode}
          />
        </View>

        <TouchableOpacity
          style={styles.startButton}
          onPress={() => navigation.navigate('Scan')}>
          <Text style={styles.startButtonText}>スキャンを始める</Text>
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
}

function FeatureRow({
  icon,
  label,
  desc,
  dark,
}: {
  icon: string;
  label: string;
  desc: string;
  dark: boolean;
}) {
  return (
    <View style={[styles.featureRow, {backgroundColor: dark ? '#252540' : '#fff'}]}>
      <Text style={styles.featureIcon}>{icon}</Text>
      <View style={styles.featureText}>
        <Text style={[styles.featureLabel, {color: dark ? '#fff' : '#1c1c1e'}]}>
          {label}
        </Text>
        <Text style={[styles.featureDesc, {color: dark ? '#888' : '#666'}]}>
          {desc}
        </Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  inner: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 28,
  },
  iconBox: {
    width: 100,
    height: 100,
    borderRadius: 24,
    backgroundColor: '#007aff',
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 24,
    shadowColor: '#007aff',
    shadowOffset: {width: 0, height: 6},
    shadowOpacity: 0.35,
    shadowRadius: 12,
    elevation: 8,
  },
  icon: {
    fontSize: 52,
  },
  title: {
    fontSize: 34,
    fontWeight: '800',
    letterSpacing: 0.5,
    marginBottom: 10,
  },
  subtitle: {
    fontSize: 15,
    textAlign: 'center',
    lineHeight: 22,
    marginBottom: 36,
  },
  featureList: {
    width: '100%',
    gap: 10,
    marginBottom: 40,
  },
  featureRow: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: 14,
    borderRadius: 12,
    gap: 14,
    shadowColor: '#000',
    shadowOffset: {width: 0, height: 1},
    shadowOpacity: 0.06,
    shadowRadius: 4,
    elevation: 2,
  },
  featureIcon: {
    fontSize: 28,
  },
  featureText: {
    flex: 1,
  },
  featureLabel: {
    fontSize: 15,
    fontWeight: '600',
    marginBottom: 2,
  },
  featureDesc: {
    fontSize: 12,
    lineHeight: 16,
  },
  startButton: {
    backgroundColor: '#007aff',
    paddingHorizontal: 48,
    paddingVertical: 16,
    borderRadius: 16,
    shadowColor: '#007aff',
    shadowOffset: {width: 0, height: 4},
    shadowOpacity: 0.4,
    shadowRadius: 10,
    elevation: 6,
  },
  startButtonText: {
    color: '#fff',
    fontSize: 17,
    fontWeight: '700',
  },
});
