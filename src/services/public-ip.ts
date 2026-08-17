import { fetch } from 'expo/fetch';

import { parseIPCountryResponse, parsePublicIPv4Response, type PublicIP } from '@/lib/public-ip';

// This hostname is IPv4-only, so the displayed address must traverse the app's IPv4-only tunnel.
const addressURL = 'https://api.ipify.org?format=json';
const countryURL = 'https://api.country.is';
const requestOptions = {
  credentials: 'omit',
  headers: {
    Accept: 'application/json',
  },
  redirect: 'error',
} as const;

export async function fetchPublicIP(signal: AbortSignal): Promise<PublicIP> {
  const addressResponse = await fetch(`${addressURL}&request=${Date.now()}`, {
    ...requestOptions,
    signal,
  });
  if (!addressResponse.ok) {
    throw new Error(`Public IP service returned HTTP ${addressResponse.status}.`);
  }
  const address = parsePublicIPv4Response(await addressResponse.json());

  const countryResponse = await fetch(`${countryURL}/${address}`, {
    ...requestOptions,
    signal,
  });
  if (!countryResponse.ok) {
    throw new Error(`IP country service returned HTTP ${countryResponse.status}.`);
  }
  const country = parseIPCountryResponse(await countryResponse.json(), address);
  return { address, country };
}
