# Markdown Studio：前端重写版

本版本按追加要求使用现代前端重新实现交互。SPEC.md 和 README.md 按创建新项目时的内容原样保留；其中旧版 AppKit 实现说明属于历史记录。当前运行、架构与验证以本文和 VALIDATION.md 为准。

## 构建与运行

需要 macOS 13+、Xcode Command Line Tools、Node.js（满足 Vite 8 的要求）。首次安装与构建：

```sh
npm ci --prefix web
./scripts/build-app.sh
open 'dist/Markdown Studio.app'
```

产物是本地 macOS 应用，使用系统 WebKit，不依赖开发服务器。当前为本机架构、临时签名构建，未进行 App Store 分发或公证。

前端开发预览：

```sh
npm run --prefix web dev
```

Chrome 可打开终端显示的 localhost 地址，导入本地 Markdown 并编辑，保存会下载新的文件。原生应用才包含直接保存原文件、编码保留、磁盘冲突检测、草稿恢复与 PDF 导出。浏览器预览中的导出为 HTML。

## 实现分工

- React / TypeScript：工具栏、大纲、状态、错误信息；Radix：菜单与弹窗；Phosphor：图标。
- CodeMirror 6：编辑事务、历史、搜索替换、语言解析、视口渲染；正文不经过 React 状态逐字重建。
- Swift / AppKit / WKWebView：窗口、系统菜单、文件选择、编码、原子保存、草稿、冲突和图片落盘。
- marked / DOMPurify：表格及导出 HTML；PDF 使用 WebKit 分页快照并由 Core Graphics 合成可选择文字的 PDF。

Markdown 原文是唯一持久化内容。前端将 CodeMirror 范围事务转换为 UTF-16 文本补丁发送到宿主，原始换行元数据独立保存并随撤销恢复。未修改的 BOM、编码、混合换行和尾随空格尽量原样保留。单元格修改只替换对应文字，增删表格行列时仅重建该表格。

## 功能入口

- 拖入文档：将 `.md`、`.markdown` 或 `.txt` 拖到应用内容区域，在独立窗口打开；支持多文件。已打开的同一路径会激活已有窗口，避免并行覆盖。图片拖入仍为插图。
- 大纲宽度：拖动侧栏右边缘，双击恢复 228 px；左右方向键每次调整 10 px，Home / End 到最小/最大值。范围为 180–420 px，并随窗口缩小限制最大宽度，给正文保留至少 560 px（窄窗口自动隐藏大纲）。宽度保存到原生偏好，重启后恢复。
- 新建 / 打开 / 保存 / 另存为：侧栏、顶栏或系统文件菜单。
- 基础格式：工具栏与格式菜单；⌘B / ⌘I / ⌘K、⌘1–6。
- 写作 / 源码切换：右上角或 ⇧⌘M；⌘F 查找替换；⌘Z / ⇧⌘Z 撤销重做。
- 代码块：工具栏设置语言，未知语言保留纯文本；内置 JS、TS、JSON、Python、Swift、Go 高亮。
- 表格：点击“编辑此表格”或工具栏，Tab / Shift-Tab 导航，支持行列和对齐调整。
- 图片：按钮、拖入或粘贴。先保存文档，再在旁边的 assets 目录存储图片；光标进入图片源码后可用链接按钮编辑地址和替代文本。
- 链接：⌘点击打开；文内标题锚点支持小写、空格转短横线及重复标题数字后缀。
- 导出：右上角选择 HTML / PDF。本地图片嵌入导出内容，失效引用会显示错误。
- 草稿：输入停止约 350 ms 后持久化；下次启动恢复。位置为 `~/Library/Application Support/MarkdownNativeWeb/Recovery`。
- 外部修改：约每 2 秒检查；保存前再次核对磁盘基线，可另存、取消或显式覆盖。

## 验证命令

```sh
npm run --prefix web test
swift test
./scripts/build-app.sh
'dist/Markdown Studio.app/Contents/MacOS/TyporaNative' --verify .build/web-verification
```

最后一项启动真实 WKWebView 执行集成验证，会在指定测试目录生成 Markdown、图片、草稿和 PDF；不修改用户文档。旧界面源码保留在 Git 提交 `3c00d75` 中。

## Glide 表格抽屉

点击表格编辑按钮，在右侧 80% 宽度抽屉中打开 Glide Data Grid；不足 900 px 的窗口使用全屏。支持区域选择、复制粘贴、Tab / Shift-Tab、列宽拖动、行列增删、列对齐和独立撤销重做。首行为 Markdown 表头。草稿在应用后才局部写回正文；取消已修改草稿时需要明确放弃。列宽只用于编辑，不写入 Markdown。

组件固定为官方发布的 `@glideapps/glide-data-grid@6.0.4-alpha24`（MIT，声明支持 React 19）。稳定版 6.0.3 的依赖范围不覆盖当前 React/marked，因此采用此预发布版本，而未强制忽略依赖约束。marked 固定为兼容的 16.4.2，HTML 仍经 DOMPurify 清理。升级需要重新验证 WebKit 中文编辑、剪贴板、Portal 焦点。

网格仅在抽屉打开时挂载，关闭时销毁。当前 IIFE 打包仍包含其代码，未使用独立网络懒加载。生产 JavaScript 约 1.33 MB，gzip 约 447 KB。公式、合并单元格及 Excel 文件导入导出未开放；粘贴作用于现有表格范围。

### 表格键盘与列操作

表格抽屉支持 F2、Enter 或双击进入单元格编辑，Tab 连续编辑，Escape 取消当前单元格编辑。打开时默认选中首个单元格。列头下拉菜单和右键菜单支持左侧/右侧插入、删除、左移、右移；拖动列头可直接重排列。列操作以当前选中列为准，同步移动表头、正文数据、对齐方式和列宽，内容变更可撤销/重做。行标选择也会用于工具栏的行操作。

验证覆盖真实 WebKit 中的列插入、删除、移动、选中位置、对齐方式、撤销和 F2 编辑浮层；编辑草稿仅在点击应用后写回 Markdown。
