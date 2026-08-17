#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$project_dir/build"
archive_path="$build_dir/OneLastChance.xcarchive"
distribution_dir="$project_dir/dist"
ipa_path="$distribution_dir/OneLastChance-unsigned.ipa"

for command_name in bun node pod xcodebuild; do
  command -v "$command_name" >/dev/null || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

cd "$project_dir"
"$project_dir/scripts/build-runtime.sh"

echo "Generating the iOS project"
bun expo prebuild --platform ios --clean --no-install
(
  cd ios
  pod install
)

workspace_path="$(find "$project_dir/ios" -maxdepth 1 -type d -name '*.xcworkspace' -print -quit)"
if [[ -z "$workspace_path" ]]; then
  echo "Expo prebuild did not create an Xcode workspace" >&2
  exit 1
fi
scheme="$(basename "$workspace_path" .xcworkspace)"

for entitlements_path in \
  "$project_dir/ios/$scheme/$scheme.entitlements" \
  "$project_dir/ios/.targets/networkpackettunnel/generated.entitlements"; do
  if [[ ! -f "$entitlements_path" ]]; then
    echo "Missing generated entitlements: $entitlements_path" >&2
    exit 1
  fi
  capability="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.networking.networkextension:0' "$entitlements_path")"
  if [[ "$capability" != "packet-tunnel-provider" ]]; then
    echo "Missing Packet Tunnel entitlement in $entitlements_path" >&2
    exit 1
  fi
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$entitlements_path" >/dev/null 2>&1; then
    echo "Unsupported App Group entitlement in $entitlements_path" >&2
    exit 1
  fi
done

mkdir -p "$build_dir" "$distribution_dir"
rm -rf "$archive_path"
echo "Archiving $scheme without code signing"
xcodebuild \
  -quiet \
  -workspace "$workspace_path" \
  -scheme "$scheme" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  archive \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  DEVELOPMENT_TEAM=''

application_path="$(find "$archive_path/Products/Applications" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$application_path" ]]; then
  echo "Xcode archive contains no application" >&2
  exit 1
fi

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-last-chance-ipa.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
mkdir -p "$stage_dir/Payload"
staged_application_path="$stage_dir/Payload/$(basename "$application_path")"
/usr/bin/ditto "$application_path" "$staged_application_path"
find "$stage_dir/Payload" -type d -name _CodeSignature -prune -exec rm -rf {} +
find "$stage_dir/Payload" -type f -name embedded.mobileprovision -delete
find "$staged_application_path/PlugIns" -type f -name pods.rb -delete

rm -f "$ipa_path"
(
  cd "$stage_dir"
  /usr/bin/zip -qry "$ipa_path" Payload
)

"$project_dir/scripts/verify-unsigned-ipa.sh" "$ipa_path"
echo "Unsigned IPA: $ipa_path"
