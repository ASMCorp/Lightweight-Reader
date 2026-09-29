import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private var project: ProjectViewController?
    private var confirmedWindowClose = false
    private var pendingOpenURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let project = ProjectViewController()
        self.project = project
        window.title = String(localized: "app.title")
        window.center()
        window.delegate = self
        window.contentViewController = project
        window.setContentSize(NSSize(width: 960, height: 640))
        window.minSize = NSSize(width: 640, height: 420)
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
        installMenu()
        NSApp.activate(ignoringOtherApps: true)
        if let pendingOpenURL {
            self.pendingOpenURL = nil
            _ = openDocument(at: pendingOpenURL)
        }
    }
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard (try? ReaderType(url: url)) != nil, FileManager.default.fileExists(atPath: url.path) else { return false }
        guard project != nil else { pendingOpenURL = url; return true }
        return openDocument(at: url)
    }
    private func installMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: String(localized: "app.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: String(localized: "file.menu"))
        let open = NSMenuItem(title: String(localized: "file.open"), action: #selector(openFile), keyEquivalent: "o")
        open.target = self
        let save = NSMenuItem(title: String(localized: "file.save"), action: #selector(saveFile), keyEquivalent: "s")
        save.target = self
        fileMenu.addItem(open); fileMenu.addItem(save)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        NSApp.mainMenu = main
    }
    @objc private func openFile() { project?.openDocument() }
    @objc private func saveFile() { project?.saveDocument() }
    func openDocument(at url: URL) -> Bool {
        guard let project, project.confirmDiscardIfNeeded() else { return false }
        project.open(url)
        mainWindow?.makeKeyAndOrderFront(nil)
        return true
    }
    func waitForOpen() async -> Bool { await project?.waitForOpen() ?? false }
    func selectionInfo() -> [String: Any]? { project?.selectionInfo() }
    func goToPDFPage(_ page: Int) -> Bool { project?.goToPDFPage(page) ?? false }
    func goToJSONPointer(_ pointer: String) async throws {
        guard let project else { throw AgentDocumentError.invalid("no document is open") }
        try await project.goToJSONPointer(pointer)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let approved = (project?.confirmDiscardIfNeeded() ?? true)
        confirmedWindowClose = approved
        return approved
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (confirmedWindowClose || (project?.confirmDiscardIfNeeded() ?? true)) ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
