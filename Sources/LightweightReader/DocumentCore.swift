import Foundation
import CryptoKit

enum ReaderType: Equatable {
    case pdf, markdown, json

    init(url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "pdf": self = .pdf
        case "md", "markdown": self = .markdown
        case "json": self = .json
        default: throw ReaderError.unsupportedType
        }
    }
}

enum ReaderError: LocalizedError {
    case unsupportedType, invalidJSON, invalidEncoding
    var errorDescription: String? {
        switch self {
        case .unsupportedType: return String(localized: "error.unsupported", defaultValue: "This file type is not supported.")
        case .invalidJSON: return String(localized: "error.json", defaultValue: "The JSON file is invalid.")
        case .invalidEncoding: return String(localized: "error.encoding", defaultValue: "The file could not be read as UTF-8.")
        }
    }
}

struct MarkdownStore {
    func read(_ url: URL) throws -> String {
        guard let value = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw ReaderError.invalidEncoding }
        return value
    }
    func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    func currentHash(_ url: URL) throws -> String { hash(try Data(contentsOf: url)) }
    func save(_ text: String, to url: URL, expectedSha256: String? = nil) throws {
        guard let data = text.data(using: .utf8) else { throw ReaderError.invalidEncoding }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writableURL in
            do {
                if let expectedSha256, try currentHash(writableURL) != expectedSha256 {
                    throw AgentDocumentError.conflict
                }
                try data.write(to: writableURL, options: .atomic)
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}

struct JSONEntry: Sendable {
    let label: String
    let range: Range<Int>
    let type: JSONValueType
    let summary: String
}

enum JSONValueType: Sendable { case object, array, scalar }

struct JSONPage: Sendable {
    let entries: [JSONEntry]
    let hasMore: Bool
}

final class JSONIndex: @unchecked Sendable {
    let data: Data
    let root: JSONEntry
    private let pageSize = 100

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        let bytes = [UInt8](data.prefix(1))
        guard !bytes.isEmpty else { throw ReaderError.invalidJSON }
        var cursor = 0
        try JSONIndex.skipWhitespace(data, &cursor)
        guard cursor < data.count else { throw ReaderError.invalidJSON }
        let kind = JSONIndex.kind(data[cursor])
        guard kind != .scalar else { throw ReaderError.invalidJSON }
        root = JSONEntry(label: url.lastPathComponent, range: cursor..<data.count, type: kind, summary: kind == .object ? "{…}" : "[…]")
    }

    func page(for parent: JSONEntry, number: Int) throws -> JSONPage {
        guard parent.type != .scalar, number >= 0, number <= Int.max / pageSize else { throw AgentDocumentError.invalid("page") }
        var cursor = parent.range.lowerBound + 1
        let endToken: UInt8 = parent.type == .object ? 125 : 93
        var childNumber = 0
        var entries: [JSONEntry] = []
        let first = number * pageSize
        while cursor < parent.range.upperBound {
            try Task.checkCancellation()
            try Self.skipWhitespace(data, &cursor)
            guard cursor < data.count else { throw ReaderError.invalidJSON }
            if data[cursor] == endToken { return JSONPage(entries: entries, hasMore: false) }
            var label = "[\(childNumber)]"
            if parent.type == .object {
                guard data[cursor] == 34 else { throw ReaderError.invalidJSON }
                let keyStart = cursor
                try skipString(&cursor)
                let keyData = data[keyStart..<cursor]
                if childNumber >= first {
                    guard let key = try JSONSerialization.jsonObject(with: Data(keyData), options: .fragmentsAllowed) as? String else { throw ReaderError.invalidJSON }
                    label = key
                }
                try Self.skipWhitespace(data, &cursor)
                guard cursor < data.count, data[cursor] == 58 else { throw ReaderError.invalidJSON }
                cursor += 1
                try Self.skipWhitespace(data, &cursor)
            }
            let start = cursor
            let type = Self.kind(data[cursor])
            try skipValue(&cursor)
            if childNumber >= first {
                let summary: String
                switch type {
                case .object: summary = "{…}"
                case .array: summary = "[…]"
                case .scalar:
                    let prefix = data[start..<min(cursor, start + 120)]
                    summary = String(decoding: prefix, as: UTF8.self) + (cursor - start > 120 ? "…" : "")
                }
                entries.append(JSONEntry(label: label, range: start..<cursor, type: type, summary: summary))
                if entries.count > pageSize { return JSONPage(entries: Array(entries.prefix(pageSize)), hasMore: true) }
            }
            childNumber += 1
            try Self.skipWhitespace(data, &cursor)
            guard cursor < data.count else { throw ReaderError.invalidJSON }
            if data[cursor] == 44 { cursor += 1; continue }
            if data[cursor] == endToken { return JSONPage(entries: entries, hasMore: false) }
            throw ReaderError.invalidJSON
        }
        throw ReaderError.invalidJSON
    }

    private static func kind(_ byte: UInt8) -> JSONValueType {
        if byte == 123 { return .object }
        if byte == 91 { return .array }
        return .scalar
    }
    private static func skipWhitespace(_ data: Data, _ cursor: inout Int) throws {
        while cursor < data.count && (data[cursor] == 32 || data[cursor] == 10 || data[cursor] == 13 || data[cursor] == 9) { cursor += 1 }
    }
    private func skipString(_ cursor: inout Int) throws {
        guard cursor < data.count, data[cursor] == 34 else { throw ReaderError.invalidJSON }
        cursor += 1
        while cursor < data.count {
            try Task.checkCancellation()
            if data[cursor] == 92 { cursor += 2; continue }
            if data[cursor] == 34 { cursor += 1; return }
            cursor += 1
        }
        throw ReaderError.invalidJSON
    }
    private func skipValue(_ cursor: inout Int) throws {
        guard cursor < data.count else { throw ReaderError.invalidJSON }
        let first = data[cursor]
        if first == 34 { try skipString(&cursor); return }
        if first == 123 || first == 91 {
            var stack: [UInt8] = [first == 123 ? 125 : 93]
            cursor += 1
            while cursor < data.count {
                try Task.checkCancellation()
                let byte = data[cursor]
                if byte == 34 { try skipString(&cursor); continue }
                if byte == 123 { stack.append(125) }
                if byte == 91 { stack.append(93) }
                if byte == 125 || byte == 93 {
                    guard stack.popLast() == byte else { throw ReaderError.invalidJSON }
                    cursor += 1
                    if stack.isEmpty { return }
                    continue
                }
                cursor += 1
            }
            throw ReaderError.invalidJSON
        }
        while cursor < data.count {
            try Task.checkCancellation()
            let byte = data[cursor]
            if byte == 44 || byte == 125 || byte == 93 || byte == 32 || byte == 10 || byte == 13 || byte == 9 { return }
            cursor += 1
        }
    }
}
