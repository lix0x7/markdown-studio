import AppKit
import MarkdownCore

final class EditorTextView: NSTextView {
    var importImageFiles: (([URL]) -> Void)?
    var importImageData: ((Data) -> Void)?
    var newline: (() -> String)?
    var navigateCell: ((Bool) -> Bool)?

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !files.isEmpty, files.allSatisfy({ NSImage(contentsOf: $0) != nil }) {
            importImageFiles?(files); return
        }
        if board.string(forType: .string) == nil {
            if let data = board.data(forType: .png) { importImageData?(data); return }
            if let data = board.data(forType: .tiff), let image = NSBitmapImageRep(data: data), let png = image.representation(using: .png, properties: [:]) {
                importImageData?(png); return
            }
        }
        pasteAsPlainText(sender)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .copy }
        return super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, urls.allSatisfy({ NSImage(contentsOf: $0) != nil }) {
            let point = convert(sender.draggingLocation, from: nil)
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
            importImageFiles?(urls); return true
        }
        return super.performDragOperation(sender)
    }
    override func insertTab(_ sender: Any?) {
        if !hasMarkedText(), navigateCell?(false) == true { return }
        super.insertTab(sender)
    }
    override func insertBacktab(_ sender: Any?) {
        if !hasMarkedText(), navigateCell?(true) == true { return }
        super.insertBacktab(sender)
    }
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertNewline(sender); return }
        let ns = string as NSString, selection = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        let ending = newline?() ?? "\n"
        // 列表续行只在当前项尾部执行；空项退回普通段落，不修改相邻行。
        if selection.length == 0, selection.location == lineRange.location + line.utf16.count,
           let match = Markdown.matches(#"^(\s*)([-+*]|\d+[.)]|>)[ \t]+(.*)$"#, in: line).first,
           !Markdown.fences(string).contains(where: { NSLocationInRange(selection.location, $0.range) }) {
            let current = line as NSString, content = current.substring(with: match.range(at: 3))
            if content.isEmpty { insertText("", replacementRange: NSRange(location: lineRange.location, length: line.utf16.count)); return }
            var marker = current.substring(with: match.range(at: 2))
            if let number = Int(marker.dropLast()) { marker = "\(number + 1)" + String(marker.last!) }
            let indent = current.substring(with: match.range(at: 1))
            insertText(ending + indent + marker + " ", replacementRange: selection); return
        }
        insertText(ending, replacementRange: selection)
    }
}

extension NSAttributedString.Key {
    static let markdownImage = NSAttributedString.Key("TyporaNativeImage")
    static let markdownTableRow = NSAttributedString.Key("TyporaNativeTableRow")
    static let markdownRule = NSAttributedString.Key("TyporaNativeRule")
}

final class TableRowPreview: NSObject {
    let cells: [String]
    let alignments: [String]
    let header: Bool
    init(cells: [String], alignments: [String], header: Bool) { self.cells = cells; self.alignments = alignments; self.header = header }
}

final class PreviewLayoutManager: NSLayoutManager {
    // 图片通过布局层绘制，底层 NSTextStorage 中始终保留 Markdown 引用原文。
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.markdownRule, in: chars) { value, range, _ in
            guard value != nil else { return }
            let line = self.lineFragmentRect(forGlyphAt: self.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            NSColor.separatorColor.setFill()
            NSRect(x: origin.x + line.minX, y: origin.y + line.midY, width: line.width, height: 1).fill()
        }
        storage.enumerateAttribute(.markdownTableRow, in: chars) { value, range, _ in
            guard let row = value as? TableRowPreview, !row.cells.isEmpty else { return }
            let line = self.lineFragmentRect(forGlyphAt: self.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            let width = max(100, line.width - 8) / CGFloat(row.cells.count)
            for (index, cell) in row.cells.enumerated() {
                let rect = NSRect(x: origin.x + line.minX + CGFloat(index) * width, y: origin.y + line.minY, width: width, height: line.height)
                (row.header ? NSColor.quaternaryLabelColor.withAlphaComponent(0.12) : NSColor.textBackgroundColor).setFill(); rect.fill()
                NSColor.separatorColor.setStroke(); NSBezierPath(rect: rect).stroke()
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = row.alignments[index] == "center" ? .center : row.alignments[index] == "right" ? .right : .left
                (cell as NSString).draw(in: rect.insetBy(dx: 10, dy: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: row.header ? .semibold : .regular), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph])
            }
        }
        storage.enumerateAttribute(.markdownImage, in: chars) { value, range, _ in
            guard let image = value as? NSImage, image.size.width > 0 else { return }
            let glyph = self.glyphIndexForCharacter(at: range.location)
            let line = self.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let width = min(image.size.width, max(80, line.width - 24))
            let scale = min(width / image.size.width, 360 / max(image.size.height, 1))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let frame = NSRect(x: origin.x + line.minX + 8, y: origin.y + line.minY + 8, width: size.width, height: size.height)
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}
