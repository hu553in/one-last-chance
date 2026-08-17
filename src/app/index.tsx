import * as Clipboard from 'expo-clipboard';
import * as Haptics from 'expo-haptics';
import { Stack, useRouter } from 'expo-router';
import { type SFSymbol, SymbolView } from 'expo-symbols';
import { useEffect, useState } from 'react';
import {
  ActionSheetIOS,
  ActivityIndicator,
  Alert,
  type ColorValue,
  KeyboardAvoidingView,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useVPN } from '@/hooks/use-vpn';
import { errorMessage } from '@/lib/error';
import type { PublicIP } from '@/lib/public-ip';
import type { VPNStatus } from '@/native/olcrtc-vpn';
import { fetchPublicIP } from '@/services/public-ip';
import { colors, radii, spacing } from '@/theme';

const publicIPRequestTimeoutMilliseconds = 8_000;

export default function HomeScreen() {
  const insets = useSafeAreaInsets();
  const router = useRouter();
  const vpn = useVPN();
  const [editing, setEditing] = useState(false);
  const [draftURL, setDraftURL] = useState<string | null>(null);
  const url = draftURL ?? vpn.url ?? '';
  const summary = vpn.summary;

  const status = statusPresentation(vpn.status);
  const canDisconnect = ['connected', 'connecting', 'reasserting'].includes(vpn.status);
  const canUpdateSubscription = vpn.status === 'invalid' || vpn.status === 'disconnected';
  const subscriptionUpdateDisabled = !canUpdateSubscription || vpn.busy;
  const isDisconnecting = vpn.status === 'disconnecting';
  const disconnectActionVisible = canDisconnect || isDisconnecting;
  const showEditor = !summary || editing;
  const selectedNode = summary?.nodes[summary.selectedNodeIndex];
  const saveDisabled = !url.trim() || subscriptionUpdateDisabled;
  const connectionDisabled =
    !selectedNode || vpn.busy || isDisconnecting || (editing && !canDisconnect);

  const paste = async () => {
    try {
      const value = await Clipboard.getStringAsync();
      if (value) setDraftURL(value.trim());
    } catch (error) {
      Alert.alert('Could not paste URL', errorMessage(error));
    }
  };

  const save = async () => {
    if (saveDisabled) return;
    const saved = await vpn.save(url);
    if (saved) {
      setEditing(false);
      setDraftURL(null);
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
    }
  };

  const toggle = async () => {
    void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    if (canDisconnect) await vpn.disconnect();
    else await vpn.connect();
  };

  const changeSubscription = () => {
    setDraftURL(vpn.url ?? '');
    setEditing(true);
  };

  const chooseNode = () => {
    if (!summary || summary.nodes.length < 2 || subscriptionUpdateDisabled) return;
    const cancelButtonIndex = summary.nodes.length;
    ActionSheetIOS.showActionSheetWithOptions(
      {
        title: 'Choose node',
        message: 'This node will be used the next time you connect.',
        options: [
          ...summary.nodes.map(
            (node, index) =>
              `${index === summary.selectedNodeIndex ? '✓ ' : ''}${node.name} — ${node.provider}/${node.transport}`
          ),
          'Cancel',
        ],
        cancelButtonIndex,
      },
      index => {
        if (index !== cancelButtonIndex && index !== summary.selectedNodeIndex) {
          void vpn.selectNode(index);
        }
      }
    );
  };

  if (vpn.loading) {
    return (
      <View style={styles.centered}>
        <ActivityIndicator />
      </View>
    );
  }

  return (
    <>
      <Stack.Toolbar placement="right">
        <Stack.Toolbar.Button
          accessibilityLabel="Open logs"
          icon="doc.text.magnifyingglass"
          onPress={() => router.push('/logs')}
          tintColor={colors.blue}
        />
      </Stack.Toolbar>
      <KeyboardAvoidingView style={styles.flex} behavior="padding">
        <ScrollView
          contentInsetAdjustmentBehavior="automatic"
          keyboardDismissMode="interactive"
          keyboardShouldPersistTaps="handled"
          contentContainerStyle={styles.content}
        >
          <View style={styles.statusBlock}>
            <View
              accessible
              accessibilityLabel={`${status.title}. ${status.detail}`}
              accessibilityRole="summary"
              style={styles.statusSummary}
            >
              <SymbolView
                accessibilityElementsHidden
                name={status.symbol}
                size={38}
                tintColor={status.color}
                weight="semibold"
                style={styles.statusSymbol}
              />
              <Text style={styles.statusTitle}>{status.title}</Text>
              <Text style={styles.statusDetail}>{status.detail}</Text>
            </View>
            {vpn.status === 'connected' ? <PublicIPAddress /> : null}
          </View>

          {showEditor ? (
            <View style={styles.card}>
              <Text
                adjustsFontSizeToFit
                minimumFontScale={0.7}
                numberOfLines={1}
                style={styles.cardTitle}
              >
                {vpn.summary ? 'Replace subscription' : 'Subscription'}
              </Text>
              <Text style={styles.cardHint}>
                One HTTPS URL in the official olcRTC sub.md format.
              </Text>
              <View style={styles.inputRow}>
                <TextInput
                  accessibilityLabel="Subscription URL"
                  autoCapitalize="none"
                  autoCorrect={false}
                  editable={!subscriptionUpdateDisabled}
                  enablesReturnKeyAutomatically
                  inputMode="url"
                  keyboardType="url"
                  onChangeText={setDraftURL}
                  onSubmitEditing={save}
                  placeholder="https://example.org/sub"
                  placeholderTextColor={colors.secondaryLabel}
                  returnKeyType="go"
                  selectionColor={colors.blue}
                  style={styles.input}
                  value={url}
                />
                <Pressable
                  accessibilityRole="button"
                  disabled={subscriptionUpdateDisabled}
                  hitSlop={8}
                  onPress={paste}
                  style={[styles.inlineButton, subscriptionUpdateDisabled && styles.disabled]}
                >
                  <Text style={styles.inlineButtonText}>Paste</Text>
                </Pressable>
              </View>
              <View style={styles.editorActions}>
                {summary ? (
                  <Pressable
                    accessibilityRole="button"
                    disabled={vpn.busy}
                    onPress={() => {
                      setEditing(false);
                      setDraftURL(null);
                    }}
                    style={styles.secondaryButton}
                  >
                    <Text style={styles.secondaryButtonText}>Cancel</Text>
                  </Pressable>
                ) : null}
                <Pressable
                  accessibilityLabel="Save subscription"
                  accessibilityRole="button"
                  accessibilityState={{
                    busy: vpn.busy,
                    disabled: saveDisabled,
                  }}
                  disabled={saveDisabled}
                  onPress={save}
                  style={({ pressed }) => [
                    styles.saveButton,
                    saveDisabled && styles.disabled,
                    pressed && styles.pressed,
                  ]}
                >
                  {vpn.busy ? <ActivityIndicator color="white" size="small" /> : null}
                  <Text style={styles.saveButtonText}>Save</Text>
                </Pressable>
              </View>
            </View>
          ) : summary ? (
            <View style={styles.card}>
              <View style={styles.subscriptionHeader}>
                <View style={styles.flex}>
                  <Text style={styles.cardTitle} numberOfLines={1}>
                    {summary.name}
                  </Text>
                  <Text style={styles.cardHint}>
                    {nodeCount(summary.nodes.length)} · Updated{' '}
                    {formatUpdatedAt(summary.refreshedAt)}
                  </Text>
                </View>
              </View>
              <View style={styles.divider} />
              <Pressable
                accessibilityHint={
                  summary.nodes.length > 1
                    ? 'Chooses the node used for the next connection.'
                    : undefined
                }
                accessibilityLabel={
                  selectedNode ? `Selected node: ${selectedNode.name}` : 'Selected node'
                }
                accessibilityRole="button"
                accessibilityState={{
                  disabled: summary.nodes.length < 2 || subscriptionUpdateDisabled,
                }}
                disabled={summary.nodes.length < 2 || subscriptionUpdateDisabled}
                onPress={chooseNode}
                style={({ pressed }) => [styles.nodeSelector, pressed && styles.pressed]}
              >
                <View style={styles.flex}>
                  <Text style={styles.nodeLabel}>Node</Text>
                  <Text style={styles.nodeName} numberOfLines={1}>
                    {selectedNode?.name ?? 'Unavailable'}
                  </Text>
                  {selectedNode ? (
                    <Text style={styles.nodeDetail} numberOfLines={1}>
                      {selectedNode.provider} · {selectedNode.transport}
                    </Text>
                  ) : null}
                </View>
                {summary.nodes.length > 1 ? (
                  <Text style={styles.disclosureIndicator}>›</Text>
                ) : null}
              </Pressable>
              <View style={styles.divider} />
              <View style={styles.subscriptionActions}>
                <Pressable
                  accessibilityRole="button"
                  disabled={subscriptionUpdateDisabled}
                  onPress={changeSubscription}
                  style={({ pressed }) => [
                    styles.subscriptionAction,
                    subscriptionUpdateDisabled && styles.disabled,
                    pressed && styles.pressed,
                  ]}
                >
                  <Text style={styles.subscriptionActionText}>Replace URL</Text>
                </Pressable>
                <View style={styles.subscriptionActionDivider} />
                <Pressable
                  accessibilityRole="button"
                  disabled={subscriptionUpdateDisabled}
                  onPress={() => void vpn.refresh()}
                  style={({ pressed }) => [
                    styles.subscriptionAction,
                    subscriptionUpdateDisabled && styles.disabled,
                    pressed && styles.pressed,
                  ]}
                >
                  <Text style={styles.subscriptionActionText}>Refresh</Text>
                </Pressable>
              </View>
            </View>
          ) : null}

          {vpn.error ? (
            <Text accessibilityRole="alert" selectable style={styles.errorText}>
              {vpn.error}
            </Text>
          ) : null}
        </ScrollView>
        <View style={[styles.footer, { paddingBottom: Math.max(insets.bottom, spacing.x3) }]}>
          <Pressable
            accessibilityLabel={disconnectActionVisible ? 'Disconnect' : 'Connect'}
            accessibilityRole="button"
            accessibilityState={{ busy: isDisconnecting, disabled: connectionDisabled }}
            disabled={connectionDisabled}
            onPress={toggle}
            style={({ pressed }) => [
              styles.connectionButton,
              { backgroundColor: disconnectActionVisible ? colors.red : colors.blue },
              connectionDisabled && styles.disabled,
              pressed && styles.connectionPressed,
            ]}
          >
            {isDisconnecting ? <ActivityIndicator color="white" size="small" /> : null}
            <Text style={styles.connectionButtonText}>
              {isDisconnecting ? 'Disconnecting' : canDisconnect ? 'Disconnect' : 'Connect'}
            </Text>
          </Pressable>
        </View>
      </KeyboardAvoidingView>
    </>
  );
}

