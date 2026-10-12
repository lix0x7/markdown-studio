import Foundation

public enum HTMLExporter {
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    public static func validateLocalImages(_ text: String, base: URL?) throws {
        let fences = Markdown.fences(text)
        let code = Markdown.matches(#"(`+)([^\r\n]+?)\1"#, in: text).map(\.range)
        for match in Markdown.matches(#"!\[[^\]]*\]\((?:<([^>]+)>|([^\s]+?))(?:\s+\"[^\"]*\")?\)"#, in: text) {
            if fences.contains(where: { NSLocationInRange(match.range.location, $0.range) }) || code.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
            let ns = text as NSString
            let raw = ns.substring(with: match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1))
            guard let url = Markdown.resolvedURL(raw, base: base), url.scheme != "mailto" else {
                throw NSError(domain: "MarkdownExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法解析图片引用：\(raw)。相对路径需要先保存文档。"])
            }
            if url.isFileURL, !FileManager.default.isReadableFile(atPath: url.path) {
                throw NSError(domain: "MarkdownExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "找不到或无法读取图片：\(raw)。请修复引用后再导出。"])
            }
        }
    }
    public static func document(_ text: String, title: String, base: URL?) -> String {
        """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title><style>
        body{font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;max-width:800px;margin:48px auto;padding:0 32px;color:#20252b;line-height:1.7;overflow-wrap:anywhere}
        h1,h2,h3,h4,h5,h6{line-height:1.3;page-break-after:avoid}h1{font-size:32px}h2{font-size:26px;border-bottom:1px solid #ddd;padding-bottom:8px}
        pre,code{font-family:Menlo,monospace;font-size:13px;background:#f3f4f5}pre{padding:16px;white-space:pre-wrap}blockquote{border-left:3px solid #7b9894;margin-left:0;padding-left:20px;color:#52625f}
        table{border-collapse:collapse;width:100%}th,td{border:1px solid #dce1e2;padding:8px;text-align:left}th{background:#f3f4f5}img{max-width:100%;height:auto}a{color:#256d68}hr{border:0;border-top:1px solid #ddd}
        @media print{body{margin:0;padding:0}pre,tr,img{page-break-inside:avoid}}
        </style></head><body>\(body(text, base: base))</body></html>
        """
    }

