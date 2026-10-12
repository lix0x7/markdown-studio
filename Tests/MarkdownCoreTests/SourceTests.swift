import XCTest
@testable import MarkdownCore

final class SourceTests: XCTestCase {
    func testExactRoundTripAndLocalizedEditAcrossEncodings() throws {
        let text = "---\r\nkey: untouched  \r\n---\r\n# 中文😀\r\n\r\n**old**  \n[x]: /space%20here\n"
        for encoding in [SourceFile.Encoding.utf8, .utf8BOM, .utf16LE, .utf16BE] {
            let original = SourceFile(text: text, encoding: encoding)
            var decoded = try SourceFile(data: original.data)
            XCTAssertEqual(decoded.data, original.data)
            let range = (text as NSString).range(of: "old")
            decoded.text = try TextEdit(range: range, replacement: "new").applying(to: decoded.text)
            XCTAssertEqual(decoded.text, text.replacingOccurrences(of: "old", with: "new"))
            XCTAssertEqual(decoded.encoding, encoding)
            XCTAssertEqual(decoded.newline, "\r\n")
        }
    }
    func testMinimalDiffDoesNotSplitEmoji() throws {
        for (a, b) in [("a😀z", "a😃z"), ("中文abc\r\n", "中文axc\r\n"), ("", "😀"), ("😀", "")] {
            let edit = try XCTUnwrap(TextEdit.difference(from: a, to: b))
            XCTAssertEqual(try edit.applying(to: a), b)
        }
        XCTAssertNil(TextEdit.difference(from: "same", to: "same"))
    }
    func testFormatDoesNotAffectAdjacentLines() throws {
        let original = "前文  \r\nchange\r\n后文\n"
        let selected = (original as NSString).range(of: "change")
        let edit = Markdown.wrap(in: original, selection: selected, marker: "**")
        XCTAssertEqual(try edit.applying(to: original), "前文  \r\n**change**\r\n后文\n")
        let heading = Markdown.prefix(in: original, selection: selected, prefix: "## ", replacing: #"^ {0,3}#{1,6}\s+"#)
        XCTAssertEqual(try heading.applying(to: original), "前文  \r\n## change\r\n后文\n")
    }
    func testHeadingsIgnoreFencesAndDisambiguateByRange() {
        let text = "# same\n```swift\n# not heading\n```\n# same\n"
        let headings = Markdown.headings(text)
        XCTAssertEqual(headings.count, 2)
        XCTAssertNotEqual(headings[0].range, headings[1].range)
        XCTAssertEqual(Markdown.fences(text).first?.language, "swift")
    }
    func testTableCellPreservesSpacingAndLineEndings() throws {
        let text = "before\r\n| a  | b |\r\n|:---|---:|\r\n| old   | `x|y` |\r\nafter\n"
        let original = try XCTUnwrap(MarkdownTable(text: text, at: (text as NSString).range(of: "old").location))
        var edited = original
        edited.rows[1][0] = "new"
        let edits = edited.edits(comparedTo: original)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(try edits[0].applying(to: text), text.replacingOccurrences(of: "old", with: "new"))
        XCTAssertEqual(original.rows[1][1], "`x|y`")
    }
    func testEscapedPipesAndStructuralTableEdit() throws {
        XCTAssertEqual(MarkdownTable.cells("| a\\|b | c |").map(\.value), ["a\\|b", "c"])
        let text = "lead  \n| a | b |\n| --- | --- |\n| c | d |\nend  "
        let original = try XCTUnwrap(MarkdownTable(text: text, at: 10))
        var edited = original
        edited.rows.append(["e", "f"])
        var result = text
        for edit in edited.edits(comparedTo: original) { result = try edit.applying(to: result) }
        XCTAssertTrue(result.hasPrefix("lead  \n")); XCTAssertTrue(result.hasSuffix("\nend  "))
        XCTAssertTrue(result.contains("| e | f |"))
    }
    func testTableAlignmentChangesOnlyItsSeparatorCell() throws {
        let text = "front  \r\n| a | b |\r\n| :-----  |  ---: |\r\n| c   | d |\r\nend"
        let original = try XCTUnwrap(MarkdownTable(text: text, at: (text as NSString).range(of: "| a").location))
        var table = original; table.alignments[1] = "center"
        let edits = table.edits(comparedTo: original)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(try edits[0].applying(to: text), text.replacingOccurrences(of: "---:", with: ":---:"))
    }
    func testTableEscapesNewPipesWithoutChangingCodeOrUnicode() {
        XCTAssertEqual(MarkdownTable.escapedCell("a|b"), "a\\|b")
        XCTAssertEqual(MarkdownTable.escapedCell("a\\|b"), "a\\|b")
        XCTAssertEqual(MarkdownTable.escapedCell("`x|y` 😀"), "`x|y` 😀")
    }
    func testInvalidEncodingIsNotSilentlyReplaced() {
        XCTAssertThrowsError(try SourceFile(data: Data([0xFF, 0x00, 0xFA])))
    }
    func testMarkdownImagesResolveRelativePathsAndExportEmbeddedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("space image.png")
        try Data([1, 2, 3]).write(to: file)
        let image = try XCTUnwrap(Markdown.imageReference("![说明](<space%20image.png>)"))
        XCTAssertEqual(Markdown.resolvedURL(image.path, base: root), file)
        let html = HTMLExporter.inline("![说明](<space%20image.png>)", base: root)
        XCTAssertTrue(html.contains("data:image/png;base64,AQID"))
    }
    func testExportRejectsMissingImagesButIgnoresCodeExamples() throws {
        let root = URL(fileURLWithPath: "/tmp")
        XCTAssertThrowsError(try HTMLExporter.validateLocalImages("![x](missing-\(UUID().uuidString).png)", base: root))
        XCTAssertNoThrow(try HTMLExporter.validateLocalImages("`![x](not-real.png)`\n\n```md\n![x](not-real.png)\n```", base: root))
    }
    func testMinimalDiffSupportsComposedUnicode() throws {
        for (a, b) in [("e\u{301}", "é"), ("e\u{301}", "e\u{300}"), ("a👩🏽‍💻z", "a👩🏻‍💻z")] {
            let edit = try XCTUnwrap(TextEdit.difference(from: a, to: b))
            XCTAssertEqual(Data(try edit.applying(to: a).utf8), Data(b.utf8))
        }
    }
    func testAtomicSaveRejectsExternalChangesAndPreservesDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.md"), baseline = Data("old".utf8)
        try baseline.write(to: file)
        try FileStore.save(SourceFile(text: "new"), to: file, expected: baseline)
        XCTAssertEqual(try String(contentsOf: file), "new")
        XCTAssertThrowsError(try FileStore.save(SourceFile(text: "overwrite"), to: file, expected: baseline))
        XCTAssertEqual(try String(contentsOf: file), "new")
        XCTAssertThrowsError(try FileStore.save(SourceFile(text: "new file"), to: file, expected: nil))
        XCTAssertEqual(try String(contentsOf: file), "new")
    }
    func testDeletedFileIsNotSilentlyRecreated() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try FileStore.save(SourceFile(text: "x"), to: file, expected: Data()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testRecoveryKeepsEncodingAndConflictBaseline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(directory: root)
        let record = RecoveryRecord(id: UUID(), path: "/tmp/file.md", source: SourceFile(text: "unsaved\r\n", encoding: .utf8BOM), baseline: Data("disk".utf8))
        try store.write(record)
        let loaded = try XCTUnwrap(store.records().first)
        XCTAssertEqual(loaded.source.data, record.source.data)
        XCTAssertEqual(loaded.baseline, record.baseline)
        try store.remove(record.id)
        XCTAssertTrue(try store.records().isEmpty)
    }
    func testHTMLExportEscapesAndIncludesStructures() {
        let text = "# 中文\n\n**bold** and *italic* and `a<b`\n\n> quote\n\n- one\n  - nested\n- two\n\n| a | b |\n| --- | ---: |\n| c | d |\n\n```swift\nlet x = \"<script>\"\n```\n\n<script>alert(1)</script>\n"
        let html = HTMLExporter.document(text, title: "A&B", base: nil)
        for expected in ["<strong>bold</strong>", "<em>italic</em>", "<code>a&lt;b</code>", "<blockquote>", "<table>", "text-align:right", "<ul>", "&lt;script&gt;", "A&amp;B"] {
            XCTAssertTrue(html.contains(expected), expected)
        }
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(HTMLExporter.inline("[x](javascript:evil)", base: nil).contains("href="))
    }
}
