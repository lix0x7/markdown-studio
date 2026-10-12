import AppKit
import WebKit
import UniformTypeIdentifiers
import MarkdownCore

// macOS 宿主只处理文件、窗口和系统能力；文档交互由 React + CodeMirror 完成。
final class Host: NSWindowController, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var source: SourceFile
    var url: URL?
    var baseline: Data?
    let recordID: UUID
    let recovery: RecoveryStore
    let web: DocumentWebView
    var draftWork: DispatchWorkItem?
    var watch: Timer?
    var closed = false
    var exporter: WebPDFExporter?
    var onClose: (() -> Void)?
    var onNew: (() -> Void)?
    var onOpen: (() -> Void)?
    var dirty: Bool { baseline.map { $0 != source.data } ?? !source.text.isEmpty }

    init(url: URL? = nil, record: RecoveryRecord? = nil, recovery: RecoveryStore) throws {
        self.recovery = recovery
        self.url = record?.path.map { URL(fileURLWithPath: $0) } ?? url
        recordID = record?.id ?? UUID()
        if let record { source = record.source; baseline = record.baseline }
        else if let url { let data = try Data(contentsOf: url); source = try SourceFile(data: data); baseline = data }
        else { source = SourceFile() }
        web = DocumentWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.minSize = NSSize(width: 760, height: 520)
        window.title = self.url?.lastPathComponent ?? "Markdown Studio"
        window.center(); window.delegate = self
        window.setFrameAutosaveName("MarkdownNativeWebEditor")
        window.contentView = web
        web.navigationDelegate = self
        web.registerForDraggedTypes([.fileURL])
        if CommandLine.arguments.contains("--verify") { web.configuration.userContentController.addUserScript(WKUserScript(source: "window.__VERIFY=true", injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
        web.configuration.userContentController.add(self, name: "bridge")
        let index = Bundle.main.resourceURL!.appendingPathComponent("web/index.html")
        web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let url = self.url else { return }
            self.event("external", (try? Data(contentsOf: url)) != self.baseline)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func metadata(includeText: Bool = false) -> [String: Any] {
        var info: [String: Any] = ["name": url?.lastPathComponent ?? "未命名.md", "path": url?.path as Any? ?? NSNull(), "encoding": source.encoding.rawValue, "dirty": dirty]
        if includeText { info["text"] = source.text }
        return info
    }
    func event(_ name: String, _ data: Any) {
        guard let json = try? JSONSerialization.data(withJSONObject: [name, data]), let value = String(data: json, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.nativeEvent?.(...\(value))", completionHandler: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let id = body["id"] as? Int, let action = body["action"] as? String else { return }
        let data = body["data"] as? [String: Any] ?? [:]
        do {
            let result: Any
            switch action {
            case "getPreferences":
                result = ["sidebarWidth": UserDefaults.standard.object(forKey: "sidebarWidth") as? Int ?? 228, "imagePasteMode": UserDefaults.standard.string(forKey: "imagePasteMode") ?? "directory"]
            case "setImagePasteMode":
                guard let mode = data["mode"] as? String, ["directory", "base64"].contains(mode) else { throw Self.error("图片粘贴方式无效。") }
                UserDefaults.standard.set(mode, forKey: "imagePasteMode"); result = true
            case "setSidebarWidth":
                guard let width = data["width"] as? Int, (180...420).contains(width) else { throw Self.error("侧栏宽度超出范围。") }
                UserDefaults.standard.set(width, forKey: "sidebarWidth"); result = true
            case "ready": var info = metadata(includeText: true); info["recovered"] = dirty; result = info
            case "change":
                guard let patches = data["patches"] as? [[String: Any]] else { throw SourceError.invalidRange }
                var text = source.text
                for patch in patches.sorted(by: { ($0["from"] as? Int ?? 0) > ($1["from"] as? Int ?? 0) }) {
                    guard let from = patch["from"] as? Int, let to = patch["to"] as? Int, let insert = patch["insert"] as? String, to >= from else { throw SourceError.invalidRange }
                    // NSString 的 UTF-16 坐标与 JavaScript 一致，不对周围文本做序列化或格式整理。
                    let ns = text as NSString
                    guard from >= 0, to <= ns.length else { throw SourceError.invalidRange }
                    text = ns.replacingCharacters(in: NSRange(location: from, length: to - from), with: insert)
                }
                source.text = text; window?.isDocumentEdited = dirty
                draftWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.persistDraft() }
                draftWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
                result = ["dirty": dirty]
            case "save", "saveAs": result = save(as: action == "saveAs") ? metadata() : NSNull()
            case "new": onNew?(); result = NSNull()
            case "open": onOpen?(); result = NSNull()
            case "reload":
                if dirty {
                    let alert = NSAlert(); alert.messageText = "重新载入并丢弃未保存的修改？"; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "重新载入")
                    guard alert.runModal() == .alertSecondButtonReturn else { reply(id, NSNull()); return }
                }
                if let url { let bytes = try Data(contentsOf: url); source = try SourceFile(data: bytes); baseline = bytes; try recovery.remove(recordID); window?.isDocumentEdited = false }
                result = metadata(includeText: true)
            case "imageURL":
                guard let path = data["path"] as? String else { throw SourceError.invalidRange }
                if path.hasPrefix("https://") || path.hasPrefix("http://") || path.hasPrefix("data:image/") { result = path }
                else {
                    guard let imageURL = Markdown.resolvedURL(path, base: url?.deletingLastPathComponent()), imageURL.isFileURL else { throw Self.error("无法解析图片位置，请先保存文档。") }
                    let bytes = try Data(contentsOf: imageURL)
                    let mime = UTType(filenameExtension: imageURL.pathExtension)?.preferredMIMEType ?? "image/png"
                    result = "data:\(mime);base64,\(bytes.base64EncodedString())"
                }
            case "chooseImages":
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
                guard panel.runModal() == .OK else { reply(id, NSNull()); return }
                guard UserDefaults.standard.string(forKey: "imagePasteMode") == "base64" || ensureSaved() else { reply(id, NSNull()); return }
                result = try panel.urls.map { file in ["name": file.deletingPathExtension().lastPathComponent, "path": try importImage(Data(contentsOf: file), name: file.lastPathComponent)] }
            case "importImage":
                guard let raw = data["data"] as? String, let bytes = Data(base64Encoded: raw), let name = data["name"] as? String else { throw Self.error("图片数据无效。") }
                guard UserDefaults.standard.string(forKey: "imagePasteMode") == "base64" || ensureSaved() else { reply(id, NSNull()); return }
                result = try importImage(bytes, name: name)
            case "openLink":
                if let path = data["path"] as? String, let target = Markdown.resolvedURL(path, base: url?.deletingLastPathComponent()) { NSWorkspace.shared.open(target) }
                result = NSNull()
            case "export":
                guard let html = data["html"] as? String, let format = data["format"] as? String else { throw Self.error("导出内容无效。") }
                let panel = NSSavePanel(); panel.allowedContentTypes = [format == "pdf" ? .pdf : .html]
                panel.nameFieldStringValue = (url?.deletingPathExtension().lastPathComponent ?? "未命名") + "." + format
                guard panel.runModal() == .OK, let destination = panel.url else { reply(id, NSNull()); return }
                if format == "html" { try html.write(to: destination, atomically: true, encoding: .utf8); result = true }
                else {
                    exporter = WebPDFExporter(html: html, destination: destination) { [weak self] error in
                        self?.reply(id, error == nil, error: error?.localizedDescription); self?.exporter = nil
                    }; return
                }
            default: throw Self.error("不支持的操作：\(action)")
            }
            reply(id, result)
        } catch { reply(id, NSNull(), error: error.localizedDescription) }
    }
    func reply(_ id: Int, _ result: Any, error: String? = nil) {
        let values: [Any] = [id, result, error as Any? ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: values), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.nativeReply(...\(json))", completionHandler: nil)
    }
    func ensureSaved() -> Bool {
        if url != nil { return true }
        let alert = NSAlert(); alert.messageText = "先保存文档以确定图片位置"; alert.informativeText = "图片将保存在 Markdown 文件所在目录。"; alert.addButton(withTitle: "保存文档"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let saved = save(); if saved { event("metadata", metadata()) }; return saved
    }
    func importImage(_ bytes: Data, name: String) throws -> String {
        guard NSImage(data: bytes) != nil else { throw Self.error("无法读取图片。") }
        if UserDefaults.standard.string(forKey: "imagePasteMode") == "base64" {
            let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "image/png"
            return "data:\(mime);base64,\(bytes.base64EncodedString())"
        }
        guard let url else { throw Self.error("请先保存文档。") }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = (name as NSString).pathExtension.isEmpty ? "png" : (name as NSString).pathExtension
        let filename = "image-\(UUID().uuidString.prefix(8)).\(ext)"
        try bytes.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return filename
    }
    // 保存基于磁盘字节基线；外部冲突必须由用户选择，不静默覆盖。
    func save(as saveAs: Bool = false) -> Bool {
        var destination = url
        if saveAs || destination == nil {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = url?.lastPathComponent ?? "未命名.md"
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            destination = chosen
        }
        guard let destination else { return false }
        let same = destination.standardizedFileURL == url?.standardizedFileURL
        do {
            if !same, let old = url?.deletingLastPathComponent(), old != destination.deletingLastPathComponent() {
                guard try copyAssets(from: old, to: destination.deletingLastPathComponent()) else { return false }
            }
            try FileStore.save(source, to: destination, expected: same ? baseline : nil, overwrite: !same)
            url = destination; baseline = source.data; window?.isDocumentEdited = false; window?.title = destination.lastPathComponent
            try recovery.remove(recordID); return true
        } catch SourceError.conflict {
            let alert = NSAlert(); alert.messageText = "磁盘文件已被修改"; alert.informativeText = "选择另存为以保留两个版本，或明确覆盖磁盘版本。"; alert.addButton(withTitle: "另存为"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "覆盖磁盘版本")
            let answer = alert.runModal()
            if answer == .alertFirstButtonReturn { return save(as: true) }
            if answer == .alertThirdButtonReturn {
                do { try FileStore.save(source, to: destination, expected: nil, overwrite: true); baseline = source.data; window?.isDocumentEdited = false; try recovery.remove(recordID); return true } catch { NSAlert(error: error).runModal() }
            }; return false
        } catch SourceError.missingFile {
            let alert = NSAlert(); alert.messageText = "原文件已移动或删除"; alert.addButton(withTitle: "另存为"); alert.addButton(withTitle: "取消")
            return alert.runModal() == .alertFirstButtonReturn ? save(as: true) : false
        } catch { NSAlert(error: error).runModal(); return false }
    }
    func copyAssets(from old: URL, to new: URL) throws -> Bool {
        let refs = Markdown.matches(#"!\[[^\]]*\]\((?:<([^>]+)>|([^\s]+?))\)"#, in: source.text).compactMap { m -> String? in
            let ns = source.text as NSString, p = ns.substring(with: m.range(at: m.range(at: 1).location == NSNotFound ? 2 : 1))
            return URL(string: p)?.scheme == nil && !p.hasPrefix("/") ? p.removingPercentEncoding ?? p : nil
        }
        if refs.isEmpty { return true }
        let alert = NSAlert(); alert.messageText = "将相对路径图片复制到新位置？"; alert.addButton(withTitle: "复制图片"); alert.addButton(withTitle: "仅保存文档"); alert.addButton(withTitle: "取消")
        let answer = alert.runModal(); if answer == .alertSecondButtonReturn { return true }; if answer != .alertFirstButtonReturn { return false }
        for ref in Set(refs) {
            let from = old.appendingPathComponent(ref).standardizedFileURL, to = new.appendingPathComponent(ref).standardizedFileURL
            guard to.path.hasPrefix(new.standardizedFileURL.path + "/") else { throw Self.error("图片引用指向上级目录，请选择仅保存文档：\(ref)") }
            if FileManager.default.fileExists(atPath: to.path) { guard try Data(contentsOf: from) == Data(contentsOf: to) else { throw Self.error("目标已有不同的图片，未覆盖：\(ref)") }; continue }
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: from, to: to)
        }
        return true
    }
    func persistDraft() {
        do { if dirty { try recovery.write(RecoveryRecord(id: recordID, path: url?.path, source: source, baseline: baseline)) } else { try recovery.remove(recordID) } }
        catch { event("error", "恢复草稿写入失败：" + error.localizedDescription) }
    }
    func canClose() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "保存对“\(url?.lastPathComponent ?? "未命名.md")”的修改？"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "不保存")
        switch alert.runModal() { case .alertFirstButtonReturn: return save(); case .alertThirdButtonReturn: return true; default: return false }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canClose() }
    func windowWillClose(_ notification: Notification) {
        closed = true; watch?.invalidate(); draftWork?.cancel(); web.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
        do { try recovery.remove(recordID) } catch { NSAlert(error: error).runModal() }; onClose?()
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated { if let url = action.request.url, ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }; decisionHandler(.cancel) }
        else { decisionHandler(action.request.url?.isFileURL == true || action.request.url?.scheme == "about" ? .allow : .cancel) }
    }
    static func error(_ text: String) -> NSError { NSError(domain: "MarkdownNative", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
