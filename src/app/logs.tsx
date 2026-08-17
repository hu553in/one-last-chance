import * as Clipboard from 'expo-clipboard';
import * as Haptics from 'expo-haptics';
import { useFocusEffect } from 'expo-router';
import { useCallback, useRef, useState } from 'react';
import {
  NativeScrollEvent,
  NativeSyntheticEvent,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import OlcRtcVpn from '@/native/olcrtc-vpn';
import { colors, spacing } from '@/theme';

export default function LogsScreen() {
  const [logs, setLogs] = useState('');
  const scrollRef = useRef<ScrollView>(null);
  const followRef = useRef(true);

  const load = useCallback(async () => {
    try {
      setLogs(await OlcRtcVpn.getLogs());
    } catch (error) {
      setLogs(`Unable to read logs: ${errorMessage(error)}`);
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      void load();
      const timer = setInterval(load, 1000);
      return () => clearInterval(timer);
    }, [load])
  );

  const onScroll = (event: NativeSyntheticEvent<NativeScrollEvent>) => {
    const { contentOffset, contentSize, layoutMeasurement } = event.nativeEvent;
    followRef.current = contentSize.height - (contentOffset.y + layoutMeasurement.height) < 72;
  };

  const copy = async () => {
    await Clipboard.setStringAsync(logs);
    void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
  };

  const clear = async () => {
    await OlcRtcVpn.clearLogs();
    await load();
  };

  return (
    <View style={styles.container}>
      <View style={styles.toolbar}>
        <Text style={styles.caption}>App and packet tunnel lifecycle</Text>
        <View style={styles.actions}>
          <Pressable accessibilityRole="button" disabled={!logs} hitSlop={8} onPress={copy}>
            <Text style={[styles.action, !logs && styles.disabled]}>Copy</Text>
          </Pressable>
          <Pressable accessibilityRole="button" hitSlop={8} onPress={clear}>
            <Text style={styles.destructiveAction}>Clear</Text>
          </Pressable>
        </View>
      </View>
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
    </View>
  );
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  toolbar: {
    flexDirection: 'row',
    minHeight: 52,
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: spacing.x4,
    gap: spacing.x3,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.separator,
  },
  caption: { flex: 1, color: colors.secondaryLabel, fontSize: 12, lineHeight: 16 },
  actions: { flexDirection: 'row', gap: spacing.x4 },
  action: { color: colors.blue, fontSize: 15, fontWeight: '600' },
  destructiveAction: { color: colors.red, fontSize: 15, fontWeight: '600' },
  disabled: { opacity: 0.4 },
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
