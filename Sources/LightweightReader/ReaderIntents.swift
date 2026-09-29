import AppIntents
import AppKit
import Foundation

struct OpenReaderDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Reader Document"
    static let description = IntentDescription("Open a local PDF, Markdown, or JSON file in Lightweight Reader.")
    static let openAppWhenRun = true

    @Parameter(title: "File Path") var path: String

    func perform() async throws -> some IntentResult {
        let url = URL(fileURLWithPath: path)
        _ = try ReaderType(url: url)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AgentDocumentError.notFound }
        let opened = await MainActor.run {
            (NSApp.delegate as? AppDelegate)?.openDocument(at: url) ?? false
        }
        guard opened else { throw AgentDocumentError.invalid("document was not opened") }
        guard let app = await MainActor.run(body: { NSApp.delegate as? AppDelegate }),
              await app.waitForOpen() else { throw AgentDocumentError.invalid("document could not be loaded") }
        return .result()
    }
}

struct ReaderDocumentInfoIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Reader Document Info"
    static let description = IntentDescription("Get the type and size of a local Reader document.")

    @Parameter(title: "File Path") var path: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let filePath = path
        let value = try await Task.detached {
            let result = try AgentDocumentService().call("document_info", arguments: ["path": filePath])
            let data = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
            return String(decoding: data, as: UTF8.self)
        }.value
        return .result(value: value)
    }
}

struct ReaderPDFPageTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get PDF Page Text"
    static let description = IntentDescription("Read a bounded excerpt from one PDF page.")

    @Parameter(title: "File Path") var path: String
    @Parameter(title: "Page") var page: Int
    @Parameter(title: "Character Offset") var offset: Int

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let filePath = path
        let pageNumber = page
        let characterOffset = offset
        let value = try await Task.detached {
            let result = try AgentDocumentService().call("pdf_page_text", arguments: ["path": filePath, "page": pageNumber, "offset": characterOffset])
            let data = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
            return String(decoding: data, as: UTF8.self)
        }.value
        return .result(value: value)
    }
}

struct ReaderJSONChildrenIntent: AppIntent {
    static let title: LocalizedStringResource = "Get JSON Children"
    static let description = IntentDescription("Read one page of children at a JSON pointer.")

    @Parameter(title: "File Path") var path: String
    @Parameter(title: "JSON Pointer") var pointer: String
    @Parameter(title: "Page") var page: Int

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let filePath = path
        let jsonPointer = pointer
        let pageNumber = page
        let value = try await Task.detached {
            let result = try AgentDocumentService().call("json_children", arguments: ["path": filePath, "pointer": jsonPointer, "page": pageNumber])
            let data = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
            return String(decoding: data, as: UTF8.self)
        }.value
        return .result(value: value)
    }
}

struct ReaderCurrentSelectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Reader Selection"
    static let description = IntentDescription("Get the selected text or JSON pointer in the open document.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let value = try await MainActor.run { () throws -> String in
            guard let result = (NSApp.delegate as? AppDelegate)?.selectionInfo() else {
                throw AgentDocumentError.invalid("no document is open")
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
            return String(decoding: data, as: UTF8.self)
        }
        return .result(value: value)
    }
}

struct ReaderGoToPDFPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Go to PDF Page"
    static let description = IntentDescription("Navigate the open PDF to a page.")
    static let openAppWhenRun = true

    @Parameter(title: "Page") var page: Int

    func perform() async throws -> some IntentResult {
        let pageNumber = page
        let succeeded = await MainActor.run {
            (NSApp.delegate as? AppDelegate)?.goToPDFPage(pageNumber) ?? false
        }
        guard succeeded else { throw AgentDocumentError.invalid("PDF page or open document") }
        return .result()
    }
}

struct ReaderGoToJSONPointerIntent: AppIntent {
    static let title: LocalizedStringResource = "Go to JSON Pointer"
    static let description = IntentDescription("Navigate the open JSON tree to a pointer.")
    static let openAppWhenRun = true

    @Parameter(title: "JSON Pointer") var pointer: String

    func perform() async throws -> some IntentResult {
        let target = pointer
        let task = await MainActor.run {
            Task { @MainActor in
                guard let app = NSApp.delegate as? AppDelegate else {
                    throw AgentDocumentError.invalid("app is not running")
                }
                try await app.goToJSONPointer(target)
            }
        }
        try await task.value
        return .result()
    }
}

struct ReaderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenReaderDocumentIntent(), phrases: ["Open a document in \(.applicationName)"], shortTitle: "Open Document", systemImageName: "doc")
        AppShortcut(intent: ReaderDocumentInfoIntent(), phrases: ["Get document info from \(.applicationName)"], shortTitle: "Document Info", systemImageName: "doc.text.magnifyingglass")
    }
}
