/// <reference types="node" />

import assert from 'node:assert/strict';
import test from 'node:test';

import { parseIPCountryResponse, parsePublicIPv4Response } from './public-ip';

test('accepts a valid IPv4 response', () => {
  assert.equal(parsePublicIPv4Response({ ip: '203.0.113.42' }), '203.0.113.42');
});

test('rejects malformed public IPv4 responses', () => {
  for (const value of [
    null,
    {},
    { ip: 42 },
    { ip: '127.1' },
    { ip: '192.168.001.1' },
    { ip: '2001:db8::1' },
    { ip: '256.0.0.1' },
  ]) {
    assert.throws(() => parsePublicIPv4Response(value));
  }
});

test('accepts only a matching IP with an ISO country code', () => {
  assert.equal(parseIPCountryResponse({ ip: '203.0.113.42', country: 'LV' }, '203.0.113.42'), 'LV');
  assert.throws(() =>
    parseIPCountryResponse({ ip: '203.0.113.43', country: 'LV' }, '203.0.113.42')
  );
  assert.throws(() =>
    parseIPCountryResponse({ ip: '203.0.113.42', country: null }, '203.0.113.42')
  );
  assert.throws(() =>
    parseIPCountryResponse({ ip: '203.0.113.42', country: 'latvia' }, '203.0.113.42')
  );
});
