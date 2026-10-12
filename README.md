# Typora Native

使用 Swift + AppKit 实现的 macOS 原生 Markdown 编辑器。文件、编辑器、表格窗口、大纲、查找替换和打印均使用原生控件；无 Electron 或浏览器编辑器依赖。

## 典型截图

以下为当前 **Markdown Studio 前端重写版**的 macOS 应用实拍，采用 React + CodeMirror 6 + Radix，运行在原生 WKWebView 宿主中。当前构建与启动方法见 [DEVELOPMENT.md](DEVELOPMENT.md)，验收记录见 [VALIDATION.md](VALIDATION.md)；下方原有章节保留的是早期纯 AppKit 版本说明。

支持将 `.md`、`.markdown`、`.txt` 文件拖到应用界面，在独立窗口打开（多文件逐个打开，已打开文件激活已有窗口）；当前文档及未保存修改保持不变。拖入图片仍用于插图。

双击编辑区空白处可插入空行并放置光标；双击文字仍为选词。双击文末下方空白会按距离补足换行，双击行尾空白则在该行之后插入一行。

### 写作与文档大纲

在同一区域输入和预览 Markdown，左侧大纲用于定位标题，顶部提供格式操作、保存和导出。

![Markdown Studio 写作界面：文档大纲、实时排版、格式工具栏和表格预览](docs/screenshots/writing.jpg)

### Markdown 源码模式

随时切换到源码模式，查看并直接编辑标题、行内格式、表格与围栏代码的原始语法。

![Markdown Studio 源码模式：Markdown 标记、表格源码与代码高亮](docs/screenshots/source.jpg)

### 可视化表格编辑

通过网格修改单元格，增删行列和设置对齐；支持 Tab / Shift-Tab 连续编辑。

![Markdown Studio 表格编辑弹窗：单元格网格、行列操作与对齐选项](docs/screenshots/table-editor.jpg)

## 运行

环境：macOS 13+、Swift 6 / Xcode 16+。本次已在 macOS 15.6.1、Apple Silicon、Xcode 26.3 上构建验证。

```bash
cd /Users/bytedance/code/typora-spec
./scripts/build-app.sh
open 'dist/Typora Native.app'
```

打开示例：

```bash
open -a "$PWD/dist/Typora Native.app" "$PWD/Resources/Welcome.md"
```

也可通过 `swift run TyporaNative /absolute/path/document.md` 启动。生成的 `.app` 使用本地 ad-hoc 签名；当前构建对应本机 arm64 架构。

## P0 能力

- 新建、打开、保存、另存为，多窗口及关闭前的未保存提示。
- 同区域实时预览、源码切换，原生撤销重做、剪贴板及查找替换。
- 标题、加粗、斜体、删除线、引用、列表、行内代码和链接。
- 围栏代码块、语言选择、常见语言的轻量语法高亮；未知语言按纯文本显示。
- 表格原生网格预览、单元格编辑、增删行列、对齐、Tab 导航。
- 拖入/粘贴图片并复制到文档旁的 `assets/`；相对路径、替代文本和链接编辑。
- 按原始文本位置定位的大纲，重复标题也能分别跳转。
- HTML / 分页 PDF 导出；HTML 内嵌本地图片，缺失本地图片会提示修复。
- 本地恢复草稿、外部文件变化提示、保存前冲突检查及原子写入。

## 原文保持规则

1. `NSTextStorage.string` 保存 Markdown 原文。预览只改变属性或布局层绘制，不通过 AST 重建文档。
2. 格式操作使用 UTF-16 范围替换，进入原生撤销栈；未选中内容不做格式整理。
3. 普通表格单元格编辑只替换单元格内容；列对齐只修改该列分隔符。增删行列的改动限定在当前表格范围内。
4. 保存保留 UTF-8、UTF-8 BOM、带 BOM 的 UTF-16 LE/BE，以及已有的混合换行、空格和末尾换行状态。新插入的换行跟随文档检测到的首个换行风格。其他编码拒绝无损要求无法保证的写入。
5. 文件通过原子替换写入，比较的是打开/上次保存时的完整字节基线。目标是让 Git diff 只包含实际编辑，不是原地改写磁盘上的几个字节。
6. 实时预览在活动段落显示语法；非活动图片和表格通过原生布局绘制。超过 10 万 UTF-16 单元的文档限制在可见段落及选区更新显示。

## 常用操作

| 操作 | 快捷键 / 入口 |
|---|---|
| 保存 / 另存为 | ⌘S / ⇧⌘S |
| 源码 / 预览 | ⇧⌘M |
| 加粗 / 斜体 | ⌘B / ⌘I |
| 标题 1–6 | ⌘1–⌘6 |
| 链接 / 图片引用 | ⌘K，光标位于引用中时编辑已有引用 |
| 表格 | ⌥⌘T；光标在表格内时打开编辑窗口 |
| 代码块 / 语言 | ⌥⌘C；光标在代码块内时只修改语言标识 |
| 查找 / 替换 | ⌘F / ⌥⌘F |
| PDF 导出 | ⇧⌘E |

未命名文档插入图片时先选择文档保存位置。跨目录另存为时，可选择复制相对路径图片或仅保存文档；图片复制不会覆盖内容不同的现有文件。撤销正文中的图片引用不会删除已复制的资产。

恢复草稿位置：`~/Library/Application Support/TyporaNative/Recovery/`。编辑停止约 400 ms 后写入，切出应用时也会刷新；异常退出后启动应用会恢复已经落盘的草稿。恢复草稿不代表原文件已经保存。

## 验证

```bash
swift test
swift run -c release TyporaNative --smoke-test .build/native-smoke
./scripts/build-app.sh
```

- `swift test`：编码与字节保持、范围编辑、Unicode、表格、冲突保护、恢复记录、导出等回归。
- 原生集成验证：真实 NSTextView 格式化、撤销重做、IME 组合输入、预览模式、图片、表格显示、精确保存及 PDF 分页。
- 测试输出仅写入 `.build/`，构建结果写入 `dist/`，均不纳入 Git。

验收证据与范围见 [VALIDATION.md](VALIDATION.md)，产品功能规格见 [SPEC.md](SPEC.md)。

## 实现边界

- 支持本项目 P0 所列 Markdown 子集，并非完整 CommonMark/GFM 一致性实现；未知语法保留原文，原始 HTML 在导出时转义显示。
- 表格修改通过原生编辑窗口完成；进入表格所在段落编辑时会展开原文。单独占一行的图片支持直接预览。
- 网络图片需要联网；HTML 保留远程图片 URL，本地图片内嵌。远程图片获取失败时保留可修改的原始引用。
- PDF 使用系统富文本导入与打印排版，样式不保证与 HTML 像素一致。PDFKit 可能将部分汉字提取为兼容字符，测试使用 Unicode 兼容归一化比较。
- 文件树/跨文档搜索、公式、Mermaid、主题定制、Pandoc 属于 P1/P2。
- 当前为本地构建，尚未进行开发者证书签名、公证或 Intel 实机验证。
