import AppKit

private final class TreeNode: @unchecked Sendable {
    enum Role { case value(JSONEntry), next, previous, loading }
    let role: Role
    weak var parent: TreeNode?
    var children: [TreeNode] = []
    var page = 0
    var loaded = false
    var task: Task<Void, Never>?
    init(_ role: Role, parent: TreeNode? = nil) { self.role = role; self.parent = parent }
    var entry: JSONEntry? { if case .value(let entry) = role { return entry }; return nil }
    var pointer: String {
        guard let parent, let entry else { return "" }
        let component: String
        if parent.entry?.type == .array {
            component = String(entry.label.dropFirst().dropLast())
        } else {
            component = entry.label.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        }
        return parent.pointer + "/" + component
    }
    func cancelRecursively() {
        task?.cancel()
        for child in children { child.cancelRecursively() }
        children.removeAll()
        loaded = false
    }
}

@MainActor
final class JSONViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let index: JSONIndex
    private let root: TreeNode
    private let outline = NSOutlineView()
    private let status = NSTextField(labelWithString: "")
    private var retainedPages: [TreeNode] = []
    init(index: JSONIndex) {
        self.index = index
        root = TreeNode(.value(index.root))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
    deinit { root.cancelRecursively() }

    override func loadView() {
        let container = NSView()
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        outline.headerView = nil
        outline.rowHeight = 24
        outline.usesAlternatingRowBackgroundColors = true
        outline.focusRingType = .default
        outline.setAccessibilityLabel(String(localized: "json.tree"))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        scroll.documentView = outline
        container.addSubview(scroll)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .secondaryLabelColor
        container.addSubview(status)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12), status.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8), status.heightAnchor.constraint(equalToConstant: 20)
        ])
        view = container
        load(root, page: 0)
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? TreeNode { return node.children.count }
        return 1
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? TreeNode { return node.children[index] }
        return root
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TreeNode, let entry = node.entry else { return false }
        return entry.type != .scalar
    }
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode, !node.loaded else { return }
        load(node, page: 0)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode else { return }
        node.cancelRecursively()
        retainedPages.removeAll { $0 === node }
        outline.reloadItem(node, reloadChildren: true)
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        switch node.role {
        case .value(let entry):
            label.stringValue = "\(entry.label):  \(entry.summary)"
            let typeName: String
            switch entry.type {
            case .object: typeName = String(localized: "json.type.object")
            case .array: typeName = String(localized: "json.type.array")
            case .scalar: typeName = String(localized: "json.type.value")
            }
            label.setAccessibilityLabel(String(format: String(localized: "json.accessibility.node"),
                                               node.pointer.isEmpty ? "/" : node.pointer, typeName, entry.summary))
        case .next: label.stringValue = String(localized: "json.next")
        case .previous: label.stringValue = String(localized: "json.previous")
        case .loading: label.stringValue = String(localized: "json.loading")
        }
        cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? TreeNode, let parent = node.parent else { return }
        switch node.role {
        case .next: load(parent, page: parent.page + 1)
        case .previous: load(parent, page: max(0, parent.page - 1))
        case .value: status.stringValue = node.pointer.isEmpty ? "/" : node.pointer
        case .loading: break
        }
    }
    var selectionInfo: [String: Any] {
        guard outline.selectedRow >= 0,
              let node = outline.item(atRow: outline.selectedRow) as? TreeNode,
              let entry = node.entry else { return ["type": "json", "pointer": ""] }
        return ["type": "json", "pointer": node.pointer, "summary": entry.summary]
    }
    func goToPointer(_ pointer: String) async throws {
        _ = view
        guard pointer.isEmpty || pointer.hasPrefix("/") else { throw AgentDocumentError.invalid("JSON pointer") }
        var node = root
        if !pointer.isEmpty {
            for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
                let component = String(raw).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                guard let parentEntry = node.entry, parentEntry.type != .scalar else { throw AgentDocumentError.notFound }
                let index = index
                let (pageData, pageNumber, childIndex) = try await Task.detached(priority: .userInitiated) {
                    var pageNumber = 0
                    while true {
                        try Task.checkCancellation()
                        let pageData = try index.page(for: parentEntry, number: pageNumber)
                        if let childIndex = pageData.entries.firstIndex(where: {
                            parentEntry.type == .object ? $0.label == component : $0.label == "[\(component)]"
                        }) { return (pageData, pageNumber, childIndex) }
                        guard pageData.hasMore else { throw AgentDocumentError.notFound }
                        pageNumber += 1
                    }
                }.value
                node.task?.cancel()
                node.children = pageData.entries.map { TreeNode(.value($0), parent: node) }
                if pageNumber > 0 { node.children.insert(TreeNode(.previous, parent: node), at: 0) }
                if pageData.hasMore { node.children.append(TreeNode(.next, parent: node)) }
                node.page = pageNumber
                node.loaded = true
                outline.reloadItem(node, reloadChildren: true)
                outline.expandItem(node)
                let next = node.children[childIndex + (pageNumber > 0 ? 1 : 0)]
                retainedPages.removeAll { $0 === node }
                retainedPages.append(node)
                while retainedPages.count > 8 {
                    let oldest = retainedPages.removeFirst()
                    if let pathChild = oldest.children.first(where: { isAncestor($0, of: next) }) {
                        oldest.children = [pathChild]
                        outline.reloadItem(oldest, reloadChildren: true)
                        outline.expandItem(oldest)
                    } else {
                        outline.collapseItem(oldest)
                        oldest.cancelRecursively()
                    }
                }
                node = next
            }
        }
        var ancestors: [TreeNode] = []
        var parent = node.parent
        while let current = parent { ancestors.append(current); parent = current.parent }
        for ancestor in ancestors.reversed() { outline.expandItem(ancestor) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { throw AgentDocumentError.notFound }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }
    private func isAncestor(_ possibleAncestor: TreeNode, of node: TreeNode) -> Bool {
        var current: TreeNode? = node
        while let candidate = current {
            if candidate === possibleAncestor { return true }
            current = candidate.parent
        }
        return false
    }
    private func load(_ node: TreeNode, page: Int) {
        guard let entry = node.entry else { return }
        node.task?.cancel()
        node.children = [TreeNode(.loading, parent: node)]
        node.loaded = true
        outline.reloadItem(node, reloadChildren: true)
        outline.expandItem(node)
        status.stringValue = String(localized: "json.loading")
        retainedPages.removeAll { $0 === node }
        retainedPages.append(node)
        while retainedPages.count > 8 {
            let oldest = retainedPages.removeFirst()
            if oldest !== node { outline.collapseItem(oldest); oldest.cancelRecursively() }
        }
        let index = index
        node.task = Task { [weak self, weak node] in
            let scan = Task.detached(priority: .userInitiated) { try index.page(for: entry, number: page) }
            do {
                let result = try await withTaskCancellationHandler {
                    try await scan.value
                } onCancel: {
                    scan.cancel()
                }
                guard !Task.isCancelled, let self, let node else { return }
                node.children = result.entries.map { TreeNode(.value($0), parent: node) }
                if page > 0 { node.children.insert(TreeNode(.previous, parent: node), at: 0) }
                if result.hasMore { node.children.append(TreeNode(.next, parent: node)) }
                node.page = page
                self.status.stringValue = String(format: String(localized: "json.page"), page + 1)
                self.outline.reloadItem(node, reloadChildren: true)
                self.outline.expandItem(node)
            } catch is CancellationError { } catch {
                self?.status.stringValue = error.localizedDescription
            }
        }
    }
}
