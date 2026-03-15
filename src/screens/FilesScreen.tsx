import React, {useState, useCallback} from 'react';
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  StyleSheet,
  Alert,
  Modal,
} from 'react-native';
import {SafeAreaView, useSafeAreaInsets} from 'react-native-safe-area-context';
import {useFocusEffect} from '@react-navigation/native';
import RNFS from 'react-native-fs';
import Share from 'react-native-share';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {STLViewerView} from '../native/STLViewerView';

const EMAIL_STORAGE_KEY = '@STLscan:defaultEmail';

interface STLFile {
  name: string;
  path: string;
  size: number;
  mtime: Date;
}

export default function FilesScreen() {
  const [files, setFiles] = useState<STLFile[]>([]);
  const [viewingFile, setViewingFile] = useState<STLFile | null>(null);
  const insets = useSafeAreaInsets();

  const loadFiles = useCallback(async () => {
    try {
      const documentsPath = RNFS.DocumentDirectoryPath;
      const items = await RNFS.readDir(documentsPath);
      const stlFiles = items
        .filter(item => item.name.endsWith('.stl'))
        .map(item => ({
          name: item.name,
          path: item.path,
          size: item.size,
          mtime: new Date(item.mtime ?? 0),
        }))
        .sort((a, b) => b.mtime.getTime() - a.mtime.getTime());
      setFiles(stlFiles);
    } catch {
      setFiles([]);
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      loadFiles();
    }, [loadFiles]),
  );

  const handleDelete = useCallback(
    (file: STLFile) => {
      Alert.alert('削除確認', `${file.name} を削除しますか？`, [
        {text: 'キャンセル', style: 'cancel'},
        {
          text: '削除',
          style: 'destructive',
          onPress: async () => {
            try {
              await RNFS.unlink(file.path);
              loadFiles();
            } catch {
              Alert.alert('エラー', 'ファイルの削除に失敗しました');
            }
          },
        },
      ]);
    },
    [loadFiles],
  );

  const handleShare = useCallback(async (file: STLFile) => {
    try {
      const savedEmail = await AsyncStorage.getItem(EMAIL_STORAGE_KEY);
      await Share.open({
        title: `STLscan - ${file.name}`,
        subject: `STLscan - ${file.name}`,
        message: `3Dスキャンデータ「${file.name}」を送信します。`,
        url: `file://${file.path}`,
        type: 'application/sla',
        email: savedEmail || undefined,
      });
    } catch (error: any) {
      if (error?.message !== 'User did not share') {
        Alert.alert('エラー', '共有に失敗しました');
      }
    }
  }, []);

  const formatSize = (bytes: number) => {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  };

  const formatDate = (date: Date) => {
    return date.toLocaleString('ja-JP', {
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
    });
  };

  const renderItem = ({item}: {item: STLFile}) => (
    <TouchableOpacity
      style={styles.fileItem}
      onPress={() => setViewingFile(item)}
      activeOpacity={0.7}>
      <View style={styles.fileInfo}>
        <Text style={styles.fileName}>{item.name}</Text>
        <Text style={styles.fileMeta}>
          {formatSize(item.size)} | {formatDate(item.mtime)}
        </Text>
      </View>
      <View style={styles.fileActions}>
        <TouchableOpacity
          style={styles.shareButton}
          onPress={() => handleShare(item)}>
          <Text style={styles.shareText}>送信</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={styles.deleteButton}
          onPress={() => handleDelete(item)}>
          <Text style={styles.deleteText}>削除</Text>
        </TouchableOpacity>
      </View>
    </TouchableOpacity>
  );

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      {files.length === 0 ? (
        <View style={styles.emptyContainer}>
          <Text style={styles.emptyText}>保存されたSTLファイルはありません</Text>
          <Text style={styles.emptySubtext}>
            スキャン画面でスキャンしてSTLを保存してください
          </Text>
        </View>
      ) : (
        <FlatList
          data={files}
          keyExtractor={item => item.path}
          renderItem={renderItem}
          contentContainerStyle={styles.list}
        />
      )}

      {/* STL Viewer Modal */}
      <Modal
        visible={viewingFile !== null}
        animationType="slide"
        onRequestClose={() => setViewingFile(null)}>
        <SafeAreaView style={styles.viewerContainer}>
          <View style={[styles.viewerHeader, {paddingTop: insets.top + 12}]}>
            <Text style={styles.viewerTitle} numberOfLines={1}>
              {viewingFile?.name}
            </Text>
            <TouchableOpacity
              style={styles.closeButton}
              onPress={() => setViewingFile(null)}>
              <Text style={styles.closeButtonText}>閉じる</Text>
            </TouchableOpacity>
          </View>
          <Text style={styles.viewerHint}>
            ドラッグで回転 / ピンチでズーム
          </Text>
          {viewingFile && (
            <STLViewerView
              style={styles.viewer}
              stlFilePath={viewingFile.path}
            />
          )}
          <View style={styles.viewerFooter}>
            <TouchableOpacity
              style={styles.shareButtonLarge}
              onPress={() => viewingFile && handleShare(viewingFile)}>
              <Text style={styles.shareText}>送信</Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={styles.deleteButtonLarge}
              onPress={() => {
                if (viewingFile) {
                  setViewingFile(null);
                  handleDelete(viewingFile);
                }
              }}>
              <Text style={styles.deleteText}>削除</Text>
            </TouchableOpacity>
          </View>
        </SafeAreaView>
      </Modal>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#f2f2f7',
  },
  list: {
    padding: 16,
  },
  emptyContainer: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 32,
  },
  emptyText: {
    fontSize: 17,
    fontWeight: '600',
    color: '#8e8e93',
    marginBottom: 8,
  },
  emptySubtext: {
    fontSize: 14,
    color: '#aeaeb2',
    textAlign: 'center',
  },
  fileItem: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#fff',
    borderRadius: 12,
    padding: 16,
    marginBottom: 10,
    shadowColor: '#000',
    shadowOffset: {width: 0, height: 1},
    shadowOpacity: 0.05,
    shadowRadius: 4,
    elevation: 2,
  },
  fileInfo: {
    flex: 1,
  },
  fileName: {
    fontSize: 15,
    fontWeight: '600',
    color: '#1c1c1e',
    marginBottom: 4,
  },
  fileMeta: {
    fontSize: 12,
    color: '#8e8e93',
  },
  fileActions: {
    flexDirection: 'row',
    gap: 8,
  },
  shareButton: {
    backgroundColor: '#007aff',
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 8,
  },
  shareText: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '600',
  },
  deleteButton: {
    backgroundColor: '#ff3b30',
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 8,
  },
  deleteText: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '600',
  },
  // Viewer modal
  viewerContainer: {
    flex: 1,
    backgroundColor: '#111',
  },
  viewerHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingBottom: 12,
    backgroundColor: '#1c1c1e',
  },
  viewerTitle: {
    flex: 1,
    fontSize: 16,
    fontWeight: '600',
    color: '#fff',
  },
  closeButton: {
    paddingHorizontal: 14,
    paddingVertical: 6,
    borderRadius: 8,
    backgroundColor: '#333',
  },
  closeButtonText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '600',
  },
  viewerHint: {
    textAlign: 'center',
    color: '#666',
    fontSize: 12,
    paddingVertical: 6,
    backgroundColor: '#111',
  },
  viewer: {
    flex: 1,
  },
  viewerFooter: {
    flexDirection: 'row',
    justifyContent: 'center',
    gap: 16,
    padding: 20,
    backgroundColor: '#1c1c1e',
  },
  shareButtonLarge: {
    flex: 1,
    backgroundColor: '#007aff',
    paddingVertical: 14,
    borderRadius: 12,
    alignItems: 'center',
  },
  deleteButtonLarge: {
    flex: 1,
    backgroundColor: '#ff3b30',
    paddingVertical: 14,
    borderRadius: 12,
    alignItems: 'center',
  },
});