type PublicIPState =
  { status: 'loading' } | { status: 'success'; value: PublicIP } | { status: 'error' };

function PublicIPAddress() {
  const [attempt, setAttempt] = useState(0);
  const [state, setState] = useState<PublicIPState>({ status: 'loading' });

  useEffect(() => {
    let active = true;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), publicIPRequestTimeoutMilliseconds);

    void fetchPublicIP(controller.signal)
      .then(value => {
        if (active) setState({ status: 'success', value });
      })
      .catch(() => {
        if (active) setState({ status: 'error' });
      })
      .finally(() => clearTimeout(timeout));

    return () => {
      active = false;
      clearTimeout(timeout);
      controller.abort();
    };
  }, [attempt]);

  if (state.status === 'loading') {
    return (
      <View
        accessible
        accessibilityLabel="Checking public IP"
        accessibilityRole="progressbar"
        style={styles.publicIPRow}
      >
        <ActivityIndicator size="small" />
        <Text style={styles.publicIPStatus}>Checking public IP…</Text>
      </View>
    );
  }

  if (state.status === 'error') {
    return (
      <Pressable
        accessibilityRole="button"
        onPress={() => {
          setState({ status: 'loading' });
          setAttempt(value => value + 1);
        }}
        style={({ pressed }) => [styles.publicIPRetry, pressed && styles.pressed]}
      >
        <Text style={styles.publicIPRetryText}>Retry IP check</Text>
      </Pressable>
    );
  }

  return (
    <Text
      accessibilityLabel={`Public IP ${state.value.address}, country ${state.value.country}`}
      selectable
      style={styles.publicIPValue}
    >
      {state.value.address} · {state.value.country}
    </Text>
  );
}

