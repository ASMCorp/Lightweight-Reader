import Foundation
import PDFKit

enum AgentDocumentError: LocalizedError {
    case missing(String), invalid(String), notFound, conflict

    var errorDescription: String? {
        switch self {
        case .missing(let name): "Missing parameter: \(name)"
        case .invalid(let detail): "Invalid parameter: \(detail)"
        case .notFound: "Document location not found"
        case .conflict: "The file changed since it was read"
        }
    }
}

/// File operations shared by the app, command line tool, and MCP adapter.
struct AgentDocumentService {
    private let maximumTextBytes = 16_384

    func call(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        let path = try string("path", in: arguments)
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let type = try ReaderType(url: url)
        switch name {
        case "document_info":
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            var result: [String: Any] = [
                "path": url.path,
                "type": type.name,
                "sizeBytes": attributes[.size] as? Int ?? 0
            ]
            if type == .pdf {
                guard let document = PDFDocument(url: url) else { throw AgentDocumentError.invalid("PDF file") }
                result["pageCount"] = document.pageCount
            } else if type == .markdown {
                result["sha256"] = try markdownHash(url)
            }
            return result
        case "pdf_page_text":
            guard type == .pdf else { throw AgentDocumentError.invalid("PDF file required") }
            let pageNumber = try integer("page", in: arguments)
            guard let document = PDFDocument(url: url), pageNumber > 0, pageNumber <= document.pageCount,
                  let page = document.page(at: pageNumber - 1) else { throw AgentDocumentError.invalid("page") }
            let text = page.string ?? ""
            let offset = try optionalInteger("offset", in: arguments) ?? 0
            guard offset >= 0 else { throw AgentDocumentError.invalid("offset") }
            let excerpt = bounded(text, offset: offset)
            return ["path": url.path, "page": pageNumber, "pageCount": document.pageCount,
                    "text": excerpt.text, "nextOffset": excerpt.nextOffset as Any, "totalCharacters": text.count]
        case "json_children":
            guard type == .json else { throw AgentDocumentError.invalid("JSON file required") }
            let pointer = try optionalString("pointer", in: arguments) ?? ""
            let page = try optionalInteger("page", in: arguments) ?? 0
            guard page >= 0 else { throw AgentDocumentError.invalid("page") }
            let index = try JSONIndex(url: url)
            let parent = try entry(at: pointer, in: index)
            guard parent.type != .scalar else { throw AgentDocumentError.invalid("pointer must name an object or array") }
            let result = try index.page(for: parent, number: page)
            let children: [[String: Any]] = result.entries.map { child in
                let component = parent.type == .array ? String(child.label.dropFirst().dropLast()) : escapePointer(child.label)
                return ["pointer": pointer + "/" + component, "label": child.label,
                        "type": child.type.name, "summary": child.summary]
            }
            return ["path": url.path, "pointer": pointer, "page": page,
                    "children": children, "hasMore": result.hasMore]
        case "json_value":
            guard type == .json else { throw AgentDocumentError.invalid("JSON file required") }
            let pointer = try optionalString("pointer", in: arguments) ?? ""
            let index = try JSONIndex(url: url)
            let value = try entry(at: pointer, in: index)
            let size = value.range.count
            guard value.type == .scalar else {
                return ["path": url.path, "pointer": pointer, "type": value.type.name,
                        "summary": value.summary, "sizeBytes": size]
            }
            let prefix = index.data[value.range.lowerBound..<min(value.range.upperBound, value.range.lowerBound + maximumTextBytes)]
            let truncated = size > maximumTextBytes
            return ["path": url.path, "pointer": pointer, "type": "scalar",
                    truncated ? "rawJSONPrefix" : "rawJSON": String(decoding: prefix, as: UTF8.self),
                    "sizeBytes": size, "truncated": truncated]
        case "markdown_text":
            guard type == .markdown else { throw AgentDocumentError.invalid("Markdown file required") }
            let content = try MarkdownStore().read(url)
            let offset = try optionalInteger("offset", in: arguments) ?? 0
            guard offset >= 0 else { throw AgentDocumentError.invalid("offset") }
            let excerpt = bounded(content, offset: offset)
            return ["path": url.path, "text": excerpt.text, "nextOffset": excerpt.nextOffset as Any,
                    "totalCharacters": content.count, "sha256": MarkdownStore().hash(content)]
        case "replace_markdown_range":
            guard type == .markdown else { throw AgentDocumentError.invalid("Markdown file required") }
            let expected = try string("expectedSha256", in: arguments)
            let offset = try integer("offset", in: arguments)
            let length = try integer("length", in: arguments)
            let replacement = try string("replacement", in: arguments)
            guard offset >= 0, length >= 0 else { throw AgentDocumentError.invalid("offset or length") }
            let store = MarkdownStore()
            let current = try store.read(url)
            let hash = store.hash(current)
            guard hash == expected else { throw AgentDocumentError.conflict }
            guard offset <= current.count, length <= current.count - offset else { throw AgentDocumentError.invalid("range") }
            let start = current.index(current.startIndex, offsetBy: offset)
            let end = current.index(start, offsetBy: length)
            var updated = current
            updated.replaceSubrange(start..<end, with: replacement)
            try store.save(updated, to: url, expectedSha256: expected)
            return ["path": url.path, "sha256": try markdownHash(url), "totalCharacters": updated.count]
        default:
            throw AgentDocumentError.invalid("operation \(name)")
        }
    }

