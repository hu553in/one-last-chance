#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_dir="$project_dir/native/one-last-chance-runtime"
gomobile_version="v0.0.0-20260813181013-1960c775504c"
frameworks_dir="$project_dir/native/olcrtc-tunnel-core/Frameworks"
framework_path="$frameworks_dir/OneLastChanceRuntime.xcframework"
tool_dir="$project_dir/.cache/tools"
gomobile_dir="$tool_dir/$gomobile_version"
gomobile_path="$gomobile_dir/gomobile"

for command_name in go xcodebuild; do
  command -v "$command_name" >/dev/null || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

mkdir -p "$frameworks_dir" "$gomobile_dir"
if [[ ! -x "$gomobile_path" ]]; then
  echo "Installing pinned gomobile $gomobile_version"
  GOBIN="$gomobile_dir" go install "golang.org/x/mobile/cmd/gomobile@$gomobile_version"
fi
"$gomobile_path" init

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-last-chance-runtime.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

echo "Building OneLastChanceRuntime.xcframework"
(
  cd "$runtime_dir"
  CGO_ENABLED=1 "$gomobile_path" bind \
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

rm -rf "$framework_path"
/usr/bin/ditto "$temporary_dir/OneLastChanceRuntime.xcframework" "$framework_path"
echo "Built $framework_path"
