import { requireNativeModule } from 'expo';

import type { ParsedSubscription } from '@/lib/subscription';

export type VPNStatus =
  'invalid' | 'disconnected' | 'connecting' | 'connected' | 'reasserting' | 'disconnecting';

export type VPNConfigSummary = {
  name: string;
  nodes: VPNNodeSummary[];
  selectedNodeIndex: number;
  refreshedAt: number;
};

type VPNNodeSummary = {
  name: string;
  provider: string;
  transport: string;
};

type VPNSnapshot = {
  status: VPNStatus;
  summary: VPNConfigSummary | null;
};

type StatusChangeEvent = {
  status: VPNStatus;
};

type OlcRtcVpnAPI = {
  getSnapshot(): Promise<VPNSnapshot>;
  configure(subscription: ParsedSubscription): Promise<VPNSnapshot>;
  selectNode(index: number): Promise<VPNSnapshot>;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  getLogs(): Promise<string>;
  clearLogs(): Promise<void>;
  addListener(
    eventName: 'onStatusChange',
    listener: (event: StatusChangeEvent) => void
  ): { remove(): void };
};

export default requireNativeModule<OlcRtcVpnAPI>('OlcRtcVpn');
