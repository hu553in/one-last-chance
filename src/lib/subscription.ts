const SUPPORTED_PROVIDERS = ['jitsi', 'telemost', 'wbstream'] as const;
const SUPPORTED_TRANSPORTS = ['datachannel', 'vp8channel'] as const;

type OlcRtcProvider = (typeof SUPPORTED_PROVIDERS)[number];
type OlcRtcTransport = (typeof SUPPORTED_TRANSPORTS)[number];

type OlcRtcNode = {
  name: string;
  provider: OlcRtcProvider;
  transport: OlcRtcTransport;
  room: string;
  key: string;
  vp8FPS: number;
  vp8BatchSize: number;
};

export type ParsedSubscription = {
  name: string;
  nodes: OlcRtcNode[];
  refreshedAt: number;
};

export const MAX_SUBSCRIPTION_BYTES = 1024 * 1024;
const MAX_NODES = 128;
const keyPattern = /^[0-9a-f]{64}$/i;

class SubscriptionParseError extends Error {
  constructor(
    message: string,
    readonly line?: number
  ) {
    super(line ? `Line ${line}: ${message}` : message);
    this.name = 'SubscriptionParseError';
  }
}

type PendingNode = {
  node: OlcRtcNode;
  name?: string;
};

export function parseSubscription(rawValue: string, sourceURL?: string): ParsedSubscription {
  if (new TextEncoder().encode(rawValue).byteLength > MAX_SUBSCRIPTION_BYTES) {
    throw new SubscriptionParseError('Subscription is larger than 1 MB.');
  }

  const globalFields: Record<string, string> = {};
  const nodes: PendingNode[] = [];
  let currentNode: PendingNode | undefined;

  rawValue
    .replace(/^\uFEFF/, '')
    .split(/\r?\n/)
    .forEach((rawLine, index) => {
      const line = rawLine.trim();
      const lineNumber = index + 1;
      if (!line) return;

      if (/^olcrtc:\/\//i.test(line)) {
        const node = parseOlcRtcUri(line, lineNumber);
        if (!node) {
          currentNode = undefined;
          return;
        }
        if (nodes.length >= MAX_NODES) {
          throw new SubscriptionParseError(
            `Subscription has more than ${MAX_NODES} supported nodes.`,
            lineNumber
          );
        }
        currentNode = { node };
        nodes.push(currentNode);
        return;
      }

      if (line.startsWith('##')) {
        const field = parseField(line.slice(2));
        if (currentNode && field?.key === 'name') currentNode.name = nonEmpty(field.value);
        return;
      }

      if (line.startsWith('#')) {
        const field = parseField(line.slice(1));
        if (field) globalFields[field.key] = field.value;
      }
    });

  const name = nonEmpty(globalFields.name) ?? sourceName(sourceURL) ?? 'olcRTC subscription';
  return {
    name,
    refreshedAt: Date.now(),
    nodes: nodes.map(({ node, name }) => ({
      ...node,
      name: name ?? node.name,
    })),
  };
}

export function validateSubscriptionURL(rawValue: string): string {
  const value = rawValue.trim();
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error('Enter a valid subscription URL.');
  }
  if (url.protocol !== 'https:') {
    throw new Error('The subscription URL must use HTTPS.');
  }
  return url.toString();
}

