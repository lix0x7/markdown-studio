import Foundation

public struct SourceLine {
    public let range: NSRange
    public let contentRange: NSRange
    public let text: String
    public let ending: String
}

public struct Heading {
    public let title: String
    public let level: Int
    public let range: NSRange
}

public struct Fence {
    public let opening: SourceLine
    public let range: NSRange
    public let bodyRange: NSRange
    public let languageRange: NSRange
    public let language: String
}

public enum Markdown {
    private static let regexCache = NSCache<NSString, NSRegularExpression>()
    public static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [NSTextCheckingResult] {
        let key = "\(options.rawValue):\(pattern)" as NSString
        let regex: NSRegularExpression
        if let cached = regexCache.object(forKey: key) { regex = cached }
        else {
            guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
            regex = compiled; regexCache.setObject(compiled, forKey: key)
        }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
    public static func lines(_ text: String) -> [SourceLine] {
        let ns = text as NSString
        var result: [SourceLine] = [], start = 0
        while start < ns.length {
            var lineStart = 0, end = 0, contentEnd = 0
            ns.getLineStart(&lineStart, end: &end, contentsEnd: &contentEnd, for: NSRange(location: start, length: 0))
            result.append(SourceLine(range: NSRange(location: start, length: end - start),
                contentRange: NSRange(location: start, length: contentEnd - start),
                text: ns.substring(with: NSRange(location: start, length: contentEnd - start)),
                ending: ns.substring(with: NSRange(location: contentEnd, length: end - contentEnd))))
            start = end
        }
        return result
    }
    public static func fences(_ text: String) -> [Fence] {
        guard text.contains("```") || text.contains("~~~") else { return [] }
        let all = lines(text)
        var result: [Fence] = [], index = 0
        while index < all.count {
            let line = all[index]
            guard line.text.contains("```") || line.text.contains("~~~") else { index += 1; continue }
            guard let match = matches(#"^ {0,3}(`{3,}|~{3,})[ \t]*([^\s]*)[^\r\n]*$"#, in: line.text).first else { index += 1; continue }
            let ns = line.text as NSString, marker = ns.substring(with: match.range(at: 1))
            var closing = index + 1
            while closing < all.count {
                let candidate = all[closing].text.trimmingCharacters(in: .whitespaces)
                if candidate.count >= marker.count && candidate.allSatisfy({ $0 == marker.first! }) { break }
                closing += 1
            }
            let bodyStart = NSMaxRange(line.range)
            let bodyEnd = closing < all.count ? all[closing].range.location : (text as NSString).length
            let end = closing < all.count ? NSMaxRange(all[closing].range) : bodyEnd
            let lr = match.range(at: 2)
            result.append(Fence(opening: line, range: NSRange(location: line.range.location, length: end - line.range.location),
                bodyRange: NSRange(location: bodyStart, length: bodyEnd - bodyStart),
                languageRange: NSRange(location: line.range.location + lr.location, length: lr.length), language: ns.substring(with: lr)))
            index = closing + 1
        }
        return result
    }
    public static func headings(_ text: String) -> [Heading] {
        guard text.contains("#") else { return [] }
        let fences = fences(text)
        return lines(text).compactMap { line in
            guard line.text.contains("#"), !fences.contains(where: { NSLocationInRange(line.range.location, $0.range) }),
                  let match = matches(#"^ {0,3}(#{1,6})[ \t]+(.+?)\s*#*\s*$"#, in: line.text).first else { return nil }
            let ns = line.text as NSString
            return Heading(title: ns.substring(with: match.range(at: 2)), level: match.range(at: 1).length, range: line.contentRange)
        }
    }
    public static func blockRange(in text: String, selection: NSRange) -> NSRange {
        let ns = text as NSString
        let end = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let first = ns.lineRange(for: NSRange(location: min(selection.location, ns.length), length: 0))
        let last = ns.lineRange(for: NSRange(location: min(end, ns.length), length: 0))
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
    public static func wrap(in text: String, selection: NSRange, marker: String) -> TextEdit {
        let ns = text as NSString, selected = ns.substring(with: selection), n = (marker as NSString).length
        if selected.hasPrefix(marker), selected.hasSuffix(marker), selected.utf16.count >= n * 2 {
            return TextEdit(range: selection, replacement: (selected as NSString).substring(with: NSRange(location: n, length: selected.utf16.count - n * 2)))
        }
        if selection.location >= n, NSMaxRange(selection) + n <= ns.length,
           ns.substring(with: NSRange(location: selection.location - n, length: n)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(selection), length: n)) == marker {
            return TextEdit(range: NSRange(location: selection.location - n, length: selection.length + n * 2), replacement: selected)
        }
        return TextEdit(range: selection, replacement: marker + selected + marker)
    }
    public static func prefix(in text: String, selection: NSRange, prefix: String, replacing pattern: String) -> TextEdit {
        let range = blockRange(in: text, selection: selection)
        let block = (text as NSString).substring(with: range)
        let rows = lines(block)
        let rewritten = rows.isEmpty ? prefix : rows.map { line in
            if let match = matches(pattern, in: line.text).first {
                return (line.text as NSString).replacingCharacters(in: match.range, with: prefix) + line.ending
            }
            return prefix + line.text + line.ending
        }.joined()
        return TextEdit(range: range, replacement: rewritten)
    }
    public static func imageReference(_ line: String) -> (alt: String, path: String)? {
        guard let match = matches(#"^\s*!\[([^\]]*)\]\((?:<([^>]+)>|([^\s]+?))(?:\s+\"[^\"]*\")?\)\s*$"#, in: line).first else { return nil }
        let ns = line as NSString, range = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
        return (ns.substring(with: match.range(at: 1)), ns.substring(with: range))
    }
    public static func resolvedURL(_ reference: String, base: URL?) -> URL? {
        if let url = URL(string: reference), let scheme = url.scheme {
            return ["http", "https", "file", "mailto"].contains(scheme.lowercased()) ? url : nil
        }
        let path = reference.removingPercentEncoding ?? reference
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return base?.appendingPathComponent(path).standardizedFileURL
    }
}
