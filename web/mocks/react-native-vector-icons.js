import React from 'react';
import {Text} from 'react-native';

const Icon = ({name, size, color, ...props}) =>
  React.createElement(Text, {...props, style: {fontSize: size, color}}, name);

export default Icon;
export const createIconSetFromIcoMoon = () => Icon;
