import AppKit
import PDFKit

@MainActor
final class PDFViewController: NSViewController, NSSearchFieldDelegate, PDFViewDelegate {
    private let document: PDFDocument
    private let pdfView = PDFView()
    private let pageLabel = NSTextField(labelWithString: "")
    private let search = NSSearchField()
    init(document: PDFDocument) { self.document = document; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { return nil }
    override func loadView() {
        let container = NSView()
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let previous = NSButton(title: String(localized: "pdf.previous"), target: self, action: #selector(previousPage))
        let next = NSButton(title: String(localized: "pdf.next"), target: self, action: #selector(nextPage))
        let zoomOut = NSButton(title: "−", target: self, action: #selector(decreaseZoom))
        let zoomIn = NSButton(title: "+", target: self, action: #selector(increaseZoom))
        search.placeholderString = String(localized: "pdf.search")
        search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true
        toolbar.addArrangedSubview(previous); toolbar.addArrangedSubview(next)
        toolbar.addArrangedSubview(pageLabel); toolbar.addArrangedSubview(zoomOut); toolbar.addArrangedSubview(zoomIn)
        toolbar.addArrangedSubview(search)
        container.addSubview(toolbar)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.delegate = self
        pdfView.setAccessibilityLabel(String(localized: "pdf.document"))
        container.addSubview(pdfView)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor), toolbar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor), toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.topAnchor.constraint(equalTo: toolbar.bottomAnchor), pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor), pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor), pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
        updatePage()
    }
    private func updatePage() {
        let current = pdfView.currentPage.map { document.index(for: $0) + 1 } ?? 0
        pageLabel.stringValue = String(format: String(localized: "pdf.page"), current, document.pageCount)
    }
    func goToPage(_ pageNumber: Int) -> Bool {
        guard pageNumber > 0, let page = document.page(at: pageNumber - 1) else { return false }
        pdfView.go(to: page)
        updatePage()
        return true
    }
    var selectionInfo: [String: Any] {
        ["type": "pdf", "page": pdfView.currentPage.map { document.index(for: $0) + 1 } ?? 0,
         "selectedText": String((pdfView.currentSelection?.string ?? "").prefix(8_000))]
    }
    func pdfViewPageChanged(_ notification: Notification) { updatePage() }
    @objc private func previousPage() { pdfView.goToPreviousPage(nil); updatePage() }
    @objc private func nextPage() { pdfView.goToNextPage(nil); updatePage() }
    @objc private func decreaseZoom() { pdfView.scaleFactor = max(pdfView.minScaleFactor, pdfView.scaleFactor / 1.2) }
    @objc private func increaseZoom() { pdfView.scaleFactor = min(pdfView.maxScaleFactor, pdfView.scaleFactor * 1.2) }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !search.stringValue.isEmpty else { return }
        let results = document.findString(search.stringValue, withOptions: .caseInsensitive)
        if let first = results.first { pdfView.setCurrentSelection(first, animate: true); pdfView.go(to: first) }
    }
}
