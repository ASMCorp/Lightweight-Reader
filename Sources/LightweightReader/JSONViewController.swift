import AppKit

@MainActor
private final class TreeNode {
    enum Role { case value(JSONEntry), next, previous, loading, error(String) }
    let role: Role
    weak var parent: TreeNode?
    var children: [TreeNode] = []
    var page = 0
    var loaded = false
    var requestID = 0
    var task: Task<Void, Never>?
    init(_ role: Role, parent: TreeNode? = nil) { self.role = role; self.parent = parent }
    deinit { task?.cancel() }
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
    func cancelTasksRecursively() {
        requestID &+= 1
        task?.cancel()
        task = nil
        for child in children { child.cancelTasksRecursively() }
    }
    func clearRecursively() {
        requestID &+= 1
        task?.cancel()
        task = nil
        for child in children { child.clearRecursively() }
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
    private var startedRootLoad = false
    init(index: JSONIndex) {
        self.index = index
        root = TreeNode(.value(index.root))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
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
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        startRootLoadIfNeeded()
    }
    private func startRootLoadIfNeeded() {
        guard !startedRootLoad else { return }
        startedRootLoad = true
        outline.reloadData()
        load(root, page: 0, duringExpansion: false)
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
        // AppKit is already expanding this item, so only prepare its child model here.
        load(node, page: 0, duringExpansion: true)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode else { return }
        node.cancelTasksRecursively()
        node.loaded = false
        retainedPages.removeAll { $0 === node || isAncestor(node, of: $0) }
        // Keep the old children alive until AppKit finishes the collapse callback.
        Task { [weak self, weak node] in
            guard let self, let node, !self.outline.isItemExpanded(node), !node.loaded else { return }
            node.clearRecursively()
        }
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
        case .error(let message): label.stringValue = message
        }
        cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? TreeNode, let parent = node.parent else { return }
        switch node.role {
        case .next:
            Task { [weak self, weak parent] in
                guard let self, let parent, self.outline.isItemExpanded(parent) else { return }
                self.outline.deselectAll(nil)
                self.load(parent, page: parent.page + 1, duringExpansion: false)
            }
        case .previous:
            Task { [weak self, weak parent] in
                guard let self, let parent, self.outline.isItemExpanded(parent) else { return }
                self.outline.deselectAll(nil)
                self.load(parent, page: max(0, parent.page - 1), duringExpansion: false)
            }
        case .value: status.stringValue = node.pointer.isEmpty ? "/" : node.pointer
        case .loading, .error: break
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
        startRootLoadIfNeeded()
        guard pointer.isEmpty || pointer.hasPrefix("/") else { throw AgentDocumentError.invalid("JSON pointer") }
        var node = root
        if !pointer.isEmpty {
            for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
                let component = String(raw).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                guard let parentEntry = node.entry, parentEntry.type != .scalar else { throw AgentDocumentError.notFound }
                let index = index
                let requestID = node.requestID
                let search = Task.detached(priority: .userInitiated) {
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
                }
                let (pageData, pageNumber, childIndex) = try await withTaskCancellationHandler {
                    try await search.value
                } onCancel: {
                    search.cancel()
                }
                try Task.checkCancellation()
                guard node.requestID == requestID else { throw CancellationError() }
                node.cancelTasksRecursively()
                install(pageData, on: node, page: pageNumber)
                let next = node.children[childIndex + (pageNumber > 0 ? 1 : 0)]
                retainPage(node, protecting: next)
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
    private func load(_ node: TreeNode, page: Int, duringExpansion: Bool) {
        guard let entry = node.entry else { return }
        node.task?.cancel()
        node.requestID &+= 1
        let requestID = node.requestID
        let oldChildren = node.children
        node.children = [TreeNode(.loading, parent: node)]
        node.loaded = true
        if !duringExpansion {
            if outline.isItemExpanded(node) {
                outline.reloadItem(node, reloadChildren: true)
            } else {
                outline.expandItem(node)
            }
        }
        Task { oldChildren.forEach { $0.clearRecursively() } }
        let index = index
        node.task = Task { [weak self, weak node] in
            let scan = Task.detached(priority: .userInitiated) { try index.page(for: entry, number: page) }
            do {
                let result = try await withTaskCancellationHandler {
                    try await scan.value
                } onCancel: {
                    scan.cancel()
                }
                guard !Task.isCancelled, let self, let node,
                      node.requestID == requestID, self.outline.isItemExpanded(node) else { return }
                self.install(result, on: node, page: page)
                self.status.stringValue = String(format: String(localized: "json.page"), page + 1)
                self.retainPage(node, protecting: node)
            } catch is CancellationError { } catch {
                guard !Task.isCancelled, let self, let node,
                      node.requestID == requestID, self.outline.isItemExpanded(node) else { return }
                let oldChildren = node.children
                node.children = [TreeNode(.error(error.localizedDescription), parent: node)]
                self.outline.reloadItem(node, reloadChildren: true)
                oldChildren.forEach { $0.clearRecursively() }
                self.status.stringValue = error.localizedDescription
            }
        }
    }
    private func install(_ pageData: JSONPage, on node: TreeNode, page: Int) {
        let oldChildren = node.children
        node.children = pageData.entries.map { TreeNode(.value($0), parent: node) }
        if page > 0 { node.children.insert(TreeNode(.previous, parent: node), at: 0) }
        if pageData.hasMore { node.children.append(TreeNode(.next, parent: node)) }
        node.page = page
        node.loaded = true
        if outline.isItemExpanded(node) {
            outline.reloadItem(node, reloadChildren: true)
        } else {
            outline.expandItem(node)
        }
        oldChildren.forEach { $0.clearRecursively() }
    }
    private func retainPage(_ node: TreeNode, protecting activeNode: TreeNode) {
        guard node !== root else { return }
        retainedPages.removeAll { $0 === node }
        retainedPages.append(node)
        while retainedPages.count > 8 {
            guard let index = retainedPages.firstIndex(where: {
                $0 !== activeNode && !isAncestor($0, of: activeNode)
            }) else { break }
            let oldest = retainedPages.remove(at: index)
            if outline.isItemExpanded(oldest) {
                outline.collapseItem(oldest)
            } else {
                oldest.clearRecursively()
            }
        }
    }
}
