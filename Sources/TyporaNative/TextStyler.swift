import AppKit
import MarkdownCore
import OSLog

final class ImageCache {
    private let cache = NSCache<NSURL, NSImage>()
    private var loading: Set<URL> = []
    private var failures: Set<URL> = []
    private let logger = Logger(subsystem: "local.TyporaNative", category: "Images")
    var didLoad: (() -> Void)?
    init() {
        // 图片按估算像素成本设置缓存上限，避免长文图片常驻内存无限增长。
        cache.totalCostLimit = 64 * 1024 * 1024
    }
    func image(at url: URL) -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        if url.isFileURL {
            if let image = NSImage(contentsOf: url) { cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4)); return image }
            return nil
        }
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), !loading.contains(url), !failures.contains(url) else { return nil }
        loading.insert(url)
        let started = Date()
        logger.info("Image request started host=\(url.host ?? "", privacy: .public) path=\(url.path, privacy: .public)")
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let data, error == nil, (200..<300).contains(status), let image = NSImage(data: data) {
                    self.cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4))
                    self.logger.info("Image request completed host=\(url.host ?? "", privacy: .public) path=\(url.path, privacy: .public) status=\(status) duration_ms=\(Date().timeIntervalSince(started) * 1000)")
                } else {
                    self.failures.insert(url)
                    self.logger.error("Image request failed host=\(url.host ?? "", privacy: .public) path=\(url.path, privacy: .public) status=\(status) duration_ms=\(Date().timeIntervalSince(started) * 1000) error=\(error?.localizedDescription ?? "Invalid image response", privacy: .public)")
                }
                self.didLoad?()
            }
        }.resume()
        return nil
    }
}

