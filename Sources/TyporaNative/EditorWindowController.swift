import AppKit
import UniformTypeIdentifiers
import MarkdownCore

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    let editor: EditorTextView
    let styler = TextStyler()
    private let scroll = NSScrollView()
    private let outline = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let modeButton = NSButton()
    private var headings: [Heading] = []
    private var source: SourceFile
    private(set) var fileURL: URL?
    private var baseline: Data?
    private let recoveryID: UUID
    private let recovery: RecoveryStore
    private var refreshWork: DispatchWorkItem?
    private var recoveryWork: DispatchWorkItem?
    private var watcher: Timer?
    var tableSheet: TableSheet?
    private var externalChanged = false
    private var recoveryError: String?
    private var closing = false
    var onClose: (() -> Void)?

    var isDirty: Bool { baseline.map { source.data != $0 } ?? !source.text.isEmpty }

    init(url: URL? = nil, record: RecoveryRecord? = nil, recovery: RecoveryStore) throws {
        let storage = NSTextStorage(), layout = PreviewLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        editor = EditorTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 700), textContainer: container)
        self.recovery = recovery
        if let record {
            source = record.source; fileURL = record.path.map { URL(fileURLWithPath: $0) }; baseline = record.baseline; recoveryID = record.id
        } else if let url {
            let data = try Data(contentsOf: url)
            source = try SourceFile(data: data); fileURL = url; baseline = data; recoveryID = UUID()
        } else { source = SourceFile(); baseline = nil; recoveryID = UUID() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self; window.minSize = NSSize(width: 720, height: 480); window.center()
        window.setFrameAutosaveName("TyporaNativeEditor")
        setupUI()
        editor.string = source.text
        styler.baseURL = fileURL?.deletingLastPathComponent()
        styler.images.didLoad = { [weak self] in self?.refresh() }
        refresh()
        if record != nil { status.stringValue = "已恢复未保存草稿 · 保存前将检查磁盘版本" }
        watcher = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkExternalChange() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 构建原生侧栏、文本编辑区和工具栏；文本容器宽度跟随实际可用区域。
    private func setupUI() {
        guard let window else { return }
        let root = NSView(); window.contentView = root
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let sidebar = NSVisualEffectView(); sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow
        let title = NSTextField(labelWithString: "文档大纲"); title.font = .systemFont(ofSize: 12, weight: .semibold); title.textColor = .secondaryLabelColor
        let outlineScroll = NSScrollView(); outlineScroll.hasVerticalScroller = true; outlineScroll.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading")); outline.addTableColumn(column)
        outline.headerView = nil; outline.delegate = self; outline.dataSource = self; outline.rowHeight = 32; outline.backgroundColor = .clear
        outline.target = self; outline.action = #selector(jumpToHeading); outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineScroll.documentView = outline
        for view in [title, outlineScroll] { view.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(view) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 20), title.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            outlineScroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12), outlineScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            outlineScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8), outlineScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])
        sidebar.frame.size.width = 220
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.documentView = editor
        editor.minSize = NSSize(width: 0, height: 0); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true; editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 44, height: 32)
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false; editor.usesFindBar = true; editor.isIncrementalSearchingEnabled = true
        editor.delegate = self; editor.font = .systemFont(ofSize: 16)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        editor.importImageFiles = { [weak self] urls in self?.insertImages(urls) }
        editor.importImageData = { [weak self] data in self?.insertPastedImage(data) }
        editor.newline = { [weak self] in self?.source.newline ?? "\n" }
        editor.navigateCell = { [weak self] backwards in self?.navigateCell(backwards: backwards) ?? false }
        split.addArrangedSubview(sidebar); split.addArrangedSubview(scroll)
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        for view in [split, status] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor), split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8), status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 160), sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 340)
        ])
        let toolbar = NSToolbar(identifier: "EditorToolbar"); toolbar.delegate = self; toolbar.displayMode = .iconOnly
        window.toolbar = toolbar; window.toolbarStyle = .unified
        editor.textContainerInset = NSSize(width: 36, height: 28)
        root.layoutSubtreeIfNeeded()
        split.setPosition(220, ofDividerAt: 0)
        editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, editor.frame.height)))
        scroll.contentView.scroll(to: .zero)
        window.makeFirstResponder(editor)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["save", "bold", "italic", "link", "image", "table", "code", .flexibleSpace, "mode", "exportPDF"].map { $0 }
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id.rawValue == "mode" {
            modeButton.title = "源码"; modeButton.setButtonType(.pushOnPushOff); modeButton.bezelStyle = .texturedRounded
            modeButton.target = self; modeButton.action = #selector(toggleMode)
            modeButton.toolTip = "切换源码 / 实时预览（⌘⇧M）"; item.view = modeButton; item.label = "源码模式"
            return item
        }
        let definitions = ["save": ("保存", "square.and.arrow.down"), "bold": ("加粗", "bold"), "italic": ("斜体", "italic"), "link": ("链接", "link"), "image": ("图片", "photo"), "table": ("表格", "tablecells"), "code": ("代码块 / 语言", "chevron.left.forwardslash.chevron.right"), "exportPDF": ("导出 PDF", "doc.richtext")]
        guard let (label, symbol) = definitions[id.rawValue] else { return nil }
        item.label = label; item.toolTip = label; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self; item.action = #selector(toolbarCommand(_:)); return item
    }
    @objc private func toolbarCommand(_ sender: NSToolbarItem) { command(sender.itemIdentifier.rawValue) }
    @objc func toggleMode() {
        guard !editor.hasMarkedText() else { return }
        let position = scroll.contentView.bounds.origin
        styler.sourceMode.toggle(); modeButton.state = styler.sourceMode ? .on : .off
        refresh(); scroll.contentView.scroll(to: position); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func command(_ name: String) {
        guard !editor.hasMarkedText() else { NSSound.beep(); return }
        switch name {
        case "save": _ = save()
        case "saveAs": _ = save(as: true)
        case "mode": toggleMode()
        case "bold": wrap("**")
        case "italic": wrap("*")
        case "strike": wrap("~~")
        case "inlineCode": wrap("`")
        case "quote": prefix("> ", replacing: #"^\s*>\s?"#)
        case "bullet": prefix("- ", replacing: #"^\s*(?:[-+*]|\d+[.)])\s+"#)
        case "number": prefix("1. ", replacing: #"^\s*(?:[-+*]|\d+[.)])\s+"#)
        case "link": editLink()
        case "image": chooseImage()
        case "table": editTable()
        case "code": editCodeFence()
        case "exportHTML": exportHTML()
        case "exportPDF": exportPDF()
        case "reload": reloadFromDisk()
        default:
            if name.hasPrefix("h"), let level = Int(name.dropFirst()), (1...6).contains(level) { prefix(String(repeating: "#", count: level) + " ", replacing: #"^ {0,3}#{1,6}\s+"#) }
        }
    }

    // 所有菜单编辑走 NSTextView 原生替换接口，保留选区、撤销栈和原文的非目标范围。
    func apply(_ edits: [TextEdit], name: String, selection: NSRange? = nil) {
        guard !edits.isEmpty else { return }
        editor.undoManager?.beginUndoGrouping()
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            editor.insertText(edit.replacement, replacementRange: edit.range)
        }
        editor.undoManager?.endUndoGrouping(); editor.undoManager?.setActionName(name)
        if let selection { editor.setSelectedRange(selection) }
        refresh()
    }
    private func wrap(_ marker: String) {
        let selected = editor.selectedRange(), edit = Markdown.wrap(in: editor.string, selection: selected, marker: marker)
        let newRange: NSRange
        if edit.replacement.utf16.count > selected.length {
            newRange = NSRange(location: edit.range.location + marker.utf16.count, length: selected.length)
        } else { newRange = NSRange(location: edit.range.location, length: edit.replacement.utf16.count) }
        apply([edit], name: "设置格式", selection: newRange)
    }
    private func prefix(_ prefix: String, replacing pattern: String) {
        apply([Markdown.prefix(in: editor.string, selection: editor.selectedRange(), prefix: prefix, replacing: pattern)], name: "段落格式")
    }
    func textDidChange(_ notification: Notification) {
        source.text = editor.string
        updateStatus()
        recoveryWork?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.persistRecovery() }
        recoveryWork = save; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: save)
        scheduleRefresh()
    }
    func textViewDidChangeSelection(_ notification: Notification) { if !styler.isStyling { scheduleRefresh() } }
    @objc private func viewportChanged() {
        if !styler.isStyling { scheduleRefresh() }
    }
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.008, execute: work)
    }
    func refresh() {
        guard !editor.hasMarkedText() else { return }
        styler.apply(to: editor)
        headings = styler.headings; outline.reloadData(); updateStatus()
    }
    private func updateStatus() {
        window?.title = fileURL?.lastPathComponent ?? "未命名.md"
        window?.representedURL = fileURL; window?.isDocumentEdited = isDirty
        let ending = source.newline == "\r\n" ? "CRLF" : source.newline == "\r" ? "CR" : "LF"
        let suffix = recoveryError.map { "草稿恢复写入失败：\($0)" } ?? (externalChanged ? "磁盘版本已变化 · 保存时处理冲突" : isDirty ? "未保存 · 自动保存恢复草稿" : fileURL == nil ? "新文档" : "已保存")
        status.stringValue = "\(source.encoding.rawValue.uppercased())  ·  \(ending)  ·  \(styler.sourceMode ? "源码" : "实时预览")  ·  \(suffix)"
    }
    func numberOfRows(in tableView: NSTableView) -> Int { headings.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let heading = headings[row]
        let text = NSTextField(labelWithString: String(repeating: "  ", count: heading.level - 1) + heading.title)
        text.font = .systemFont(ofSize: 12, weight: heading.level == 1 ? .semibold : .regular)
        text.lineBreakMode = .byTruncatingTail; text.toolTip = heading.title; return text
    }
    @objc private func jumpToHeading() {
        let row = outline.selectedRow
        guard headings.indices.contains(row) else { return }
        editor.setSelectedRange(NSRange(location: headings[row].range.location, length: 0)); editor.scrollRangeToVisible(headings[row].range)
        window?.makeFirstResponder(editor)
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let raw = link as? String else { return false }
        if raw.hasPrefix("#") {
            let target = String(raw.dropFirst()).removingPercentEncoding ?? String(raw.dropFirst())
            if let heading = headings.first(where: { $0.title.lowercased().replacingOccurrences(of: " ", with: "-") == target.lowercased() }) {
                editor.setSelectedRange(NSRange(location: heading.range.location, length: 0)); editor.scrollRangeToVisible(heading.range)
            }
        } else if let url = Markdown.resolvedURL(raw, base: fileURL?.deletingLastPathComponent()) { NSWorkspace.shared.open(url) }
        return true
    }

    // 保存前比较磁盘基线；冲突只允许显式选择另存为、重载或覆盖。
    func save(as saveAs: Bool = false) -> Bool {
        source.text = editor.string
        var target = fileURL, overwrite = false
        if saveAs || target == nil {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "未命名.md"
            panel.directoryURL = fileURL?.deletingLastPathComponent()
            panel.message = "另存为保留 Markdown 原文。相对图片引用仍相对于新位置；跨文件夹保存会提示复制本地图片。"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            target = url; overwrite = true
        }
        guard let target else { return false }
        let same = target.standardizedFileURL == fileURL?.standardizedFileURL
        do {
            if !same, let oldBase = fileURL?.deletingLastPathComponent(), oldBase != target.deletingLastPathComponent() {
                guard copyRelativeImages(from: oldBase, to: target.deletingLastPathComponent()) else { return false }
            }
            try FileStore.save(source, to: target, expected: same ? baseline : nil, overwrite: overwrite && !same)
            fileURL = target; baseline = source.data; externalChanged = false; styler.baseURL = target.deletingLastPathComponent()
            try recovery.remove(recoveryID); recoveryError = nil; updateStatus()
            NSDocumentController.shared.noteNewRecentDocumentURL(target)
            return true
        } catch SourceError.conflict {
            let alert = NSAlert(); alert.messageText = "文件已被其他应用修改"; alert.informativeText = "保留当前编辑并另存为，或重新载入磁盘版本。覆盖会替换磁盘上的内容。"
            alert.addButton(withTitle: "另存为"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "重新载入"); alert.addButton(withTitle: "覆盖磁盘版本")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return save(as: true)
            case .alertThirdButtonReturn: reloadFromDisk(); return false
            case NSApplication.ModalResponse(rawValue: 1003):
                do {
                    try FileStore.save(source, to: target, expected: nil, overwrite: true)
                    fileURL = target; baseline = source.data; externalChanged = false
                    try recovery.remove(recoveryID); updateStatus(); return true
                } catch { present(error); return false }
            default: return false
            }
        } catch { present(error); return false }
    }
    private func persistRecovery() {
        do {
            if isDirty { try recovery.write(RecoveryRecord(id: recoveryID, path: fileURL?.path, source: source, baseline: baseline)) }
            else { try recovery.remove(recoveryID) }
            recoveryError = nil
        } catch { recoveryError = error.localizedDescription }
        updateStatus()
    }
    private func checkExternalChange() {
        guard let fileURL, !closing else { return }
        externalChanged = (try? Data(contentsOf: fileURL)) != baseline
        updateStatus()
    }
    private func reloadFromDisk() {
        guard let fileURL else { return }
        if isDirty {
            let alert = NSAlert(); alert.messageText = "丢弃当前编辑并重新载入？"; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "重新载入")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do {
            let data = try Data(contentsOf: fileURL), loaded = try SourceFile(data: data)
            source = loaded; baseline = data; editor.string = loaded.text; editor.undoManager?.removeAllActions(); externalChanged = false
            try recovery.remove(recoveryID); refresh()
        } catch { present(error) }
    }
    func canClose() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert(); alert.messageText = "保存对“\(fileURL?.lastPathComponent ?? "未命名.md")”的修改？"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "不保存")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canClose() }
    func windowWillClose(_ notification: Notification) {
        closing = true; watcher?.invalidate(); refreshWork?.cancel(); recoveryWork?.cancel()
        do { try recovery.remove(recoveryID) } catch { present(error) }
        onClose?()
    }
    func flushRecovery() { recoveryWork?.cancel(); source.text = editor.string; persistRecovery() }
    func present(_ error: Error) { NSAlert(error: error).runModal() }
}

extension NSToolbarItem.Identifier: @retroactive ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}