function statusPresentation(status: VPNStatus): {
  title: string;
  detail: string;
  color: ColorValue;
  symbol: SFSymbol;
} {
  switch (status) {
    case 'connected':
      return {
        title: 'Connected',
        detail: 'Packet tunnel active',
        color: colors.green,
        symbol: 'checkmark.circle.fill',
      };
    case 'reasserting':
      return {
        title: 'Reconnecting',
        detail: 'Restoring the selected node',
        color: colors.orange,
        symbol: 'arrow.clockwise.circle.fill',
      };
    case 'connecting':
      return {
        title: 'Connecting',
        detail: 'Starting the packet tunnel',
        color: colors.orange,
        symbol: 'ellipsis.circle.fill',
      };
    case 'disconnecting':
      return {
        title: 'Disconnecting',
        detail: 'Stopping the packet tunnel',
        color: colors.orange,
        symbol: 'stop.circle.fill',
      };
    case 'invalid':
      return {
        title: 'Needs setup',
        detail: 'Add a subscription to connect',
        color: colors.secondaryLabel,
        symbol: 'link.badge.plus',
      };
    case 'disconnected':
      return {
        title: 'Disconnected',
        detail: 'Using your regular internet connection',
        color: colors.secondaryLabel,
        symbol: 'circle.slash.fill',
      };
  }
}

function nodeCount(count: number) {
  return `${count} ${count === 1 ? 'node' : 'nodes'}`;
}

