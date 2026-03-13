import React from 'react';
import {Platform, View, ViewStyle, requireNativeComponent} from 'react-native';

interface Props {
  stlFilePath: string;
  style?: ViewStyle;
}

const NativeSTLViewer =
  Platform.OS === 'ios'
    ? requireNativeComponent<Props>('STLViewerView')
    : null;

export function STLViewerView({stlFilePath, style}: Props) {
  if (Platform.OS !== 'ios' || !NativeSTLViewer) {
    return <View style={style} />;
  }
  return <NativeSTLViewer stlFilePath={stlFilePath} style={style} />;
}