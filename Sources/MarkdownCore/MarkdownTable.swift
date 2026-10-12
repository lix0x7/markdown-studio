import Foundation

public struct MarkdownTable {
    public var rows: [[String]]
    public var alignments: [String]
    public let range: NSRange
    public let newline: String
    private var rawLines: [SourceLine]
    private var cellRanges: [[NSRange]]

    // 记录每个单元格的原始位置；普通单元格编辑只替换内容，不整理空格或分隔行。
    public init?(text: String, at location: Int) {
        let lines = Markdown.lines(text), fences = Markdown.fences(text)
        guard let focus = lines.firstIndex(where: { NSLocationInRange(location, $0.range) || location == NSMaxRange($0.range) && $0.ending.isEmpty }),
              !fences.contains(where: { NSLocationInRange(location, $0.range) }) else { return nil }
        var start = focus
        while start > 0, lines[start - 1].text.contains("|"), !lines[start - 1].text.isEmpty { start -= 1 }
        guard start + 1 < lines.count else { return nil }
        let headers = Self.cells(lines[start].text), separators = Self.cells(lines[start + 1].text)
        guard headers.count > 0, headers.count == separators.count,
              separators.allSatisfy({ !Markdown.matches(#"^\s*:?-{3,}:?\s*$"#, in: $0.value).isEmpty }) else { return nil }
        var end = start + 2
        while end < lines.count, lines[end].text.contains("|"), Self.cells(lines[end].text).count == headers.count { end += 1 }
        guard focus < end else { return nil }
        rawLines = Array(lines[start..<end])
        range = NSRange(location: lines[start].range.location, length: NSMaxRange(lines[end - 1].range) - lines[start].range.location)
        newline = lines[start].ending.isEmpty ? SourceFile(text: text).newline : lines[start].ending
        alignments = separators.map { cell in
            let v = cell.value.trimmingCharacters(in: .whitespaces)
            return v.hasSuffix(":") ? (v.hasPrefix(":") ? "center" : "right") : "left"
        }
        let dataLines = [lines[start]] + Array(lines[(start + 2)..<end])
        rows = dataLines.map { Self.cells($0.text).map(\.value) }
        cellRanges = dataLines.map { line in Self.cells(line.text).map { NSRange(location: line.range.location + $0.range.location, length: $0.range.length) } }
    }
    public static func cells(_ line: String) -> [(value: String, range: NSRange)] {
        let ns = line as NSString
        var boundaries: [Int] = [], escaped = false, codeTicks = 0, index = 0
        while index < ns.length {
            let c = ns.character(at: index)
            if escaped { escaped = false; index += 1; continue }
            if c == 92 { escaped = true; index += 1; continue }
            if c == 96 {
                var end = index
                while end < ns.length, ns.character(at: end) == 96 { end += 1 }
                let count = end - index
                if codeTicks == 0 { codeTicks = count } else if codeTicks == count { codeTicks = 0 }
                index = end; continue
            }
            if c == 124, codeTicks == 0 { boundaries.append(index) }
            index += 1
        }
        guard !boundaries.isEmpty else { return [] }
        var starts = [0] + boundaries.map { $0 + 1 }, ends = boundaries + [ns.length]
        if ns.substring(to: boundaries[0]).trimmingCharacters(in: .whitespaces).isEmpty { starts.removeFirst(); ends.removeFirst() }
        if ns.substring(from: boundaries.last! + 1).trimmingCharacters(in: .whitespaces).isEmpty { starts.removeLast(); ends.removeLast() }
        return zip(starts, ends).map { start, end in
            var a = start, b = end
            while a < b, [9, 32].contains(Int(ns.character(at: a))) { a += 1 }
            while b > a, [9, 32].contains(Int(ns.character(at: b - 1))) { b -= 1 }
            return (ns.substring(with: NSRange(location: a, length: b - a)), NSRange(location: a, length: b - a))
        }
    }
    public static func escapedCell(_ value: String) -> String {
        let ns = value as NSString
        var result = "", index = 0, codeTicks = 0
        while index < ns.length {
            let char = ns.character(at: index)
            if char == 92, index + 1 < ns.length {
                let end = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: index + 1))
                result += ns.substring(with: NSRange(location: index, length: end - index)); index = end; continue
            }
            if char == 96 {
                var end = index
                while end < ns.length, ns.character(at: end) == 96 { end += 1 }
                let count = end - index
                if codeTicks == 0 { codeTicks = count } else if codeTicks == count { codeTicks = 0 }
                result += ns.substring(with: NSRange(location: index, length: count)); index = end; continue
            }
            if char == 124, codeTicks == 0 { result += "\\" }
            let range = ns.rangeOfComposedCharacterSequence(at: index)
            result += ns.substring(with: range); index = NSMaxRange(range)
        }
        return result
    }
    public func cellEdit(row: Int, column: Int, value: String) -> TextEdit {
        TextEdit(range: cellRanges[row][column], replacement: value)
    }
    public func edits(comparedTo original: MarkdownTable) -> [TextEdit] {
        if rows.count == original.rows.count, alignments.count == original.alignments.count,
           zip(rows, original.rows).allSatisfy({ $0.count == $1.count }) {
            var edits: [TextEdit] = []
            for row in rows.indices { for col in rows[row].indices where !rows[row][col].utf8.elementsEqual(original.rows[row][col].utf8) {
                edits.append(original.cellEdit(row: row, column: col, value: rows[row][col]))
            } }
            let separators = Self.cells(original.rawLines[1].text)
            for column in alignments.indices where alignments[column] != original.alignments[column] {
                let cell = separators[column]
                let dashes = cell.value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                let value = alignments[column] == "center" ? ":" + dashes + ":" : alignments[column] == "right" ? dashes + ":" : dashes
                edits.append(TextEdit(range: NSRange(location: original.rawLines[1].range.location + cell.range.location, length: cell.range.length), replacement: value))
            }
            return edits.sorted { $0.range.location > $1.range.location }
        }
        let old = original.rawLines.map { $0.text + $0.ending }.joined()
        let new = serialized()
        guard let change = TextEdit.difference(from: old, to: new) else { return [] }
        return [TextEdit(range: NSRange(location: range.location + change.range.location, length: change.range.length), replacement: change.replacement)]
    }
    public func serialized() -> String {
        var output = rows.enumerated().map { index, row in
            let rawIndex = index == 0 ? 0 : index + 1
            if rawIndex < rawLines.count, Self.cells(rawLines[rawIndex].text).map(\.value) == row { return rawLines[rawIndex].text }
            return "| " + row.joined(separator: " | ") + " |"
        }
        output.insert("| " + alignments.map { $0 == "center" ? ":---:" : $0 == "right" ? "---:" : "---" }.joined(separator: " | ") + " |", at: 1)
        return output.joined(separator: newline) + (rawLines.last?.ending ?? newline)
    }
    public static func template(columns: Int = 3, newline: String = "\n") -> String {
        let header = "| " + (1...columns).map { "列\($0)" }.joined(separator: " | ") + " |"
        let separator = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        let row = "| " + Array(repeating: "内容", count: columns).joined(separator: " | ") + " |"
        return [header, separator, row].joined(separator: newline) + newline
    }
}