    private func entry(at pointer: String, in index: JSONIndex) throws -> JSONEntry {
        guard pointer.isEmpty || pointer.hasPrefix("/") else { throw AgentDocumentError.invalid("JSON pointer") }
        var current = index.root
        if pointer.isEmpty { return current }
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let component = String(raw).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard current.type != .scalar else { throw AgentDocumentError.notFound }
            var page = 0
            var found: JSONEntry?
            repeat {
                let result = try index.page(for: current, number: page)
                found = result.entries.first {
                    current.type == .object ? $0.label == component : $0.label == "[\(component)]"
                }
                if let found { current = found; break }
                if !result.hasMore { throw AgentDocumentError.notFound }
                page += 1
            } while true
        }
        return current
    }

    private func bounded(_ value: String, offset: Int) -> (text: String, nextOffset: Int?) {
        let safeOffset = max(0, min(offset, value.count))
        let start = value.index(value.startIndex, offsetBy: safeOffset)
        let end = value.index(start, offsetBy: min(8_000, value.distance(from: start, to: value.endIndex)))
        let next = end == value.endIndex ? nil : value.distance(from: value.startIndex, to: end)
        return (String(value[start..<end]), next)
    }

    private func markdownHash(_ url: URL) throws -> String {
        try MarkdownStore().currentHash(url)
    }

    private func string(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String else { throw AgentDocumentError.missing(key) }
        return value
    }
    private func optionalString(_ key: String, in arguments: [String: Any]) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value as? String else { throw AgentDocumentError.invalid(key) }
        return string
    }
    private func integer(_ key: String, in arguments: [String: Any]) throws -> Int {
        guard let value = arguments[key] as? Int else { throw AgentDocumentError.missing(key) }
        return value
    }
    private func optionalInteger(_ key: String, in arguments: [String: Any]) throws -> Int? {
        guard let value = arguments[key] else { return nil }
        guard let integer = value as? Int else { throw AgentDocumentError.invalid(key) }
        return integer
    }
    private func escapePointer(_ value: String) -> String {
        value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }
}

private extension ReaderType {
    var name: String {
        switch self { case .pdf: "pdf"; case .markdown: "markdown"; case .json: "json" }
    }
}

private extension JSONValueType {
    var name: String {
        switch self { case .object: "object"; case .array: "array"; case .scalar: "scalar" }
    }
}
