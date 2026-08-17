import * as Haptics from 'expo-haptics';
import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState } from 'react-native';

import { errorMessage } from '@/lib/error';
import OlcRtcVpn, { type VPNConfigSummary, type VPNStatus } from '@/native/olcrtc-vpn';
import {
  installSubscription,
  refreshInstalledSubscription,
  savedSubscriptionURL,
} from '@/services/subscription';

export function useVPN() {
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<VPNStatus>('invalid');
  const [summary, setSummary] = useState<VPNConfigSummary | null>(null);
  const [url, setURL] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const running = useRef(false);

  useEffect(() => {
    let active = true;
    let statusVersion = 0;
    const listener = OlcRtcVpn.addListener('onStatusChange', ({ status: nextStatus }) => {
      if (!active) return;
      statusVersion += 1;
      setStatus(nextStatus);
    });

    const syncSnapshot = async () => {
      const requestedAtVersion = statusVersion;
      const snapshot = await OlcRtcVpn.getSnapshot();
      if (!active) return;
      if (requestedAtVersion === statusVersion) setStatus(snapshot.status);
      setSummary(snapshot.summary);
      setError(null);
    };

    const initialURL = savedSubscriptionURL().then(storedURL => {
      if (active) setURL(storedURL);
    });
    Promise.all([syncSnapshot(), initialURL])
      .catch(caught => {
        if (!active) return;
        setError(errorMessage(caught));
      })
      .finally(() => active && setLoading(false));

    const appStateListener = AppState.addEventListener('change', nextState => {
      if (nextState !== 'active') return;
      void syncSnapshot().catch(caught => active && setError(errorMessage(caught)));
    });

    return () => {
      active = false;
      listener.remove();
      appStateListener.remove();
    };
  }, []);

  const run = useCallback(async <T>(action: () => Promise<T>): Promise<T | undefined> => {
    if (running.current) return undefined;
    running.current = true;
    setBusy(true);
    setError(null);
    try {
      return await action();
    } catch (caught) {
      setError(errorMessage(caught));
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
      return undefined;
    } finally {
      running.current = false;
      setBusy(false);
    }
  }, []);

  const save = useCallback(
    async (nextURL: string) => {
      const result = await run(() => installSubscription(nextURL));
      if (!result) return false;
      setURL(result.url);
      setSummary(result.snapshot.summary);
      setStatus(result.snapshot.status);
      return true;
    },
    [run]
  );

  const refresh = useCallback(async () => {
    const result = await run(refreshInstalledSubscription);
    if (!result) return;
    setSummary(result.snapshot.summary);
    setStatus(result.snapshot.status);
    void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
  }, [run]);

  const connect = useCallback(async () => {
    await run(() => OlcRtcVpn.connect());
  }, [run]);

  const selectNode = useCallback(
    async (index: number) => {
      const snapshot = await run(() => OlcRtcVpn.selectNode(index));
      if (!snapshot) return;
      setSummary(snapshot.summary);
      setStatus(snapshot.status);
    },
    [run]
  );

  const disconnect = useCallback(async () => {
    await run(() => OlcRtcVpn.disconnect());
  }, [run]);

  return {
    loading,
    busy,
    status,
    summary,
    url,
    error,
    save,
    refresh,
    selectNode,
    connect,
    disconnect,
  };
}
