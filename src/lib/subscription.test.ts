/// <reference types="node" />

import assert from 'node:assert/strict';
import test from 'node:test';

import { parseSubscription, validateSubscriptionURL } from './subscription';

const key = 'a'.repeat(64);

test('parses official v1 global and nearest-node fields', () => {
  const parsed = parseSubscription(
    `#name: Freedom\n#update: 1778011200\n#refresh: 10m\n\n` +
      `olcrtc://wbstream?vp8channel<vp8-fps=60&vp8-batch=32>@room-01#${key}$fallback\n` +
      `##name: RU-1\n##comment: primary\n\n` +
      `olcrtc://jitsi?datachannel@https://meet.example.org/room#${key}$backup\n` +
      `##name: DE-2`
  );

  assert.equal(parsed.name, 'Freedom');
  assert.equal(parsed.nodes.length, 2);
  assert.equal(parsed.nodes[0].name, 'RU-1');
  assert.equal(parsed.nodes[0].vp8FPS, 60);
  assert.equal(parsed.nodes[0].vp8BatchSize, 32);
  assert.equal(parsed.nodes[1].name, 'DE-2');
  assert.equal(parsed.nodes[1].room, 'https://meet.example.org/room');
});

test('filters unavailable nodes while preserving supported nodes and their nearest names', () => {
  const parsed = parseSubscription(
    `\uFEFF#name: Filtered\r\n# arbitrary comment\r\n\r\n` +
      `olcrtc://telemost?videochannel<video-w=1080>@ignored#${key}\r\n` +
      `##name: Ignored\r\n` +
      `olcrtc://unsupported?datachannel@ignored#${key}\r\n` +
      `olcrtc://telemost?datachannel@ignored#${key}\r\n` +
      `olcrtc://wbstream?datachannel@ignored#${key}\r\n` +
      `olcrtc://jitsi?datachannel@kept#${key}\r\n` +
      `##name: Kept\r\n`
  );
  assert.equal(parsed.name, 'Filtered');
  assert.equal(parsed.nodes.length, 1);
  assert.equal(parsed.nodes[0].name, 'Kept');
  assert.equal(parsed.nodes[0].room, 'kept');
});

test('accepts a subscription containing only unavailable nodes as zero nodes', () => {
  const parsed = parseSubscription(
    `#name: Unavailable\n` +
      `olcrtc://jitsi?seichannel@ignored#${key}\n` +
      `olcrtc://telemost?videochannel@ignored#${key}`
  );
  assert.equal(parsed.name, 'Unavailable');
  assert.deepEqual(parsed.nodes, []);
});

test('rejects malformed keys, duplicate params, and transport-specific params', () => {
  assert.throws(() => parseSubscription('olcrtc://jitsi?datachannel@room#abcd'), /64 hexadecimal/);
  assert.throws(
    () => parseSubscription(`olcrtc://jitsi?vp8channel<vp8-fps=30&vp8-fps=60>@room#${key}`),
    /duplicated/
  );
  assert.throws(
    () => parseSubscription(`olcrtc://jitsi?datachannel<fps=30>@room#${key}`),
    /does not belong/
  );
  assert.throws(
    () => parseSubscription(`olcrtc://wbstream?vp8channel<vp8-batch=65>@room#${key}`),
    /between 1 and 64/
  );
});

test('accepts an empty subscription and caps subscription size', () => {
  assert.deepEqual(parseSubscription('#name: empty').nodes, []);
  assert.throws(() => parseSubscription(' '.repeat(1024 * 1024 + 1)), /larger than 1 MB/);
});

test('accepts 128 supported nodes and rejects the 129th', () => {
  const node = `olcrtc://jitsi?datachannel@room#${key}`;
  assert.equal(parseSubscription(Array(128).fill(node).join('\n')).nodes.length, 128);
  assert.throws(
    () => parseSubscription(Array(129).fill(node).join('\n')),
    /more than 128 supported nodes/
  );
});

test('normalizes HTTPS subscription URLs and rejects insecure URLs', () => {
  assert.equal(validateSubscriptionURL(' https://example.org/sub '), 'https://example.org/sub');
  assert.throws(() => validateSubscriptionURL('http://example.org/sub'), /must use HTTPS/);
  assert.throws(() => validateSubscriptionURL('nope'), /valid subscription URL/);
});
