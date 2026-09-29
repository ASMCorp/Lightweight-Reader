import AppKit
import PDFKit
import UniformTypeIdentifiers

private struct LoadedPDF: @unchecked Sendable {
    let document: PDFDocument
}

private struct LoadedMarkdown: Sendable {
    let text: String
    let hash: String
}

@MainActor
private final class DocumentDropView: NSView {
    var onFileDrop: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearDropIndicator()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        supportedFile(in: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        clearDropIndicator()
        guard let url = supportedFile(in: sender.draggingPasteboard) else { return false }
        onFileDrop?(url)
        return true
    }

    private func updateDropIndicator(for sender: NSDraggingInfo) -> NSDragOperation {
        let supported = supportedFile(in: sender.draggingPasteboard) != nil
        layer?.borderColor = supported ? NSColor.controlAccentColor.cgColor : nil
        layer?.borderWidth = supported ? 3 : 0
        return supported ? .copy : []
    }

    private func clearDropIndicator() {
        layer?.borderColor = nil
        layer?.borderWidth = 0
    }

    private func supportedFile(in pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.compactMap { $0 as? URL } ?? []
        return urls.first { url in
            var isDirectory: ObjCBool = false
            return url.isFileURL
                && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && (try? ReaderType(url: url)) != nil
        }
    }
}

@MainActor
final class ProjectViewController: NSViewController {
    private let openButton = NSButton(title: String(localized: "file.open"), target: nil, action: nil)
    private let saveButton = NSButton(title: String(localized: "file.save"), target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: String(localized: "app.title"))
    private let loadingIndicator = NSProgressIndicator()
    private let content = NSView()
    private let bar = NSStackView()
    private var barHeight: NSLayoutConstraint?
    private var current: NSViewController?
    private var currentURL: URL?
    private var loadTask: Task<Bool, Never>?

