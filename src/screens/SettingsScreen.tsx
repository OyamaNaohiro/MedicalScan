import React, {useState, useEffect, useCallback} from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  Alert,
  Keyboard,
  ScrollView,
} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import AsyncStorage from '@react-native-async-storage/async-storage';

const EMAIL_STORAGE_KEY = '@MedicalScan:defaultEmail';

export default function SettingsScreen() {
  const [email, setEmail] = useState('');
  const [savedEmail, setSavedEmail] = useState('');

  useEffect(() => {
    AsyncStorage.getItem(EMAIL_STORAGE_KEY).then(value => {
      if (value) {
        setEmail(value);
        setSavedEmail(value);
      }
    });
  }, []);

  const handleSave = useCallback(async () => {
    const trimmed = email.trim();
    if (trimmed && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(trimmed)) {
      Alert.alert('エラー', '有効なメールアドレスを入力してください');
      return;
    }
    try {
      await AsyncStorage.setItem(EMAIL_STORAGE_KEY, trimmed);
      setSavedEmail(trimmed);
      Keyboard.dismiss();
      Alert.alert('保存完了', 'デフォルトの送信先アドレスを保存しました');
    } catch {
      Alert.alert('エラー', '設定の保存に失敗しました');
    }
  }, [email]);

  const hasChanges = email.trim() !== savedEmail;

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <ScrollView keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag">
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>メール送信設定</Text>
          <View style={styles.card}>
            <Text style={styles.label}>デフォルト送信先アドレス</Text>
            <TextInput
              style={styles.input}
              value={email}
              onChangeText={setEmail}
              placeholder="example@gmail.com"
              placeholderTextColor="#c7c7cc"
              keyboardType="email-address"
              autoCapitalize="none"
              autoCorrect={false}
            />
            <Text style={styles.hint}>
              STLファイル送信時のデフォルトの宛先として使用されます
            </Text>
          </View>

          <TouchableOpacity
            style={[styles.saveButton, !hasChanges && styles.disabledButton]}
            onPress={handleSave}
            disabled={!hasChanges}>
            <Text style={styles.saveText}>保存</Text>
          </TouchableOpacity>
        </View>

        <View style={styles.section}>
          <Text style={styles.sectionTitle}>アプリ情報</Text>
          <View style={styles.card}>
            <View style={styles.infoRow}>
              <Text style={styles.infoLabel}>バージョン</Text>
              <Text style={styles.infoValue}>1.0.0</Text>
            </View>
            <View style={styles.infoRow}>
              <Text style={styles.infoLabel}>スキャン精度</Text>
              <Text style={styles.infoValue}>実寸 1:1（メートル単位）</Text>
            </View>
            <View style={styles.infoRow}>
              <Text style={styles.infoLabel}>出力形式</Text>
              <Text style={styles.infoValue}>STL (Stereolithography)</Text>
            </View>
          </View>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#f2f2f7',
  },
  section: {
    padding: 16,
  },
  sectionTitle: {
    fontSize: 13,
    fontWeight: '600',
    color: '#8e8e93',
    textTransform: 'uppercase',
    marginBottom: 8,
    marginLeft: 4,
  },
  card: {
    backgroundColor: '#fff',
    borderRadius: 12,
    padding: 16,
    shadowColor: '#000',
    shadowOffset: {width: 0, height: 1},
    shadowOpacity: 0.05,
    shadowRadius: 4,
    elevation: 2,
  },
  label: {
    fontSize: 14,
    fontWeight: '600',
    color: '#1c1c1e',
    marginBottom: 8,
  },
  input: {
    borderWidth: 1,
    borderColor: '#e5e5ea',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 16,
    color: '#1c1c1e',
    backgroundColor: '#f9f9f9',
  },
  hint: {
    fontSize: 12,
    color: '#aeaeb2',
    marginTop: 8,
  },
  saveButton: {
    backgroundColor: '#007aff',
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: 'center',
    marginTop: 16,
  },
  disabledButton: {
    opacity: 0.5,
  },
  saveText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
  infoRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#e5e5ea',
  },
  infoLabel: {
    fontSize: 15,
    color: '#1c1c1e',
  },
  infoValue: {
    fontSize: 15,
    color: '#8e8e93',
  },
});