    // 导出解析只生成新产物，绝不回写原始 Markdown。原始 HTML 按文本转义。
    public static func body(_ text: String, base: URL?) -> String {
        let lines = Markdown.lines(text), fences = Markdown.fences(text)
        var output = "", i = 0, headingCounts: [String: Int] = [:]
        while i < lines.count {
            let line = lines[i], value = line.text
            if value.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            if let fence = fences.first(where: { $0.range.location == line.range.location }) {
                let code = (text as NSString).substring(with: fence.bodyRange)
                output += "<pre><code class=\"language-\(escape(fence.language))\">\(escape(code))</code></pre>\n"
                i += 1
                while i < lines.count, lines[i].range.location < NSMaxRange(fence.range) { i += 1 }
                continue
            }
            if let table = MarkdownTable(text: text, at: line.range.location), table.range.location == line.range.location {
                output += "<table><thead>"
                for (rowIndex, row) in table.rows.enumerated() {
                    if rowIndex == 1 { output += "</thead><tbody>" }
                    let tag = rowIndex == 0 ? "th" : "td"
                    output += "<tr>" + row.enumerated().map { column, cell in
                        "<\(tag) style=\"text-align:\(table.alignments[column])\">\(inline(cell, base: base))</\(tag)>"
                    }.joined() + "</tr>"
                }
                output += table.rows.count > 1 ? "</tbody></table>\n" : "</thead></table>\n"
                while i < lines.count, lines[i].range.location < NSMaxRange(table.range) { i += 1 }
                continue
            }
            if let m = Markdown.matches(#"^ {0,3}(#{1,6})[ \t]+(.+?)\s*#*\s*$"#, in: value).first {
                let title = (value as NSString).substring(with: m.range(at: 2)), level = m.range(at: 1).length
                let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
                let count = headingCounts[slug, default: 0]; headingCounts[slug] = count + 1
                let id = slug + (count == 0 ? "" : "-\(count)")
                output += "<h\(level) id=\"\(escape(id))\">\(inline(title, base: base))</h\(level)>\n"; i += 1; continue
            }
            if !Markdown.matches(#"^ {0,3}(?:\*\s*){3,}$|^ {0,3}(?:-\s*){3,}$|^ {0,3}(?:_\s*){3,}$"#, in: value).isEmpty {
                output += "<hr>\n"; i += 1; continue
            }
            if !Markdown.matches(#"^\s*>"#, in: value).isEmpty {
                var quote = ""
                while i < lines.count, let m = Markdown.matches(#"^\s*> ?"#, in: lines[i].text).first {
                    quote += (lines[i].text as NSString).substring(from: NSMaxRange(m.range)) + "\n"; i += 1
                }
                output += "<blockquote>\(body(quote, base: base))</blockquote>\n"; continue
            }
            if let first = listMatch(value) {
                let ordered = Int(first.marker.dropLast()) != nil, tag = ordered ? "ol" : "ul"
                output += "<\(tag)\(ordered ? " start=\"\(Int(first.marker.dropLast()) ?? 1)\"" : "")>"
                while i < lines.count, let item = listMatch(lines[i].text), item.indent == first.indent,
                      (Int(item.marker.dropLast()) != nil) == ordered {
                    var content = item.content + "\n"; i += 1
                    while i < lines.count {
                        let next = lines[i].text
                        if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                        let indentation = next.prefix { $0 == " " || $0 == "\t" }.count
                        guard indentation > first.indent else { break }
                        content += String(next.dropFirst(min(indentation, first.indent + item.marker.count + 1))) + "\n"; i += 1
                    }
                    output += "<li>\(body(content, base: base))</li>"
                }
                output += "</\(tag)>\n"; continue
            }
            var paragraph = value; i += 1
            while i < lines.count, !lines[i].text.isEmpty,
                  Markdown.matches(#"^\s*(?:#{1,6}\s|>|`{3,}|~{3,}|[-+*]\s|\d+[.)]\s|\|)"#, in: lines[i].text).isEmpty {
                if paragraph.hasSuffix("  ") { paragraph += "\n" } else { paragraph += " " }
                paragraph += lines[i].text; i += 1
            }
            output += "<p>\(inline(paragraph, base: base))</p>\n"
        }
        return output
    }
    private static func listMatch(_ text: String) -> (indent: Int, marker: String, content: String)? {
        guard let m = Markdown.matches(#"^(\s*)([-+*]|\d+[.)])\s+(.*)$"#, in: text).first else { return nil }
        let ns = text as NSString
        return (m.range(at: 1).length, ns.substring(with: m.range(at: 2)), ns.substring(with: m.range(at: 3)))
    }
    // 优先处理转义和行内代码，再递归渲染格式；不直接执行原始 HTML。
    public static func inline(_ text: String, base: URL?, depth: Int = 0) -> String {
        if depth > 16 { return escape(text) }
        let patterns: [(String, String)] = [
            (#"\\([\\`*{}\[\]()#+\-.!_>|~])"#, "escape"),
            (#"(`+)(.+?)\1"#, "code"),
            (#"!\[([^\]]*)\]\((?:<([^>]+)>|([^\s]+?))(?:\s+\"[^\"]*\")?\)"#, "image"),
            (#"\[([^\]]+)\]\((?:<([^>]+)>|([^\s]+?))(?:\s+\"[^\"]*\")?\)"#, "link"),
            (#"\*\*(.+?)\*\*|__(.+?)__"#, "strong"),
            (#"~~(.+?)~~"#, "del"),
            (#"\*([^*\n]+)\*|(?<!\w)_([^_\n]+)_(?!\w)"#, "em")
        ]
        let ns = text as NSString
        var earliest: (NSTextCheckingResult, String)?
        for (pattern, kind) in patterns {
            if let m = Markdown.matches(pattern, in: text).first,
               earliest == nil || m.range.location < earliest!.0.range.location { earliest = (m, kind) }
        }
        guard let (m, kind) = earliest else { return escape(text).replacingOccurrences(of: "  \n", with: "<br>\n") }
        let prefix = escape(ns.substring(to: m.range.location)).replacingOccurrences(of: "  \n", with: "<br>\n")
        let suffix = inline(ns.substring(from: NSMaxRange(m.range)), base: base, depth: depth)
        var rendered = ""
        switch kind {
        case "escape": rendered = escape(ns.substring(with: m.range(at: 1)))
        case "code": rendered = "<code>\(escape(ns.substring(with: m.range(at: 2))))</code>"
        case "image", "link":
            let raw = ns.substring(with: m.range(at: m.range(at: 2).location == NSNotFound ? 3 : 2))
            let label = ns.substring(with: m.range(at: 1))
            if kind == "link", raw.hasPrefix("#") {
                rendered = "<a href=\"\(escape(raw))\">\(inline(label, base: base, depth: depth + 1))</a>"
            } else if let url = Markdown.resolvedURL(raw, base: base) {
                if kind == "image" {
                    var src = url.absoluteString
                    if url.isFileURL, let data = try? Data(contentsOf: url) {
                        let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml", "tiff": "image/tiff"][url.pathExtension.lowercased()] ?? "application/octet-stream"
                        src = "data:\(mime);base64,\(data.base64EncodedString())"
                    }
                    rendered = "<img src=\"\(escape(src))\" alt=\"\(escape(label))\">"
                } else { rendered = "<a href=\"\(escape(url.absoluteString))\">\(inline(label, base: base, depth: depth + 1))</a>" }
            } else { rendered = escape(ns.substring(with: m.range)) }
        default:
            let group = m.range(at: 1).location == NSNotFound ? 2 : 1
            rendered = "<\(kind)>\(inline(ns.substring(with: m.range(at: group)), base: base, depth: depth + 1))</\(kind)>"
        }
        return prefix + rendered + suffix
    }
}