    override func loadView() {
        let container = DocumentDropView()
        let handleDrop: (URL) -> Void = { [weak self] url in
            guard let self, self.confirmDiscardIfNeeded() else { return }
            self.open(url)
        }
        container.onFileDrop = handleDrop
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        openButton.target = self; openButton.action = #selector(openDocument)
        saveButton.target = self; saveButton.action = #selector(saveDocument)
        saveButton.isEnabled = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(openButton); bar.addArrangedSubview(saveButton); bar.addArrangedSubview(loadingIndicator); bar.addArrangedSubview(titleLabel)
        container.addSubview(bar)
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        let barHeight = bar.heightAnchor.constraint(equalToConstant: 0)
        self.barHeight = barHeight
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor), bar.leadingAnchor.constraint(equalTo: container.leadingAnchor), bar.trailingAnchor.constraint(equalTo: container.trailingAnchor), barHeight,
            content.topAnchor.constraint(equalTo: bar.bottomAnchor), content.leadingAnchor.constraint(equalTo: container.leadingAnchor), content.trailingAnchor.constraint(equalTo: container.trailingAnchor), content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        bar.isHidden = true
        view = container
        showWelcome()
    }
    private func showWelcome() {
        let welcome = WelcomeView()
        welcome.onOpen = { [weak self] in self?.openDocument() }
        welcome.onOpenPDF = { [weak self] in self?.presentOpenPanel(allowedTypes: [.pdf]) }
        welcome.onOpenMarkdown = { [weak self] in self?.presentOpenPanel(allowedTypes: Self.markdownTypes) }
        welcome.onOpenJSON = { [weak self] in self?.presentOpenPanel(allowedTypes: [.json]) }
        welcome.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(welcome)
        NSLayoutConstraint.activate([
            welcome.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            welcome.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            welcome.topAnchor.constraint(equalTo: content.topAnchor),
            welcome.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }
    @objc func openDocument() {
        presentOpenPanel(allowedTypes: [.pdf, .json] + Self.markdownTypes)
    }
    private static var markdownTypes: [UTType] {
        [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText]
    }
    private func presentOpenPanel(allowedTypes: [UTType]) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, confirmDiscardIfNeeded() { open(url) }
    }
    func open(_ url: URL) {
        loadTask?.cancel()
        barHeight?.constant = 52
        bar.isHidden = false
        loadingIndicator.startAnimation(nil)
        loadTask = Task { [weak self] in
            guard let self else { return false }
            defer {
                if !Task.isCancelled {
                    self.loadingIndicator.stopAnimation(nil)
                    if self.current == nil {
                        self.barHeight?.constant = 0
                        self.bar.isHidden = true
                    }
                }
            }
            do {
                let type = try ReaderType(url: url)
                switch type {
                case .pdf:
                    let loading = Task.detached(priority: .userInitiated) { () throws -> LoadedPDF in
                        try Task.checkCancellation()
                        guard let document = PDFDocument(url: url) else { throw ReaderError.invalidEncoding }
                        try Task.checkCancellation()
                        return LoadedPDF(document: document)
                    }
                    let result = try await withTaskCancellationHandler {
                        try await loading.value
                    } onCancel: {
                        loading.cancel()
                    }
                    guard !Task.isCancelled else { return false }
                    self.install(PDFViewController(document: result.document), url: url)
                case .markdown:
                    let loading = Task.detached(priority: .userInitiated) { () throws -> LoadedMarkdown in
                        try Task.checkCancellation()
                        let store = MarkdownStore()
                        let text = try store.read(url)
                        try Task.checkCancellation()
                        return LoadedMarkdown(text: text, hash: store.hash(text))
                    }
                    let result = try await withTaskCancellationHandler {
                        try await loading.value
                    } onCancel: {
                        loading.cancel()
                    }
                    guard !Task.isCancelled else { return false }
                    let reader = MarkdownViewController(url: url, text: result.text, savedHash: result.hash)
                    reader.onDirtyChange = { [weak self] dirty in self?.saveButton.isEnabled = dirty; self?.updateTitle() }
                    self.install(reader, url: url)
                case .json:
                    let loading = Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        return try JSONIndex(url: url)
                    }
                    let index = try await withTaskCancellationHandler {
                        try await loading.value
                    } onCancel: {
                        loading.cancel()
                    }
                    guard !Task.isCancelled else { return false }
                    self.install(JSONViewController(index: index), url: url)
                }
                return true
            } catch is CancellationError { return false } catch {
                guard !Task.isCancelled else { return false }
                self.showError(error)
                return false
            }
        }
    }
    func waitForOpen() async -> Bool {
        await loadTask?.value ?? false
    }
    private func install(_ controller: NSViewController, url: URL) {
        barHeight?.constant = 52
        bar.isHidden = false
        (current as? MarkdownViewController)?.cancelPreview()
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        content.subviews.forEach { $0.removeFromSuperview() }
        addChild(controller)
        let childView = controller.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(childView)
        NSLayoutConstraint.activate([childView.leadingAnchor.constraint(equalTo: content.leadingAnchor), childView.trailingAnchor.constraint(equalTo: content.trailingAnchor), childView.topAnchor.constraint(equalTo: content.topAnchor), childView.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        current = controller; currentURL = url
        saveButton.isEnabled = false
        updateTitle()
    }
    private func updateTitle() {
        let name = currentURL?.lastPathComponent ?? String(localized: "app.title")
        let dirty = (current as? MarkdownViewController)?.isDirty == true
        titleLabel.stringValue = name + (dirty ? " •" : "")
        view.window?.title = name + (dirty ? " •" : "")
    }
    @objc func saveDocument() {
        guard let markdown = current as? MarkdownViewController else { return }
        do { try markdown.save() } catch { showError(error) }
    }
    func selectionInfo() -> [String: Any]? {
        guard let currentURL else { return nil }
        var result: [String: Any] = ["path": currentURL.path]
        if let pdf = current as? PDFViewController { result.merge(pdf.selectionInfo) { _, new in new } }
        if let markdown = current as? MarkdownViewController { result.merge(markdown.selectionInfo) { _, new in new } }
        if let json = current as? JSONViewController { result.merge(json.selectionInfo) { _, new in new } }
        return result
    }
    func goToPDFPage(_ page: Int) -> Bool {
        (current as? PDFViewController)?.goToPage(page) ?? false
    }
    func goToJSONPointer(_ pointer: String) async throws {
        guard let json = current as? JSONViewController else { throw AgentDocumentError.invalid("JSON document is not open") }
        try await json.goToPointer(pointer)
    }
    func confirmDiscardIfNeeded() -> Bool {
        guard let markdown = current as? MarkdownViewController, markdown.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "markdown.unsaved")
        alert.addButton(withTitle: String(localized: "file.save"))
        alert.addButton(withTitle: String(localized: "file.discard"))
        alert.addButton(withTitle: String(localized: "file.cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do { try markdown.save(); return true } catch { showError(error); return false }
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
