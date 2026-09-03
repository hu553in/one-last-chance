# One Last Chance

[![CI](https://github.com/hu553in/one-last-chance/actions/workflows/ci.yml/badge.svg)](https://github.com/hu553in/one-last-chance/actions/workflows/ci.yml)
[![GitHub go.mod Go version](https://img.shields.io/github/go-mod/go-version/hu553in/one-last-chance?filename=native%2Fone-last-chance-runtime%2Fgo.mod)](https://github.com/hu553in/one-last-chance/blob/main/native/one-last-chance-runtime/go.mod)

Minimal iPhone client for connecting to olcRTC through one subscription URL.

Paste an HTTPS `sub.md` URL, choose a compatible node, and connect. The Expo interface controls a
native iOS Packet Tunnel backed by the pinned [olcRTC](https://github.com/openlibrecommunity/olcrtc)
mobile runtime; SOCKS and routing details stay out of the user interface.

> [!IMPORTANT]
>
> One Last Chance supports iPhone with iOS 16.4 or newer. Android, iPad, macOS, landscape mode, and
> languages other than English are not supported.

> [!WARNING]
>
> The repository builds an unsigned IPA. You must sign it with a certificate and a provisioning
> profile that permit a Packet Tunnel Provider before installing it on an iPhone. A Simulator build
> cannot verify device-wide VPN traffic.

## Features

- One saved HTTPS subscription URL with manual refresh
- Manual selection of one supported node
- One-tap connect and disconnect through an iOS Packet Tunnel
- Public IPv4 address and country shown only while connected, with a refresh button
- Local lifecycle logs with Copy and Clear actions
- No account, analytics, telemetry, remote logs, or exposed SOCKS settings

## Requirements

- An iPhone running iOS 16.4 or newer
- An HTTPS subscription in the official olcRTC `sub.md` text format
- An olcRTC server compatible with the client revision documented below
- A signing method such as KravaSign, plus a certificate and provisioning profile with the Network
  Extension capability

The app does not install or administer an olcRTC server. Obtain the server and subscription URL
separately.

## Install the CI build

Every successful CI run uploads a ready-to-sign IPA:

1. Sign in to GitHub, open the
   [CI runs for `main`](https://github.com/hu553in/one-last-chance/actions/workflows/ci.yml?query=branch%3Amain),
   and select the latest successful run.
2. In **Artifacts**, download `one-last-chance-unsigned-<commit SHA>`.
3. Extract the outer archive downloaded from GitHub. It contains `OneLastChance-unsigned.ipa`; do
   not extract the IPA itself.
4. Sign the IPA with a certificate and provisioning profile that permit a Packet Tunnel Provider,
   and install it on the iPhone.

Artifacts are retained for 90 days and are tied to the exact commit shown in the workflow run.

## Usage

1. Sign and install the downloaded or locally built IPA.
2. Paste the HTTPS subscription URL and tap **Save**.
3. If the subscription contains several compatible nodes, choose the node to use.
4. Tap **Connect** and approve the iOS VPN configuration when prompted.
5. Use **Refresh** to fetch the saved URL again or **Replace URL** while disconnected.
6. Open **Logs** when connection diagnostics are needed.

The app keeps the previous working subscription if a refresh or URL replacement fails. Connecting
uses the saved configuration and does not fetch the subscription again.

## Supported nodes

| Provider   | `datachannel` | `vp8channel` |
| ---------- | ------------- | ------------ |
| `jitsi`    | Yes           | Yes          |
| `telemost` | No            | Yes          |
| `wbstream` | No            | Yes          |

`seichannel`, `videochannel`, unknown providers, unknown transports, and unsupported provider and
transport combinations are ignored. If every node is ignored, the subscription remains saved but
Connect stays unavailable. A malformed node that uses a supported combination rejects the entire
update instead of replacing the working configuration.

For `vp8channel`, `vp8-fps` defaults to 30 and accepts 1-120; `vp8-batch` defaults to 64 and accepts
1-64. Every supported node must contain a 64-character hexadecimal key.

Subscription limits:

- 20-second request timeout
- 1 MiB response body
- 128 supported nodes
- 512 KiB serialized iOS VPN configuration

Redirects are accepted only when the final URL is also HTTPS. Automatic, background, and periodic
subscription refresh are intentionally absent.

## Network behavior

- All regular IPv4 device traffic uses the Packet Tunnel; loopback traffic is excluded.
- The internal SOCKS5 listener runs on `127.0.0.1:21080` and is not configurable from the app.
- Tun2socks uses `198.18.0.2` for internal DNS handling and `100.64.0.0/10` for fake IP addresses.
- IPv6 tunneling, split tunneling, custom routes, custom DNS, kill switch, and iOS On Demand are not
  implemented.
- The selected node is not replaced automatically after a failure. There is no latency test,
  fastest-node selection, or failover.

Connected means the selected node started its local SOCKS listener, iOS accepted the IPv4 tunnel
settings, and packet forwarding survived the startup check. After that status is reached, the app
checks the public IPv4 address for display only. The check does not decide the VPN status or claim
broader internet reachability. The refresh button repeats the check, including after a failure, and
is disabled while a check is running. The previous IP and country stay visible during refresh; a
failed check replaces them with "IP unavailable".

## Privacy and logs

The subscription URL is stored in iOS Secure Store. The parsed VPN configuration, including node
keys, is stored in NetworkExtension preferences. Logs remain in local Application Support storage
for the app and extension; key-shaped values and common secret fields are redacted before writing.
The log view records lifecycle and runtime events, not packet contents.

While Connected, the app asks `api.ipify.org` for its public IPv4 address and passes that address to
`api.country.is` to obtain a country code. The result is neither persisted nor written to logs, and
any in-flight request is cancelled as soon as the VPN leaves Connected.

olcRTC receives a random UUID client identifier generated and stored by the extension. It is not
derived from the phone's hardware identifier.

## Compatibility

The client pins olcRTC commit
[`2f2db04c332667ac43ad0f9e99d76c1bd8bd3248`](https://github.com/openlibrecommunity/olcrtc/commit/2f2db04c332667ac43ad0f9e99d76c1bd8bd3248),
from before the incompatible resolver and global transport refactors. Servers must use a
wire-compatible revision. Compatibility with the current olcRTC `master` branch is not claimed.

Tun2SocksKit remains pinned to 5.14.4 because 5.16.0 enables a UDP path that is incompatible with
this runtime. Update either compatibility pin only after testing the matching server and a signed
build on a physical iPhone.

## Build from source

Building requires macOS, Xcode with an iOS SDK, Bun, Node.js, CocoaPods, and Go. Full local checks
also require Golangci-lint v2 and shfmt.

```bash
bun ci
bun run build
```

The build command:

1. Builds the pinned Go runtime as `OneLastChanceRuntime.xcframework`.
2. Generates a clean native iOS project with Expo Prebuild.
3. Installs the Packet Tunnel pods.
4. Creates an unsigned arm64 Release archive.
5. Removes signatures and provisioning profiles.
6. Verifies the app, extension, identifiers, minimum OS, architectures, and matching versions and
   build numbers.

The resulting artifact is `dist/OneLastChance-unsigned.ipa`.

## Development

```bash
bun dev
bun ios
bun run test
bun check
```

- `bun dev` starts Expo development tools.
- `bun ios` builds the Go runtime, then generates and runs the iOS app locally.
- `bun run test` runs TypeScript unit tests and Go runtime tests with the race detector.
- `bun check` runs formatting, linting, configuration validation, Expo Doctor, TypeScript, tests, Go
  checks, unused-code analysis, dependency audits, and the complete unsigned IPA build.
- `bun check:fix` applies formatter and linter fixes before running the same full gate.

The unsigned IPA and Simulator build validate packaging and native linking. Only a signed build on a
physical iPhone can validate NetworkExtension, device routes, and Safari traffic end to end.

## License

[MIT](LICENSE)
