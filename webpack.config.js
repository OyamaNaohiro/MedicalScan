const path = require('path');
const HtmlWebpackPlugin = require('html-webpack-plugin');

module.exports = {
  mode: 'development',
  entry: path.resolve(__dirname, 'index.web.js'),
  output: {
    path: path.resolve(__dirname, 'dist'),
    filename: 'bundle.js',
  },
  resolve: {
    extensions: ['.web.tsx', '.web.ts', '.web.js', '.tsx', '.ts', '.js'],
    alias: {
      'react-native$': 'react-native-web',
      'react-native-fs': path.resolve(__dirname, 'web/mocks/react-native-fs.js'),
      'react-native-share': path.resolve(
        __dirname,
        'web/mocks/react-native-share.js',
      ),
      '@react-native-async-storage/async-storage': path.resolve(
        __dirname,
        'web/mocks/async-storage.js',
      ),
      'react-native-screens': path.resolve(
        __dirname,
        'web/mocks/react-native-screens.js',
      ),
      'react-native-vector-icons': path.resolve(
        __dirname,
        'web/mocks/react-native-vector-icons.js',
      ),
    },
  },
  module: {
    rules: [
      {
        test: /\.js$/,
        resolve: {fullySpecified: false},
      },
      {
        test: /\.[jt]sx?$/,
        exclude:
          /node_modules\/(?!(react-native-safe-area-context|@react-navigation|@react-native\/elements|react-native-tab-view|react-native-pager-view)\/).*/,
        use: {
          loader: 'babel-loader',
          options: {
            configFile: false,
            babelrc: false,
            sourceType: 'module',
            presets: [
              ['@babel/preset-env', {modules: false}],
              ['@babel/preset-react', {runtime: 'automatic'}],
              '@babel/preset-typescript',
              '@babel/preset-flow',
            ],
            plugins: [
              'react-native-web',
              [
                '@babel/plugin-transform-private-methods',
                {loose: true},
              ],
              [
                '@babel/plugin-transform-private-property-in-object',
                {loose: true},
              ],
            ],
          },
        },
      },
      {
        test: /\.(png|jpe?g|gif|svg)$/,
        type: 'asset/resource',
      },
    ],
  },
  plugins: [
    new HtmlWebpackPlugin({
      template: path.resolve(__dirname, 'web/index.html'),
    }),
  ],
  devServer: {
    port: 8080,
    hot: true,
    open: true,
  },
};
