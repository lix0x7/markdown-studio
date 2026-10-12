import AppKit
import UniformTypeIdentifiers
import MarkdownCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [Host] = []
    private let recovery = RecoveryStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MarkdownNativeWeb/Recovery", isDirectory: true))

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        do {
            for record in try recovery.records() { try show(record: record) }
        } catch { NSAlert(error: error).runModal() }
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && $0.hasSuffix(".md") }
        for path in args { open(URL(fileURLWithPath: path)) }
        if windows.isEmpty { newDocument(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }
    private func show(url: URL? = nil, record: RecoveryRecord? = nil) throws {
        if let url, let existing = windows.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) { existing.showWindow(nil); return }
        let controller = try Host(url: url, record: record, recovery: recovery)
        windows.append(controller)
        controller.web.onOpenDocuments = { [weak self] urls in
            for url in urls { self?.open(url) }
        }
        controller.onClose = { [weak self, weak controller] in self?.windows.removeAll { $0 === controller } }
        controller.onNew = { [weak self] in self?.newDocument(nil) }; controller.onOpen = { [weak self] in self?.openDocument(nil) }; controller.showWindow(nil)
    }
    private func open(_ url: URL) {
        do { try show(url: url); NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        catch { NSAlert(error: error).runModal() }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for path in filenames { open(URL(fileURLWithPath: path)) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { newDocument(nil) }; return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for window in windows where !window.canClose() { return .terminateCancel }
        for window in Array(windows) { window.close() }
        return .terminateNow
    }
    func applicationDidResignActive(_ notification: Notification) { windows.forEach { $0.persistDraft() } }
    @objc private func newDocument(_ sender: Any?) { do { try show() } catch { NSAlert(error: error).runModal() } }
    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, .init(filenameExtension: "md") ?? .plainText]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach(open) }
    }
    @objc private func command(_ sender: NSMenuItem) {
        (NSApp.keyWindow?.windowController as? Host)?.event("command", sender.representedObject as? String ?? "")
    }
    // 原生菜单通过响应链处理编辑命令，文档命令转发到当前窗口。
    private func buildMenus() {
        let menu = NSMenu(); NSApp.mainMenu = menu
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""), child = NSMenu(title: title)
            item.submenu = child; menu.addItem(item); return child
        }
        func item(_ parent: NSMenu, _ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, action: Selector? = nil, command name: String? = nil, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: name == nil ? action : #selector(command(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = name == nil ? target : self; item.representedObject = name
            parent.addItem(item)
        }
        let app = submenu("Markdown Studio")
        item(app, "关于 Markdown Studio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        item(app, "隐藏 Markdown Studio", "h", action: #selector(NSApplication.hide(_:)), target: NSApp)
        item(app, "退出 Markdown Studio", "q", action: #selector(NSApplication.terminate(_:)), target: NSApp)
        let file = submenu("文件")
        item(file, "新建", "n", action: #selector(newDocument(_:)), target: self)
        item(file, "打开…", "o", action: #selector(openDocument(_:)), target: self)
        file.addItem(.separator())
        item(file, "保存", "s", command: "save"); item(file, "另存为…", "s", [.command, .shift], command: "saveAs")
        item(file, "从磁盘重新载入…", command: "reload")
        file.addItem(.separator()); item(file, "导出 HTML…", command: "exportHTML"); item(file, "导出 PDF…", "e", [.command, .shift], command: "exportPDF")
        file.addItem(.separator()); item(file, "关闭窗口", "w", action: #selector(NSWindow.performClose(_:)))
        let edit = submenu("编辑")
        item(edit, "撤销", "z", command: "undo"); item(edit, "重做", "z", [.command, .shift], command: "redo")
        edit.addItem(.separator()); item(edit, "剪切", "x", action: #selector(NSText.cut(_:))); item(edit, "复制", "c", action: #selector(NSText.copy(_:)))
        item(edit, "粘贴", "v", action: #selector(NSText.paste(_:))); item(edit, "全选", "a", action: #selector(NSText.selectAll(_:)))
        edit.addItem(.separator())
        item(edit, "查找…", "f", command: "find")
        edit.items.last?.tag = NSTextFinder.Action.showFindInterface.rawValue
        item(edit, "查找与替换…", "f", [.command, .option], command: "find")
        edit.items.last?.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        let format = submenu("格式")
        item(format, "加粗", "b", command: "bold"); item(format, "斜体", "i", command: "italic")
        item(format, "删除线", command: "strike"); item(format, "行内代码", "`", command: "inlineCode")
        format.addItem(.separator())
        for level in 1...6 { item(format, "标题 \(level)", String(level), command: "h\(level)") }
        item(format, "引用", command: "quote"); item(format, "无序列表", command: "bullet"); item(format, "有序列表", command: "number")
        format.addItem(.separator())
        item(format, "编辑链接…", "k", command: "link"); item(format, "插入图片…", command: "image")
        item(format, "插入 / 编辑表格…", "t", [.command, .option], command: "table")
        item(format, "代码块 / 语言…", "c", [.command, .option], command: "code")
        let view = submenu("显示"); item(view, "切换源码 / 实时预览", "m", [.command, .shift], command: "mode")
        let window = submenu("窗口"); NSApp.windowsMenu = window
        item(window, "最小化", "m", action: #selector(NSWindow.performMiniaturize(_:))); item(window, "缩放", action: #selector(NSWindow.performZoom(_:)))
    }
}
