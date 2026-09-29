import AppKit
import WebKit

struct MarkdownHTML: Sendable {
    let baseURL: URL
    func render(_ markdown: String) throws -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var output = ""
        var index = 0
        var inCode = false
        var codeLanguage = ""
        var inList = false
        while index < lines.count {
            try Task.checkCancellation()
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inList { output += "</ul>"; inList = false }
                if inCode { output += "</code></pre>"; inCode = false }
                else { codeLanguage = String(trimmed.dropFirst(3)); output += "<pre><code class='language-\(escape(codeLanguage))'>"; inCode = true }
                index += 1; continue
            }
            if inCode { output += escape(line) + "\n"; index += 1; continue }
            if trimmed.contains("|") && index + 1 < lines.count && lines[index + 1].range(of: #"^\s*\|?\s*:?-{3,}"#, options: .regularExpression) != nil {
                if inList { output += "</ul>"; inList = false }
                let headers = cells(line)
                output += "<table><thead><tr>" + headers.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
                index += 2
                while index < lines.count && lines[index].contains("|") && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    try Task.checkCancellation()
                    output += "<tr>" + cells(lines[index]).map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
                    index += 1
                }
                output += "</tbody></table>"
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !inList { output += "<ul>"; inList = true }
                let content = String(trimmed.dropFirst(2))
                if content.hasPrefix("[ ] ") { output += "<li><input type='checkbox' disabled> \(inline(String(content.dropFirst(4))))</li>" }
                else if content.lowercased().hasPrefix("[x] ") { output += "<li><input type='checkbox' checked disabled> \(inline(String(content.dropFirst(4))))</li>" }
                else { output += "<li>\(inline(content))</li>" }
                index += 1; continue
            }
            if inList { output += "</ul>"; inList = false }
            if trimmed.isEmpty { index += 1; continue }
            let count = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(count), trimmed.dropFirst(count).hasPrefix(" ") {
                output += "<h\(count)>\(inline(String(trimmed.dropFirst(count + 1))))</h\(count)>"
            } else if trimmed.hasPrefix("> ") {
                output += "<blockquote>\(inline(String(trimmed.dropFirst(2))))</blockquote>"
            } else { output += "<p>\(inline(trimmed))</p>" }
            index += 1
        }
        if inList { output += "</ul>" }
        if inCode { output += "</code></pre>" }
        let style = "body{font:15px -apple-system,system-ui;line-height:1.55;max-width:850px;margin:24px auto;padding:0 24px;color:#202124}pre{background:#f3f4f6;padding:14px;overflow:auto}code{font-family:ui-monospace,monospace}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccd0d5;padding:6px 10px;text-align:left}blockquote{border-left:3px solid #aaa;padding-left:12px;color:#666}img{max-width:100%;height:auto}"
        return "<!doctype html><html><head><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; img-src file: data:; style-src 'unsafe-inline'\"><style>\(style)</style></head><body>\(output)</body></html>"
    }
    private func cells(_ line: String) -> [String] {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "| ")).split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
    private func inline(_ text: String) -> String {
        var value = escape(text)
        let patterns: [(String, String)] = [
            (#"!\[([^\]]*)\]\(([^)]+)\)"#, "image"),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "link"),
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"\*([^*]+)\*"#, "<em>$1</em>"),
            (#"`([^`]+)`"#, "<code>$1</code>")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: value) else { continue }
                if replacement == "image" || replacement == "link" {
                    guard let labelRange = Range(match.range(at: 1), in: value), let pathRange = Range(match.range(at: 2), in: value) else { continue }
                    let label = String(value[labelRange]); let path = String(value[pathRange])
                    if replacement == "image" {
                        guard let url = localURL(path) else { value.replaceSubrange(range, with: label); continue }
                        value.replaceSubrange(range, with: "<img alt='\(label)' src='\(escape(url.absoluteString))'>")
                    } else if let url = localURL(path) {
                        value.replaceSubrange(range, with: "<a href='\(escape(url.absoluteString))'>\(label)</a>")
                    } else { value.replaceSubrange(range, with: label) }
                } else {
                    let replaced = regex.replacementString(for: match, in: value, offset: 0, template: replacement)
                    value.replaceSubrange(range, with: replaced)
                }
            }
        }
        return value
    }
    private func localURL(_ path: String) -> URL? {
        guard !path.contains(":") && !path.hasPrefix("/") && !path.hasPrefix("~") else { return nil }
        let directory = baseURL.standardizedFileURL
        let result = directory.appendingPathComponent(path).standardizedFileURL
        guard result.path.hasPrefix(directory.path + "/") else { return nil }
        return result
    }
}

