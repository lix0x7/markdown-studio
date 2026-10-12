import AppKit
import PDFKit
import MarkdownCore

// 集成验证直接驱动真实 AppKit 编辑器，检查预览、撤销、输入法与导出的数据完整性。
enum NativeSmoke {
    static func run(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: "NativeSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            print("PASS: \(message)")
        }
        let file = root.appendingPathComponent("roundtrip.md")
        let original = "# 中文标题\r\n\r\n**bold** with *italic* and ~~deleted~~.  \r\n\r\n| a  | b |\r\n|:---|---:|\r\n| old   | value |\r\n\r\n```swift\r\nlet value = 42\r\n```\r\n\r\n[link](https://example.com)\r\n"
        let data = SourceFile(text: original, encoding: .utf8BOM).data
        try data.write(to: file)
        let controller = try EditorWindowController(url: file, recovery: RecoveryStore(directory: root.appendingPathComponent("Recovery")))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let editor = controller.editor
        print("Editor inset: \(editor.textContainerInset), frame: \(editor.frame), visible: \(editor.visibleRect)")
        editor.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
        controller.refresh()
        try check(editor.string == original, "Live preview leaves exact source unchanged")
        controller.toggleMode(); controller.toggleMode()
        try check(editor.string == original && !controller.isDirty, "Source/preview toggle creates no document edits")
        let selected = (editor.string as NSString).range(of: "value |")
        editor.setSelectedRange(NSRange(location: selected.location, length: 5))
        controller.command("bold")
        try check(editor.string == original.replacingOccurrences(of: "value |", with: "**value** |"), "Native formatting changes selected source only")
        editor.undoManager?.undo()
        try check(editor.string == original, "Native undo restores exact CRLF source")
        editor.undoManager?.redo()
        try check(editor.string.contains("**value** |"), "Native redo restores formatting")
        editor.undoManager?.undo()
        editor.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        let composing = editor.string
        controller.refresh()
        try check(editor.hasMarkedText() && editor.string == composing, "Live styling does not interrupt marked text")
        editor.insertText("拼音", replacementRange: editor.markedRange())
        try check(!editor.hasMarkedText() && editor.string.hasSuffix("拼音"), "IME commit inserts composed text once")
        controller.flushRecovery()
        let recovered = try RecoveryStore(directory: root.appendingPathComponent("Recovery")).records()
        try check(recovered.count == 1 && recovered[0].source.text == editor.string, "Native edits persist a recoverable draft")
        try check(controller.save(), "Native document save succeeds")
        let saved = try Data(contentsOf: file)
        try check(saved == SourceFile(text: original + "拼音", encoding: .utf8BOM).data, "Native save preserves BOM and original unchanged bytes")
        let html = HTMLExporter.document(original, title: "Smoke", base: root)
        try html.write(to: root.appendingPathComponent("export.html"), atomically: true, encoding: .utf8)
        let pdfURL = root.appendingPathComponent("export.pdf")
        try PDFExporter.write(original + String(repeating: "\n\n分页验证 paragraph text.\n", count: 65), title: "Smoke", base: root, to: pdfURL)
        guard let pdf = PDFDocument(url: pdfURL) else { throw NSError(domain: "NativeSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "PDF cannot be read"]) }
        try check(pdf.pageCount > 1, "PDF export paginates long documents")
        try check(pdf.string?.precomposedStringWithCompatibilityMapping.contains("中文标题") == true && pdf.string?.contains("paragraph text") == true, "PDF contains selectable Chinese and Latin text")
        let afterExport = try Data(contentsOf: file)
        try check(afterExport == saved, "Exports do not modify the source file")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        controller.insertPastedImage(png)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        controller.refresh()
        var renderedImages = 0
        editor.textStorage?.enumerateAttribute(.markdownImage, in: NSRange(location: 0, length: editor.string.utf16.count)) { value, _, _ in if value is NSImage { renderedImages += 1 } }
        try check(renderedImages == 1, "Pasted image is copied to assets and rendered natively")
        try check(HTMLExporter.document(editor.string, title: "Image", base: root).contains("data:image/png;base64,"), "HTML export embeds local image data")
        let rowTable = editor.textStorage?.attribute(.markdownTableRow, at: (editor.string as NSString).range(of: "| a").location, effectiveRange: nil)
        try check(rowTable is TableRowPreview, "Inactive table uses native grid rendering")
        controller.close()
        let large = String(repeating: "普通段落，保持原文。Markdown plain paragraph with words and spacing.  \n\n", count: 14000)
        let largeURL = root.appendingPathComponent("large.md")
        try large.write(to: largeURL, atomically: true, encoding: .utf8)
        let start = Date()
        let largeController = try EditorWindowController(url: largeURL, recovery: RecoveryStore(directory: root.appendingPathComponent("LargeRecovery")))
        print("Large file (\(large.utf8.count) bytes) open ms: \(Date().timeIntervalSince(start) * 1000)")
        let refreshStart = Date()
        largeController.refresh()
        print("Large file preview refresh ms: \(Date().timeIntervalSince(refreshStart) * 1000)")
        var timings: [Double] = []
        largeController.editor.setSelectedRange(NSRange(location: 20, length: 0))
        for _ in 0..<30 {
            let started = Date()
            largeController.editor.insertText("x", replacementRange: largeController.editor.selectedRange())
            largeController.refresh()
            timings.append(Date().timeIntervalSince(started) * 1000)
        }
        print("Large file edit + preview P95 ms (30 samples): \(timings.sorted()[28])")
        largeController.close()
        print("Native smoke checks completed. PDF pages: \(pdf.pageCount)")
    }
}
