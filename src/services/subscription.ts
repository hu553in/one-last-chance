import * as SecureStore from 'expo-secure-store';
import { fetch } from 'expo/fetch';

import {
  MAX_SUBSCRIPTION_BYTES,
  parseSubscription,
  validateSubscriptionURL,
} from '@/lib/subscription';
import OlcRtcVpn from '@/native/olcrtc-vpn';

const subscriptionURLKey = 'subscription-url-v1';
const requestTimeoutMilliseconds = 20_000;

export async function savedSubscriptionURL() {
  return SecureStore.getItemAsync(subscriptionURLKey);
}

async function fetchSubscription(rawURL: string) {
  const url = validateSubscriptionURL(rawURL);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), requestTimeoutMilliseconds);

  try {
    const response = await fetch(url, {
      headers: {
        Accept: 'text/plain, text/markdown;q=0.9, */*;q=0.1',
        'Cache-Control': 'no-cache',
      },
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`Subscription server returned HTTP ${response.status}.`);
    if (new URL(response.url).protocol !== 'https:') {
      throw new Error('The subscription server redirected to an insecure URL.');
    }

    return { url, subscription: parseSubscription(await readSubscriptionBody(response), url) };
  } catch (error) {
    if (error instanceof Error && error.name === 'AbortError') {
      throw new Error('Subscription request timed out.');
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

async function readSubscriptionBody(response: Response) {
  const reader = response.body?.getReader();
  if (!reader) return '';

  const decoder = new TextDecoder();
  let receivedBytes = 0;
  let value = '';

  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) return value + decoder.decode();

      receivedBytes += chunk.value.byteLength;
      if (receivedBytes > MAX_SUBSCRIPTION_BYTES) {
        await reader.cancel().catch(() => undefined);
        throw new Error('Subscription is larger than 1 MB.');
      }
      value += decoder.decode(chunk.value, { stream: true });
    }
  } finally {
    reader.releaseLock();
  }
}

export async function installSubscription(rawURL: string) {
  const previousURL = await savedSubscriptionURL();
  const result = await fetchSubscription(rawURL);

  await SecureStore.setItemAsync(subscriptionURLKey, result.url);
  try {
    const snapshot = await OlcRtcVpn.configure(result.subscription);
    return { ...result, snapshot };
  } catch (error) {
    if (previousURL) await SecureStore.setItemAsync(subscriptionURLKey, previousURL);
    else await SecureStore.deleteItemAsync(subscriptionURLKey);
    throw error;
  }
}

export async function refreshInstalledSubscription() {
  const url = await savedSubscriptionURL();
  if (!url) throw new Error('No subscription URL is saved.');
  const result = await fetchSubscription(url);
  const snapshot = await OlcRtcVpn.configure(result.subscription);
  return { ...result, snapshot };
}
