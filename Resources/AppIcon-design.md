# Markdown Studio 应用图标

使用内置 imagegen 生成黑白扁平图标：白色圆角底板、黑色 M 与书写横线，去除纸张折角、钢笔、立体高光和阴影。相较旧版扩大底板占比、减少透明外边距，改善 Dock 视觉尺寸。

透明 PNG 母版：`AppIcon.png`；macOS 图标：`AppIcon.icns`。
运行 `./scripts/build-icon.sh` 生成 16–1024 像素各尺寸，再运行 `./scripts/build-app.sh` 打包。

## 生成提示词

Use case: style-transfer / logo-brand. Edit the supplied Markdown Studio app icon into a radically simpler flat black-and-white macOS Dock icon. One front-facing rounded square white tile with a large solid black geometric M centered on it and one simple short black horizontal writing line below the M. Remove paper outline, folded corner, fountain pen, green colors, shadows, bevels, gradients and all texture. Pure black #000000 and white #FFFFFF only, with antialiasing at edges. The M is bold and crisp, readable at 16px. Enlarge the rounded square to occupy 88% of the canvas width and height, centered with only 6% transparent margin on each side; rounded corners radius about 20% of tile width. M occupies roughly 62% of tile width. Flat vector-like artwork, no 3D, no drop shadow, no border, no text other than M, no mockup. Square PNG with genuinely transparent pixels outside white rounded square. Exactly one icon.

## 边缘优化提示词

Polish this exact icon without changing its design: black geometric M and black underline on white rounded-square tile. Strict flat pure black and pure white fills, no texture or grain. CRITICAL: remove every stray speck and rough/ragged pixel outside the white rounded rectangle; its silhouette must be perfectly smooth clean symmetric continuous rounded-square with antialiased edges. All canvas outside the rounded-square must be completely transparent alpha=0. Center the tile, equal 6% margin on all four sides (tile 88% canvas width and height). Preserve the M and underline shapes and relative composition, no shadow, no border, no gray outlines, no extra elements. Production-ready small macOS app icon, square asset.
