import React from 'react';
import {StatusBar, StyleSheet, useColorScheme, View} from 'react-native';
import {SafeAreaProvider} from 'react-native-safe-area-context';
import {NavigationContainer} from '@react-navigation/native';
import {createBottomTabNavigator} from '@react-navigation/bottom-tabs';

import ScanScreen from './src/screens/ScanScreen';
import FilesScreen from './src/screens/FilesScreen';
import SettingsScreen from './src/screens/SettingsScreen';

const Tab = createBottomTabNavigator();

function App() {
  const isDarkMode = useColorScheme() === 'dark';

  return (
    <SafeAreaProvider style={styles.root}>
      <View style={styles.root}>
        <StatusBar barStyle={isDarkMode ? 'light-content' : 'dark-content'} />
        <NavigationContainer>
        <Tab.Navigator
          screenOptions={{
            tabBarActiveTintColor: '#007aff',
            tabBarInactiveTintColor: '#8e8e93',
            tabBarStyle: {
              backgroundColor: isDarkMode ? '#1c1c1e' : '#fff',
              borderTopColor: isDarkMode ? '#38383a' : '#e5e5ea',
            },
            headerStyle: {
              backgroundColor: isDarkMode ? '#1c1c1e' : '#f8f8f8',
            },
            headerTintColor: isDarkMode ? '#fff' : '#1c1c1e',
          }}>
          <Tab.Screen
            name="Scan"
            component={ScanScreen}
            options={{
              title: 'スキャン',
              headerShown: false,
              tabBarLabel: 'スキャン',
            }}
          />
          <Tab.Screen
            name="Files"
            component={FilesScreen}
            options={{
              title: 'ファイル',
              tabBarLabel: 'ファイル',
            }}
          />
          <Tab.Screen
            name="Settings"
            component={SettingsScreen}
            options={{
              title: '設定',
              tabBarLabel: '設定',
            }}
          />
        </Tab.Navigator>
        </NavigationContainer>
      </View>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
  },
});

export default App;