function parseOlcRtcUri(value: string, line: number): OlcRtcNode | undefined {
  const body = value.slice('olcrtc://'.length);
  const question = body.indexOf('?');
  if (question <= 0) throw new SubscriptionParseError('Provider or transport is missing.', line);

  const providerValue = body.slice(0, question).trim().toLowerCase();
  const provider = SUPPORTED_PROVIDERS.find(item => item === providerValue);
  if (!provider) return undefined;

  const at = body.indexOf('@', question + 1);
  const hash = body.indexOf('#', at + 1);
  if (at <= question + 1 || hash <= at + 1) {
    throw new SubscriptionParseError('Expected olcrtc://provider?transport@room#key.', line);
  }

  const transportValue = body.slice(question + 1, at).trim();
  const transportCandidate = transportValue.split('<', 1)[0].trim().toLowerCase();
  const transport = SUPPORTED_TRANSPORTS.find(item => item === transportCandidate);
  if (!transport) return undefined;
  if (transport === 'datachannel' && provider !== 'jitsi') return undefined;

  const { name: transportName, params } = parseTransport(transportValue, line);
  if (transportName !== transport) {
    throw new SubscriptionParseError(`Invalid transport “${transportName}”.`, line);
  }

  const room = body.slice(at + 1, hash).trim();
  if (!room) throw new SubscriptionParseError('Room ID is missing.', line);

  const fragment = body.slice(hash + 1);
  const dollar = fragment.indexOf('$');
  const key = (dollar < 0 ? fragment : fragment.slice(0, dollar)).trim();
  const comment = dollar < 0 ? undefined : nonEmpty(fragment.slice(dollar + 1));
  if (!keyPattern.test(key)) {
    throw new SubscriptionParseError(
      'Encryption key must be exactly 64 hexadecimal characters.',
      line
    );
  }

  const allowed = new Set(transportParameterNames(transport));
  for (const param of params.keys()) {
    if (!allowed.has(param)) {
      throw new SubscriptionParseError(
        `Parameter “${param}” does not belong to ${transport}.`,
        line
      );
    }
  }

  const node: OlcRtcNode = {
    name: comment ?? `${provider} ${room}`,
    provider,
    transport,
    room,
    key: key.toLowerCase(),
    vp8FPS: integerParam(params, 'vp8-fps', 30, 1, 120, line),
    vp8BatchSize: integerParam(params, 'vp8-batch', 64, 1, 64, line),
  };
  return node;
}

function parseTransport(
  value: string,
  line: number
): { name: string; params: Map<string, string> } {
  const open = value.indexOf('<');
  if (open < 0) return { name: value.toLowerCase(), params: new Map() };
  if (!value.endsWith('>') || open === 0) {
    throw new SubscriptionParseError('Transport parameters must be enclosed in <...>.', line);
  }
  const name = value.slice(0, open).trim().toLowerCase();
  const payload = value.slice(open + 1, -1);
  const params = new Map<string, string>();
  if (!payload) return { name, params };

  for (const pair of payload.split('&')) {
    const separator = pair.indexOf('=');
    if (separator <= 0)
      throw new SubscriptionParseError(`Invalid transport parameter “${pair}”.`, line);
    const key = pair.slice(0, separator).trim().toLowerCase();
    const paramValue = pair.slice(separator + 1).trim();
    if (!paramValue)
      throw new SubscriptionParseError(`Transport parameter “${key}” is empty.`, line);
    if (params.has(key))
      throw new SubscriptionParseError(`Transport parameter “${key}” is duplicated.`, line);
    params.set(key, paramValue);
  }
  return { name, params };
}

function transportParameterNames(transport: OlcRtcTransport): readonly string[] {
  switch (transport) {
    case 'datachannel':
      return [];
    case 'vp8channel':
      return ['vp8-fps', 'vp8-batch'];
  }
}

function integerParam(
  params: Map<string, string>,
  key: string,
  fallback: number,
  minimum: number,
  maximum: number,
  line: number
): number {
  const raw = params.get(key);
  if (raw === undefined) return fallback;
  if (!/^-?\d+$/.test(raw))
    throw new SubscriptionParseError(`Parameter “${key}” must be an integer.`, line);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new SubscriptionParseError(
      `Parameter “${key}” must be between ${minimum} and ${maximum}.`,
      line
    );
  }
  return value;
}

function parseField(value: string): { key: string; value: string } | undefined {
  const separator = value.indexOf(':');
  if (separator < 0) return undefined;
  const key = value.slice(0, separator).trim().toLowerCase();
  if (!key) return undefined;
  return { key, value: value.slice(separator + 1).trim() };
}

function nonEmpty(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function sourceName(sourceURL: string | undefined): string | undefined {
  if (!sourceURL) return undefined;
  try {
    return new URL(sourceURL).hostname || undefined;
  } catch {
    return undefined;
  }
}
