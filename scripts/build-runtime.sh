#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_dir="$project_dir/native/one-last-chance-runtime"
frameworks_dir="$project_dir/native/olcrtc-tunnel-core/Frameworks"
framework_path="$frameworks_dir/OneLastChanceRuntime.xcframework"

for command_name in go xcodebuild; do
  command -v "$command_name" >/dev/null || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-last-chance-runtime.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

(
  cd "$runtime_dir"
  echo "Installing gomobile and gobind"
  GOBIN="$temporary_dir" go install golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind

  echo "Building OneLastChanceRuntime.xcframework"
  PATH="$temporary_dir:$PATH" CGO_ENABLED=1 "$temporary_dir/gomobile" bind \
    -target=ios,iossimulator \
    -trimpath \
    -ldflags='-s -w -checklinkname=0' \
    -o "$temporary_dir/OneLastChanceRuntime.xcframework" \
    .
)

for binary in \
  "$temporary_dir/OneLastChanceRuntime.xcframework/ios-arm64/OneLastChanceRuntime.framework/OneLastChanceRuntime" \
  "$temporary_dir/OneLastChanceRuntime.xcframework/ios-arm64_x86_64-simulator/OneLastChanceRuntime.framework/OneLastChanceRuntime"; do
  [[ -f "$binary" ]] || {
    echo "gomobile did not produce $binary" >&2
    exit 1
  }
done

mkdir -p "$frameworks_dir"
rm -rf "$framework_path"
/usr/bin/ditto "$temporary_dir/OneLastChanceRuntime.xcframework" "$framework_path"
echo "Built $framework_path"
