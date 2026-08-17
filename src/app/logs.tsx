import * as Clipboard from 'expo-clipboard';
import * as Haptics from 'expo-haptics';
import { Stack, useFocusEffect } from 'expo-router';
import { useCallback, useRef, useState } from 'react';
import {
  Alert,
  NativeScrollEvent,
  NativeSyntheticEvent,
  ScrollView,
  StyleSheet,
  Text,
} from 'react-native';

import { errorMessage } from '@/lib/error';
import OlcRtcVpn from '@/native/olcrtc-vpn';
import { colors, spacing } from '@/theme';

export default function LogsScreen() {
  const [logs, setLogs] = useState('');
  const scrollRef = useRef<ScrollView>(null);
  const followRef = useRef(true);
  const loadVersionRef = useRef(0);

  const load = useCallback(async () => {
    const version = ++loadVersionRef.current;
    try {
      const nextLogs = await OlcRtcVpn.getLogs();
      if (version === loadVersionRef.current) setLogs(nextLogs);
    } catch (error) {
      if (version === loadVersionRef.current) {
        setLogs(`Unable to read logs: ${errorMessage(error)}`);
      }
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      void load();
      const timer = setInterval(load, 1000);
      return () => {
        clearInterval(timer);
        loadVersionRef.current += 1;
      };
    }, [load])
  );

  const onScroll = (event: NativeSyntheticEvent<NativeScrollEvent>) => {
    const { contentOffset, contentSize, layoutMeasurement } = event.nativeEvent;
    followRef.current = contentSize.height - (contentOffset.y + layoutMeasurement.height) < 72;
  };

  const copy = async () => {
    try {
      await Clipboard.setStringAsync(logs);
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
    } catch (error) {
      Alert.alert('Could not copy logs', errorMessage(error));
    }
  };

  const clear = async () => {
    try {
      await OlcRtcVpn.clearLogs();
      await load();
    } catch (error) {
      Alert.alert('Could not clear logs', errorMessage(error));
    }
  };

  return (
    <>
      <ScrollView
        ref={scrollRef}
        contentInsetAdjustmentBehavior="automatic"
        onContentSizeChange={() => {
          if (followRef.current) scrollRef.current?.scrollToEnd({ animated: false });
        }}
        onScroll={onScroll}
        scrollEventThrottle={100}
        style={styles.logScroll}
        contentContainerStyle={styles.logContent}
      >
        <Text selectable style={styles.logText}>
          {logs || 'No logs yet. Connect once and tunnel events will appear here.'}
        </Text>
      </ScrollView>
      <Stack.Toolbar placement="right">
        <Stack.Toolbar.Button
          accessibilityLabel="Copy logs"
          disabled={!logs}
          icon="doc.on.doc"
          onPress={() => void copy()}
          tintColor={colors.blue}
        />
        <Stack.Toolbar.Button
          accessibilityLabel="Clear logs"
          disabled={!logs}
          icon="trash"
          onPress={() => void clear()}
          tintColor={colors.red}
        />
      </Stack.Toolbar>
    </>
  );
}

const styles = StyleSheet.create({
  logScroll: { flex: 1, backgroundColor: colors.surface },
  logContent: { padding: spacing.x4, paddingBottom: spacing.x8 },
  logText: {
    color: colors.label,
    fontFamily: 'ui-monospace',
    fontSize: 12,
    lineHeight: 18,
    fontVariant: ['tabular-nums'],
  },
});
