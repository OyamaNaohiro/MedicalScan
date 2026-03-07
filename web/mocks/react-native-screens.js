import React from 'react';
import {View} from 'react-native';

export const enableScreens = () => {};
export const enableFreeze = () => {};
export const screensEnabled = () => false;

export const ScreenContainer = (props) => React.createElement(View, props);
export const Screen = (props) => React.createElement(View, props);
export const NativeScreen = (props) => React.createElement(View, props);
export const NativeScreenContainer = (props) => React.createElement(View, props);

export default {
  enableScreens,
  enableFreeze,
  screensEnabled,
  ScreenContainer,
  Screen,
  NativeScreen,
  NativeScreenContainer,
};