function formatUpdatedAt(timestamp: number) {
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(
    timestamp
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.background,
  },
  content: { paddingHorizontal: spacing.x4, paddingBottom: spacing.x4, gap: spacing.x4 },
  statusBlock: { alignItems: 'center', paddingTop: spacing.x8, paddingBottom: spacing.x4 },
  statusSummary: { alignItems: 'center' },
  statusSymbol: { marginBottom: spacing.x3 },
  statusTitle: {
    color: colors.label,
    fontSize: 28,
    lineHeight: 34,
    fontWeight: '700',
    letterSpacing: -0.5,
  },
  statusDetail: {
    color: colors.secondaryLabel,
    fontSize: 15,
    lineHeight: 21,
    marginTop: spacing.x1,
    textAlign: 'center',
  },
  publicIPRow: {
    minHeight: 44,
    marginTop: spacing.x1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.x2,
  },
  publicIPStatus: { color: colors.secondaryLabel, fontSize: 14, lineHeight: 20 },
  publicIPValue: {
    minHeight: 44,
    marginTop: spacing.x1,
    color: colors.label,
    fontFamily: 'ui-monospace',
    fontSize: 14,
    lineHeight: 44,
    fontVariant: ['tabular-nums'],
  },
  publicIPRetry: {
    minHeight: 44,
    marginTop: spacing.x1,
    justifyContent: 'center',
    paddingHorizontal: spacing.x2,
  },
  publicIPRetryText: { color: colors.blue, fontSize: 14, lineHeight: 20, fontWeight: '600' },
  card: {
    backgroundColor: colors.surface,
    borderRadius: radii.card,
    padding: spacing.x4,
    gap: spacing.x3,
  },
  cardTitle: { color: colors.label, fontSize: 17, lineHeight: 22, fontWeight: '600' },
  cardHint: { color: colors.secondaryLabel, fontSize: 14, lineHeight: 19, marginTop: 2 },
  inputRow: {
    minHeight: 48,
    flexDirection: 'row',
    alignItems: 'center',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.separator,
    borderRadius: 10,
    overflow: 'hidden',
  },
  input: {
    flex: 1,
    minHeight: 48,
    paddingHorizontal: spacing.x3,
    color: colors.label,
    fontSize: 16,
  },
  inlineButton: {
    minWidth: 60,
    minHeight: 44,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.x3,
  },
  inlineButtonText: { color: colors.blue, fontSize: 15, fontWeight: '500' },
  editorActions: { flexDirection: 'row', justifyContent: 'flex-end', gap: spacing.x2 },
  secondaryButton: { minHeight: 44, justifyContent: 'center', paddingHorizontal: spacing.x4 },
  secondaryButtonText: { color: colors.blue, fontSize: 16, fontWeight: '600' },
  saveButton: {
    minWidth: 96,
    minHeight: 44,
    borderRadius: radii.button,
    backgroundColor: colors.blue,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row',
    gap: spacing.x2,
    paddingHorizontal: spacing.x4,
  },
  saveButtonText: { color: 'white', fontSize: 16, fontWeight: '600' },
  subscriptionHeader: { flexDirection: 'row', alignItems: 'center', gap: spacing.x3 },
  divider: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: colors.separator,
    marginHorizontal: -spacing.x4,
  },
  nodeSelector: { minHeight: 64, flexDirection: 'row', alignItems: 'center', gap: spacing.x3 },
  nodeLabel: { color: colors.secondaryLabel, fontSize: 12, lineHeight: 16, fontWeight: '500' },
  nodeName: { color: colors.label, fontSize: 16, lineHeight: 21, fontWeight: '600' },
  nodeDetail: { color: colors.secondaryLabel, fontSize: 13, lineHeight: 18 },
  disclosureIndicator: {
    color: colors.secondaryLabel,
    fontSize: 28,
    lineHeight: 30,
    fontWeight: '300',
  },
  subscriptionActions: { minHeight: 44, flexDirection: 'row', alignItems: 'center' },
  subscriptionAction: { flex: 1, minHeight: 44, alignItems: 'center', justifyContent: 'center' },
  subscriptionActionText: { color: colors.blue, fontSize: 16, lineHeight: 20, fontWeight: '500' },
  subscriptionActionDivider: {
    width: StyleSheet.hairlineWidth,
    height: 24,
    backgroundColor: colors.separator,
  },
  errorText: { color: colors.red, fontSize: 14, lineHeight: 20, paddingHorizontal: spacing.x2 },
  footer: {
    paddingHorizontal: spacing.x4,
    paddingTop: spacing.x2,
    backgroundColor: colors.background,
  },
  connectionButton: {
    minHeight: 54,
    borderRadius: radii.button,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row',
    gap: spacing.x2,
  },
  connectionButtonText: { color: 'white', fontSize: 18, lineHeight: 22, fontWeight: '700' },
  connectionPressed: { transform: [{ scale: 0.985 }], opacity: 0.88 },
  disabled: { opacity: 0.45 },
  pressed: { opacity: 0.55 },
});
