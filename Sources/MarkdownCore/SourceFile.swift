import Foundation

public enum SourceError: LocalizedError {
    case unsupportedEncoding, invalidRange, conflict, missingFile
    public var errorDescription: String? {
        switch self {
        case .unsupportedEncoding: return "无法无损读取此编码。支持 UTF-8、带 BOM 的 UTF-16 LE/BE；原文件未修改。"
        case .invalidRange: return "编辑范围已经变化，请重新选择。"
        case .conflict: return "文件已被其他应用修改，尚未覆盖磁盘版本。"
        case .missingFile: return "原文件已被移动或删除，请另存为。"
        }
    }
}

public struct TextEdit: Equatable {
    public let range: NSRange
    public let replacement: String
    public init(range: NSRange, replacement: String) {
        self.range = range; self.replacement = replacement
    }
    public func applying(to text: String) throws -> String {
        guard Range(range, in: text) != nil else { throw SourceError.invalidRange }
        return (text as NSString).replacingCharacters(in: range, with: replacement)
    }

    // 只返回变化的最小连续范围，避免格式化操作重写文档的其他部分。
    public static func difference(from old: String, to new: String) -> TextEdit? {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard a != b else { return nil }
        var start = 0
        while start < min(a.count, b.count), a[start] == b[start] { start += 1 }
        if start > 0, start < a.count, (0xDC00...0xDFFF).contains(a[start]) { start -= 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        if endA < a.count, (0xDC00...0xDFFF).contains(a[endA]) { endA += 1; endB += 1 }
        return TextEdit(range: NSRange(location: start, length: endA - start),
                        replacement: String(decoding: b[start..<endB], as: UTF16.self))
    }
}

public struct SourceFile: Codable {
    public enum Encoding: String, Codable { case utf8, utf8BOM, utf16LE, utf16BE }
    public var text: String
    public var encoding: Encoding
    public init(text: String = "", encoding: Encoding = .utf8) { self.text = text; self.encoding = encoding }
    public init(data: Data) throws {
        let payload: Data
        let codec: String.Encoding
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8BOM; payload = data.dropFirst(3); codec = .utf8
        } else if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LE; payload = data.dropFirst(2); codec = .utf16LittleEndian
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BE; payload = data.dropFirst(2); codec = .utf16BigEndian
        } else { encoding = .utf8; payload = data; codec = .utf8 }
        guard let decoded = String(data: payload, encoding: codec), decoded.data(using: codec) == payload else {
            throw SourceError.unsupportedEncoding
        }
        text = decoded
    }
    public var data: Data {
        switch encoding {
        case .utf8: return Data(text.utf8)
        case .utf8BOM: return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16LE: return Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        case .utf16BE: return Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!
        }
    }
    public var newline: String {
        let ns = text as NSString
        let match = ns.rangeOfCharacter(from: .newlines)
        guard match.location != NSNotFound else { return "\n" }
        if ns.character(at: match.location) == 13 {
            return match.location + 1 < ns.length && ns.character(at: match.location + 1) == 10 ? "\r\n" : "\r"
        }
        return "\n"
    }
}

public enum FileStore {
    // 协调读写并比较打开时的字节；原子写入成功之后才能更新内存基线。
    public static func save(_ source: SourceFile, to url: URL, expected: Data?, overwrite: Bool = false) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            result = Result {
                let exists = FileManager.default.fileExists(atPath: target.path)
                if !overwrite {
                    if let expected {
                        guard exists else { throw SourceError.missingFile }
                        guard try Data(contentsOf: target) == expected else { throw SourceError.conflict }
                    } else if exists { throw SourceError.conflict }
                }
                try source.data.write(to: target, options: .atomic)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }
}

public struct RecoveryRecord: Codable {
    public var id: UUID
    public var path: String?
    public var source: SourceFile
    public var baseline: Data?
    public var modified: Date
    public init(id: UUID, path: String?, source: SourceFile, baseline: Data?) {
        self.id = id; self.path = path; self.source = source; self.baseline = baseline; modified = Date()
    }
}

public struct RecoveryStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func write(_ record: RecoveryRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
    }
    public func records() throws -> [RecoveryRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.modified < $1.modified }
    }
    public func remove(_ id: UUID) throws {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
