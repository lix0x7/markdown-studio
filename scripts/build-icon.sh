#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 从透明 PNG 母版生成 macOS 标准图标尺寸和 Retina 资源。
icon_tmp="$(mktemp -d)"
trap 'rm -rf "$icon_tmp"' EXIT
iconset="$icon_tmp/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
