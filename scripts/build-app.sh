#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$PWD/dist/Markdown Native.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/TyporaNative" "$app_dir/Contents/MacOS/TyporaNative"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
printf 'Built %s\n' "$app_dir"
