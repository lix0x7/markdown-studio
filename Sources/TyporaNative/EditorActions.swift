import AppKit
import UniformTypeIdentifiers
import MarkdownCore

extension EditorWindowController {
    func editLink() {
        let selection = editor.selectedRange(), ns = editor.string as NSString
        var target = selection, label = ns.substring(with: selection), path = "https://"
        for m in Markdown.matches(#"!?\[([^\]]*)\]\((?:<([^>]+)>|([^\s]+?))\)"#, in: editor.string) where NSLocationInRange(selection.location, m.range) {
            target = m.range; label = ns.substring(with: m.range(at: 1)); path = ns.substring(with: m.range(at: m.range(at: 2).location == NSNotFound ? 3 : 2)); break
        }
        let alert = NSAlert(); alert.messageText = "编辑链接 / 图片引用"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        let title = NSTextField(string: label), destination = NSTextField(string: path)
        title.placeholderString = "显示文字 / 图片替代文本"; destination.placeholderString = "URL 或相对文件路径"
        title.widthAnchor.constraint(equalToConstant: 420).isActive = true; destination.widthAnchor.constraint(equalToConstant: 420).isActive = true
        stack.addArrangedSubview(title); stack.addArrangedSubview(destination); alert.accessoryView = stack
        alert.addButton(withTitle: "应用"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let image = ns.substring(with: target).hasPrefix("![") ? "!" : ""
        let text = title.stringValue.replacingOccurrences(of: "]", with: "\\]")
        let reference = destination.stringValue.replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "<", with: "%3C")
        apply([TextEdit(range: target, replacement: "\(image)[\(text)](<\(reference)>)")], name: "编辑链接")
    }
    func editCodeFence() {
        let selection = editor.selectedRange()
        let fence = Markdown.fences(editor.string).first { NSLocationInRange(selection.location, $0.range) }
        let alert = NSAlert(); alert.messageText = fence == nil ? "插入代码块" : "设置代码语言"
        let choice = NSComboBox(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        choice.addItems(withObjectValues: ["text", "swift", "go", "python", "javascript", "typescript", "json", "bash", "rust", "sql", "c", "cpp", "java"])
        choice.stringValue = fence?.language ?? "text"; alert.accessoryView = choice
        alert.addButton(withTitle: "应用"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let language = choice.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard language.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !language.contains("`"), !language.contains("~") else { NSSound.beep(); return }
        if let fence { apply([TextEdit(range: fence.languageRange, replacement: language)], name: "设置代码语言"); return }
        let ending = SourceFile(text: editor.string).newline
        let selected = (editor.string as NSString).substring(with: selection)
        let runs = Markdown.matches("`+", in: selected).map { $0.range.length }.max() ?? 0
        let marker = String(repeating: "`", count: max(3, runs + 1))
        let prefix = selection.location > 0 && !(editor.string as NSString).substring(to: selection.location).hasSuffix(ending) ? ending : ""
        let code = prefix + marker + language + ending + selected + ending + marker + ending
        apply([TextEdit(range: selection, replacement: code)], name: "插入代码块", selection: NSRange(location: selection.location + prefix.utf16.count + marker.utf16.count + language.utf16.count + ending.utf16.count, length: selected.utf16.count))
    }
    func editTable() {
        if let table = MarkdownTable(text: editor.string, at: editor.selectedRange().location), let window {
            tableSheet = TableSheet(model: table) { [weak self] edits in self?.apply(edits, name: "编辑表格") }
            tableSheet?.present(on: window)
        } else {
            let selection = editor.selectedRange(), ending = SourceFile(text: editor.string).newline
            let prefix = selection.location == 0 ? "" : ending
            apply([TextEdit(range: selection, replacement: prefix + MarkdownTable.template(newline: ending))], name: "插入表格")
        }
    }
    func navigateCell(backwards: Bool) -> Bool {
        let selection = editor.selectedRange()
        guard let table = MarkdownTable(text: editor.string, at: selection.location) else { return false }
        let lines = Markdown.lines(editor.string).filter { NSLocationInRange($0.range.location, table.range) }
        let ranges = lines.enumerated().filter { $0.offset != 1 }.flatMap { _, line in
            MarkdownTable.cells(line.text).map { NSRange(location: line.range.location + $0.range.location, length: $0.range.length) }
        }
        guard !ranges.isEmpty else { return false }
        let current = ranges.lastIndex(where: { $0.location <= selection.location }) ?? 0
        let next = (current + (backwards ? -1 : 1) + ranges.count) % ranges.count
        editor.setSelectedRange(ranges[next]); editor.scrollRangeToVisible(ranges[next]); return true
    }
    func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        insertImages(panel.urls)
    }
    private func assetDirectory() -> URL? {
        if fileURL == nil {
            let alert = NSAlert(); alert.messageText = "先保存文档以确定图片位置"
            alert.informativeText = "图片会复制到 Markdown 同目录下的 assets 文件夹，并使用相对路径引用。"
            alert.addButton(withTitle: "保存文档"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn, save() else { return nil }
        }
        guard let fileURL else { return nil }
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory }
        catch { present(error); return nil }
    }
    func insertImages(_ urls: [URL]) {
        guard let directory = assetDirectory() else { return }
        do {
            var references: [String] = []
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent + "-" + String(UUID().uuidString.prefix(8)) + "." + url.pathExtension
                let destination = directory.appendingPathComponent(name)
                try FileManager.default.copyItem(at: url, to: destination)
                let path = "assets/" + name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
                references.append("![\(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "]", with: "\\]"))](<\(path)>)")
            }
            let ending = SourceFile(text: editor.string).newline
            apply([TextEdit(range: editor.selectedRange(), replacement: ending + references.joined(separator: ending + ending) + ending)], name: "插入图片")
        } catch { present(error) }
    }
    func insertPastedImage(_ data: Data) {
        guard let directory = assetDirectory() else { return }
        do {
            let name = "image-" + UUID().uuidString + ".png"
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            let ending = SourceFile(text: editor.string).newline
            apply([TextEdit(range: editor.selectedRange(), replacement: ending + "![图片](assets/\(name))" + ending)], name: "粘贴图片")
        } catch { present(error) }
    }
    // 跨目录另存为时复制相对资源，不覆盖已有的不同内容。
    func copyRelativeImages(from old: URL, to new: URL) -> Bool {
        let refs = Markdown.matches(#"!\[[^\]]*\]\((?:<([^>]+)>|([^\s]+?))(?:\s+\"[^\"]*\")?\)"#, in: editor.string).compactMap { match -> String? in
            let ns = editor.string as NSString
            let raw = ns.substring(with: match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1))
            guard URL(string: raw)?.scheme == nil, !raw.hasPrefix("/") else { return nil }
            return raw.removingPercentEncoding ?? raw
        }
        guard !refs.isEmpty else { return true }
        let alert = NSAlert(); alert.messageText = "将相对路径图片一起复制到新位置？"
        alert.informativeText = "复制图片会保持 Markdown 引用原文。若选择仅保存文档，需自行确保新位置的图片路径有效。"
        alert.addButton(withTitle: "复制图片"); alert.addButton(withTitle: "仅保存文档"); alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn { return true }
        guard response == .alertFirstButtonReturn else { return false }
        do {
            for ref in Set(refs) {
                let from = old.appendingPathComponent(ref).standardizedFileURL, to = new.appendingPathComponent(ref).standardizedFileURL
                guard to.path.hasPrefix(new.standardizedFileURL.path + "/") else {
                    throw NSError(domain: "TyporaNative", code: 1, userInfo: [NSLocalizedDescriptionKey: "图片引用包含上级目录：\(ref)。请选择仅保存文档，或先调整图片引用。"])
                }
                if FileManager.default.fileExists(atPath: to.path) {
                    guard try Data(contentsOf: from) == Data(contentsOf: to) else {
                        throw NSError(domain: "TyporaNative", code: 2, userInfo: [NSLocalizedDescriptionKey: "新位置已有不同的图片：\(ref)，未覆盖。"])
                    }
                    continue
                }
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: from, to: to)
            }
            return true
        } catch { present(error); return false }
    }
    private func exportURL(extension ext: String, type: UTType) -> URL? {
        let panel = NSSavePanel(); panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "未命名") + "." + ext
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
    func exportHTML() {
        guard let url = exportURL(extension: "html", type: .html) else { return }
        do {
            try HTMLExporter.validateLocalImages(editor.string, base: fileURL?.deletingLastPathComponent())
            let html = HTMLExporter.document(editor.string, title: fileURL?.lastPathComponent ?? "未命名", base: fileURL?.deletingLastPathComponent())
            try html.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { present(error) }
    }
    func exportPDF() {
        guard let url = exportURL(extension: "pdf", type: .pdf) else { return }
        do {
            try PDFExporter.write(editor.string, title: fileURL?.lastPathComponent ?? "未命名", base: fileURL?.deletingLastPathComponent(), to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { present(error) }
    }
}
