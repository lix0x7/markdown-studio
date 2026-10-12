#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
npm run --prefix web build
configuration="${1:-release}"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$PWD/dist/Markdown Studio.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/web"
cp "$bin_dir/TyporaNative" "$app_dir/Contents/MacOS/TyporaNative"
cp Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp web/dist/app.js "$app_dir/Contents/Resources/web/"
cp web/dist/*.css "$app_dir/Contents/Resources/web/style.css"
cat > "$app_dir/Contents/Resources/web/index.html" <<'HTML'
<!doctype html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https: http:; connect-src 'none'; object-src 'none'; frame-src 'none'"><link rel="stylesheet" href="style.css"><title>Markdown Studio</title></head><body><div id="root"></div><script src="app.js"></script></body></html>
HTML
codesign --force --sign - "$app_dir"
printf 'Built %s\n' "$app_dir"
