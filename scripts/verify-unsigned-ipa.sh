#!/usr/bin/env bash
set -euo pipefail

ipa_path="${1:-}"
if [[ -z "$ipa_path" || ! -f "$ipa_path" ]]; then
  echo "Usage: $0 /path/to/OneLastChance-unsigned.ipa" >&2
  exit 1
fi

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-last-chance-ipa-check.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
/usr/bin/unzip -q "$ipa_path" -d "$temporary_dir"

applications=("$temporary_dir"/Payload/*.app)
if [[ ${#applications[@]} -ne 1 || ! -d "${applications[0]}" ]]; then
  echo "Expected exactly one .app in Payload" >&2
  exit 1
fi
app_path="${applications[0]}"

extensions=("$app_path"/PlugIns/*.appex)
if [[ ${#extensions[@]} -ne 1 || ! -d "${extensions[0]}" ]]; then
  echo "Expected exactly one Packet Tunnel .appex" >&2
  exit 1
fi
extension_path="${extensions[0]}"
if find "$extension_path" -type f -name pods.rb -print -quit | grep -q .; then
  echo "Packet Tunnel extension unexpectedly contains CocoaPods source configuration" >&2
  exit 1
fi

app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
extension_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$extension_path/Info.plist")"
if [[ "$app_identifier" != "com.github.hu553in.onelastchance" ]]; then
  echo "Unexpected app bundle identifier: $app_identifier" >&2
  exit 1
fi
if [[ "$extension_identifier" != "com.github.hu553in.onelastchance.packet-tunnel" ]]; then
  echo "Unexpected extension bundle identifier: $extension_identifier" >&2
  exit 1
fi

extension_point="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$extension_path/Info.plist")"
if [[ "$extension_point" != "com.apple.networkextension.packet-tunnel" ]]; then
  echo "Unexpected extension point: $extension_point" >&2
  exit 1
fi

principal_class="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPrincipalClass' "$extension_path/Info.plist")"
if [[ "$principal_class" != *.PacketTunnelProvider ]]; then
  echo "Unexpected Packet Tunnel principal class: $principal_class" >&2
  exit 1
fi

app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Info.plist")"
extension_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$extension_path/Info.plist")"
if [[ "$app_build" != "$extension_build" ]]; then
  echo "App and extension build numbers differ: $app_build != $extension_build" >&2
  exit 1
fi

app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Info.plist")"
extension_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extension_path/Info.plist")"
if [[ "$app_version" != "$extension_version" ]]; then
  echo "App and extension versions differ: $app_version != $extension_version" >&2
  exit 1
fi

for bundle in "$app_path" "$extension_path"; do
  minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$bundle/Info.plist")"
  if [[ "$minimum_os" != "16.4" ]]; then
    echo "Expected iOS 16.4 minimum in $bundle, found: $minimum_os" >&2
    exit 1
  fi
done

app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Info.plist")"
extension_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$extension_path/Info.plist")"
for executable in "$app_path/$app_executable" "$extension_path/$extension_executable"; do
  architectures="$(/usr/bin/lipo -archs "$executable")"
  if [[ "$architectures" != "arm64" ]]; then
    echo "Expected only arm64 in $executable, found: $architectures" >&2
    exit 1
  fi
done

if find "$app_path" \( -name _CodeSignature -o -name embedded.mobileprovision \) -print -quit | grep -q .; then
  echo "IPA unexpectedly contains a signature or provisioning profile" >&2
  exit 1
fi
for bundle in "$app_path" "$extension_path"; do
  if /usr/bin/codesign --display "$bundle" >/dev/null 2>&1; then
    echo "IPA unexpectedly contains signed bundle: $bundle" >&2
    exit 1
  fi
done

/usr/bin/unzip -tq "$ipa_path" >/dev/null
echo "Verified unsigned arm64 IPA with Packet Tunnel extension: $ipa_path"