@MainActor
final class MarkdownViewController: NSViewController, NSTextViewDelegate {
    let url: URL
    private let store: MarkdownStore
    private let editor = NSTextView()
    private let preview = WKWebView()
    private let splitController = NSSplitViewController()
    private let sourceController = NSViewController()
    private let previewController = NSViewController()
    private lazy var sourceItem = NSSplitViewItem(viewController: sourceController)
    private lazy var previewItem = NSSplitViewItem(viewController: previewController)
    private let status = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl()
    private var savedDividerPosition: CGFloat = 0
    private var isPreviewOnly = false
    private var previewTask: Task<Void, Never>?
    private(set) var isDirty = false
    private var savedHash: String
    var onDirtyChange: ((Bool) -> Void)?
    init(url: URL, text: String, savedHash: String, store: MarkdownStore = MarkdownStore()) {
        self.url = url; self.store = store
        self.savedHash = savedHash
        super.init(nibName: nil, bundle: nil)
        editor.string = text
    }
    required init?(coder: NSCoder) { return nil }
    override func loadView() {
        let container = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textContainerInset = NSSize(width: 16, height: 16)
        editor.delegate = self
        editor.setAccessibilityLabel(String(localized: "markdown.source"))
        preview.setAccessibilityLabel(String(localized: "markdown.preview"))
        sourceController.view = scroll
        previewController.view = preview
        sourceItem.minimumThickness = 200
        previewItem.minimumThickness = 200
        sourceItem.canCollapse = false
        previewItem.canCollapse = false
        sourceItem.preferredThicknessFraction = 0.5
        previewItem.preferredThicknessFraction = 0.5
        splitController.splitView.isVertical = true
        splitController.splitView.dividerStyle = .thin
        splitController.addSplitViewItem(sourceItem)
        splitController.addSplitViewItem(previewItem)
        addChild(splitController)
        let splitView = splitController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(splitView)
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)
        footer.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .secondaryLabelColor
        modeControl.segmentCount = 2
        modeControl.setLabel(String(localized: "markdown.mode.split"), forSegment: 0)
        modeControl.setLabel(String(localized: "markdown.mode.preview"), forSegment: 1)
        modeControl.trackingMode = .selectOne
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(changeMarkdownMode)
        modeControl.setAccessibilityLabel(String(localized: "markdown.mode.label"))
        footer.addArrangedSubview(modeControl)
        footer.addArrangedSubview(status)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
        view = container
        schedulePreview()
    }
    @objc private func changeMarkdownMode() {
        let showPreviewOnly = modeControl.selectedSegment == 1
        guard showPreviewOnly != isPreviewOnly else { return }
        if showPreviewOnly {
            savedDividerPosition = splitController.splitView.subviews.first?.frame.width ?? 0
            splitController.removeSplitViewItem(sourceItem)
            isPreviewOnly = true
        } else {
            isPreviewOnly = false
            splitController.removeSplitViewItem(previewItem)
            splitController.addSplitViewItem(sourceItem)
            splitController.addSplitViewItem(previewItem)
            view.layoutSubtreeIfNeeded()
            restoreDivider()
        }
    }
    private func restoreDivider() {
        guard savedDividerPosition > 0 else { return }
        splitController.splitView.setPosition(savedDividerPosition, ofDividerAt: 0)
    }
    func textDidChange(_ notification: Notification) {
        isDirty = true
        onDirtyChange?(true)
        schedulePreview(delay: .milliseconds(250))
    }
    func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
    }
    private func schedulePreview(delay: Duration? = nil) {
        cancelPreview()
        previewTask = Task { [weak self] in
            do {
                if let delay { try await Task.sleep(for: delay) }
                guard let self else { return }
                let markdown = self.editor.string
                let renderer = MarkdownHTML(baseURL: self.url.deletingLastPathComponent())
                let rendering = Task.detached(priority: .userInitiated) {
                    try renderer.render(markdown)
                }
                let html = try await withTaskCancellationHandler {
                    try await rendering.value
                } onCancel: {
                    rendering.cancel()
                }
                guard !Task.isCancelled else { return }
                self.preview.loadHTMLString(html, baseURL: self.url.deletingLastPathComponent())
            } catch is CancellationError {
                return
            } catch {
                self?.status.stringValue = error.localizedDescription
            }
        }
    }
    func save() throws {
        try store.save(editor.string, to: url, expectedSha256: savedHash)
        savedHash = store.hash(editor.string)
        isDirty = false
        onDirtyChange?(false)
        status.stringValue = String(localized: "markdown.saved")
    }
    var selectionInfo: [String: Any] {
        guard let range = Range(editor.selectedRange(), in: editor.string) else {
            return ["type": "markdown", "selectedText": ""]
        }
        let offset = editor.string.distance(from: editor.string.startIndex, to: range.lowerBound)
        return ["type": "markdown", "offset": offset,
                "length": editor.string.distance(from: range.lowerBound, to: range.upperBound),
                "selectedText": String(editor.string[range].prefix(8_000))]
    }
}