final class TextStyler {
    let images = ImageCache()
    var sourceMode = false { didSet { resetAll = true } }
    private var resetAll = false
    var baseURL: URL?
    var isStyling = false
    private var cachedText = ""
    private var cachedLines: [SourceLine] = []
    private var cachedFences: [Fence] = []
    private(set) var headings: [Heading] = []
    private let inlineSymbols = CharacterSet(charactersIn: "*_`[~")
    private let bodyFont = NSFont.systemFont(ofSize: 16)
    private let codeFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 6
        return [.font: sourceMode ? codeFont : bodyFont, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
    }
    // 解析结果仅驱动显示属性，输入法组词期间跳过渲染以保留原生组合状态。
    func apply(to editor: NSTextView) {
        guard !isStyling, !editor.hasMarkedText(), let storage = editor.textStorage else { return }
        isStyling = true
        defer { isStyling = false }
        let text = editor.string, full = NSRange(location: 0, length: storage.length)
        let selection = editor.selectedRange()
        let active = Markdown.blockRange(in: text, selection: selection)
        // 长文只更新可见段落及当前选区的显示属性，避免输入时重排整篇文档。
        var renderRange = full
        if !resetAll, full.length > 100_000, let layout = editor.layoutManager, let container = editor.textContainer {
            let visible = editor.visibleRect.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y)
            let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
            let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let combined = NSUnionRange(characters, active)
            renderRange = (text as NSString).lineRange(for: combined.length < 30_000 ? combined : active)
        }
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: renderRange)
        resetAll = false
        defer { storage.endEditing(); editor.typingAttributes = baseAttributes }
        if !cachedText.utf8.elementsEqual(text.utf8) {
            cachedText = text
            let hasMarkup = text.utf8.contains { byte in
                switch byte { case 35, 96, 42, 95, 126, 91, 62, 124, 45: return true; default: return false }
            }
            cachedLines = hasMarkup ? Markdown.lines(text) : []
            cachedFences = hasMarkup ? Markdown.fences(text) : []
            headings = hasMarkup ? Markdown.headings(text) : []
        }
        guard !sourceMode, !text.isEmpty else { return }
        let fences = cachedFences
        let sourceLines = cachedLines
        var tableRows: [Int: TableRowPreview] = [:]
        var delimiterLines: Set<Int> = []
        var index = 0
        while index + 1 < sourceLines.count {
            let line = sourceLines[index]
            guard line.text.contains("|"), !fences.contains(where: { NSLocationInRange(line.range.location, $0.range) }) else { index += 1; continue }
            let columns = MarkdownTable.cells(line.text), separators = MarkdownTable.cells(sourceLines[index + 1].text)
            guard !columns.isEmpty, columns.count == separators.count,
                  separators.allSatisfy({ !Markdown.matches(#"^\s*:?-{3,}:?\s*$"#, in: $0.value).isEmpty }) else { index += 1; continue }
            var end = index + 2
            while end < sourceLines.count, MarkdownTable.cells(sourceLines[end].text).count == columns.count { end += 1 }
            let tableRange = NSRange(location: line.range.location, length: NSMaxRange(sourceLines[end - 1].range) - line.range.location)
            if NSIntersectionRange(tableRange, active).length == 0 {
                let alignment = separators.map { $0.value.hasSuffix(":") ? ($0.value.hasPrefix(":") ? "center" : "right") : "left" }
                for row in index..<end where row != index + 1 {
                    tableRows[sourceLines[row].range.location] = TableRowPreview(cells: MarkdownTable.cells(sourceLines[row].text).map(\.value), alignments: alignment, header: row == index)
                }
                delimiterLines.insert(sourceLines[index + 1].range.location)
            }
            index = end
        }
        func hidden(_ range: NSRange) {
            guard range.length > 0, NSIntersectionRange(active, range).length == 0 else { return }
            storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear], range: range)
        }
        for heading in headings where NSIntersectionRange(heading.range, renderRange).length > 0 {
            let sizes: [CGFloat] = [30, 25, 21, 19, 17, 16]
            storage.addAttributes([.font: NSFont.systemFont(ofSize: sizes[heading.level - 1], weight: .semibold)], range: heading.range)
            let line = (text as NSString).substring(with: heading.range)
            if let m = Markdown.matches(#"^ {0,3}#{1,6}\s+"#, in: line).first {
                hidden(NSRange(location: heading.range.location, length: m.range.length))
            }
        }
        for line in sourceLines {
            if NSIntersectionRange(line.range, renderRange).length == 0 { continue }
            if line.text.isEmpty { continue }
            if fences.contains(where: { NSLocationInRange(line.range.location, $0.range) }) { continue }
            if line.text.contains("!["), let imageRef = Markdown.imageReference(line.text),
               NSIntersectionRange(line.contentRange, active).length == 0,
               let url = Markdown.resolvedURL(imageRef.path, base: baseURL), let image = images.image(at: url) {
                let width = max(80, (editor.textContainer?.containerSize.width ?? 600) - 24)
                let scale = min(1, min(width / max(image.size.width, 1), 360 / max(image.size.height, 1)))
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = image.size.height * scale + 24
                paragraph.maximumLineHeight = paragraph.minimumLineHeight
                storage.addAttributes([.paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear, .markdownImage: image], range: line.contentRange)
                continue
            }
            if line.text.contains(">"), let quote = Markdown.matches(#"^\s*>\s?"#, in: line.text).first {
                let paragraph = NSMutableParagraphStyle()
                paragraph.headIndent = 20; paragraph.firstLineHeadIndent = 20; paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 6
                storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph], range: line.contentRange)
                hidden(NSRange(location: line.range.location, length: quote.range.length))
            }
            if let row = tableRows[line.range.location] {
                let width = max(80, ((editor.textContainer?.containerSize.width ?? 600) - 8) / CGFloat(row.cells.count) - 20)
                let height = row.cells.map { ($0 as NSString).boundingRect(with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 14, weight: row.header ? .semibold : .regular)]).height }.max() ?? 20
                let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = max(36, ceil(height) + 16); paragraph.maximumLineHeight = paragraph.minimumLineHeight
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear, .paragraphStyle: paragraph, .markdownTableRow: row], range: line.contentRange)
                continue
            }
            if delimiterLines.contains(line.range.location) {
                let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 0.01; paragraph.maximumLineHeight = 0.01
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear, .paragraphStyle: paragraph], range: line.range)
                continue
            }
            if line.text.contains("---") || line.text.contains("***") || line.text.contains("___"),
               !Markdown.matches(#"^ {0,3}(?:\*\s*){3,}$|^ {0,3}(?:-\s*){3,}$|^ {0,3}(?:_\s*){3,}$"#, in: line.text).isEmpty,
               NSIntersectionRange(line.contentRange, active).length == 0 {
                let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 24
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear, .paragraphStyle: paragraph, .markdownRule: true], range: line.contentRange)
                continue
            }
            if line.text.rangeOfCharacter(from: inlineSymbols) != nil { styleInline(line, storage: storage, active: active) }
        }
        for fence in fences where NSIntersectionRange(fence.range, renderRange).length > 0 {
            storage.addAttributes([.font: codeFont, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)], range: NSIntersectionRange(fence.range, renderRange))
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: fence.opening.contentRange)
            if NSIntersectionRange(active, fence.range).length == 0 {
                hidden(fence.opening.contentRange)
                let last = Markdown.lines((text as NSString).substring(with: fence.range)).last
                if let last, last.range.location > 0, !Markdown.matches(#"^\s*(`{3,}|~{3,})\s*$"#, in: last.text).isEmpty {
                    hidden(NSRange(location: fence.range.location + last.contentRange.location, length: last.contentRange.length))
                }
            }
            let visibleCode = NSIntersectionRange(fence.bodyRange, renderRange)
            if visibleCode.length > 0 { highlightCode((text as NSString).substring(with: visibleCode), offset: visibleCode.location, language: fence.language, storage: storage) }
        }
    }
    private func styleInline(_ line: SourceLine, storage: NSTextStorage, active: NSRange) {
        let ns = line.text as NSString
        let codeRanges = Markdown.matches(#"(`+)(.+?)\1"#, in: line.text).map(\.range)
        let patterns: [(String, String)] = [
            (#"\*\*(.+?)\*\*|__(.+?)__"#, "bold"),
            (#"(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!\w)_([^_\n]+)_(?!\w)"#, "italic"),
            (#"~~(.+?)~~"#, "strike"),
            (#"(`+)(.+?)\1"#, "code")
        ]
        for (pattern, kind) in patterns {
            for m in Markdown.matches(pattern, in: line.text) {
                if kind != "code", codeRanges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
                let group = kind == "code" ? 2 : (m.range(at: 1).location == NSNotFound ? 2 : 1)
                let inner = m.range(at: group)
                let absolute = NSRange(location: line.range.location + inner.location, length: inner.length)
                switch kind {
                case "bold":
                    let font = storage.attribute(.font, at: absolute.location, effectiveRange: nil) as? NSFont ?? bodyFont
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: absolute)
                case "italic":
                    let font = storage.attribute(.font, at: absolute.location, effectiveRange: nil) as? NSFont ?? bodyFont
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: absolute)
                case "strike": storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: absolute)
                default: storage.addAttributes([.font: codeFont, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)], range: absolute)
                }
                let whole = NSRange(location: line.range.location + m.range.location, length: m.range.length)
                if NSIntersectionRange(active, whole).length == 0 {
                    let prefix = NSRange(location: whole.location, length: absolute.location - whole.location)
                    let suffix = NSRange(location: NSMaxRange(absolute), length: NSMaxRange(whole) - NSMaxRange(absolute))
                    for range in [prefix, suffix] { storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear], range: range) }
                }
            }
        }
        for m in Markdown.matches(#"(?<!!)\[([^\]]+)\]\((?:<([^>]+)>|([^\s]+?))(?:\s+\"[^\"]*\")?\)"#, in: line.text) {
            if codeRanges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
            let inner = m.range(at: 1), raw = ns.substring(with: m.range(at: m.range(at: 2).location == NSNotFound ? 3 : 2))
            let range = NSRange(location: line.range.location + inner.location, length: inner.length)
            storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .link: raw], range: range)
            if NSIntersectionRange(active, line.contentRange).length == 0 {
                for relative in [NSRange(location: m.range.location, length: inner.location - m.range.location), NSRange(location: NSMaxRange(inner), length: NSMaxRange(m.range) - NSMaxRange(inner))] {
                    storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear], range: NSRange(location: line.range.location + relative.location, length: relative.length))
                }
            }
        }
    }
    private func highlightCode(_ code: String, offset: Int, language: String, storage: NSTextStorage) {
        let known = ["swift", "go", "python", "py", "javascript", "js", "typescript", "ts", "json", "bash", "sh", "rust", "c", "cpp", "java", "sql"]
        guard known.contains(language.lowercased()) else { return }
        for (pattern, color) in [
            (#"\b(?:let|var|func|function|return|if|else|for|while|class|struct|enum|import|from|def|const|public|private|guard|throw|try|async|await|true|false|null|nil|None|package|type|SELECT|FROM|WHERE)\b"#, NSColor.systemPurple),
            (#"\b\d+(?:\.\d+)?\b"#, NSColor.systemOrange),
            (#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, NSColor.systemRed),
            (#"(?m)//[^\r\n]*|^[ \t]*#[^\r\n]*"#, NSColor.systemGreen)
        ] {
            for match in Markdown.matches(pattern, in: code) {
                storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: offset + match.range.location, length: match.range.length))
            }
        }
    }
}
