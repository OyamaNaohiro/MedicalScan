import {AppRegistry} from 'react-native';
import App from './App';
const appName = 'MedicalScan';

AppRegistry.registerComponent(appName, () => App);
AppRegistry.runApplication(appName, {
  rootTag: document.getElementById('root'),
});
