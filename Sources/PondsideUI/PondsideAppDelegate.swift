import AppKit
import UniformTypeIdentifiers

/// Application entry point for the macOS front end.
@MainActor
public enum PondsideApplication {
    public static func run() {
        let app = NSApplication.shared
        let delegate = PondsideAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .darkAqua)
        // NSApplication holds its delegate weakly; keep ours alive.
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class PondsideAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controllers: [DocumentWindowController] = []
    private var openedFromLaunch = false
    private var lightsOut = UserDefaults.standard.bool(forKey: "Pondside.lightsOut")

    static let lilyPondTypes: [UTType] = [
        UTType(filenameExtension: "ly"), UTType(filenameExtension: "ily"),
    ].compactMap { $0 }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `PondsideApp score.ly` from a terminal or agent.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for path in args { self.open(URL(fileURLWithPath: path)) }
        NSApp.activate(ignoringOtherApps: true)
        if controllers.isEmpty && !openedFromLaunch { openDocument(nil) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFromLaunch = true
        urls.forEach { self.open($0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        controllers.forEach { $0.score.flushPendingSaves() }
    }

    func windowDidClose(_ controller: DocumentWindowController) {
        controllers.removeAll { $0 === controller }
    }

    // MARK: Opening

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let existing = controllers.first(where: { $0.score.root.matches(path: url.path) }) {
            existing.showWindow(nil)
            return
        }
        do {
            let document = try ScoreDocument(url: url)
            let controller = DocumentWindowController(document: document)
            controller.lightsOut = lightsOut
            controllers.append(controller)
            controller.showWindow(nil)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            _ = NSAlert(error: error).runModal()
        }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.lilyPondTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { self.open($0) }
    }

    @objc func newDocument(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.lilyPondTypes.prefix(1).map { $0 }
        panel.nameFieldStringValue = "Untitled.ly"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let template = """
        \\version "2.26.0"

        \\header {
          title = "Untitled"
        }

        \\relative c' {
          \\time 4/4
          c4 d e f | g1 \\bar "|."
        }

        """
        do {
            try Data(template.utf8).write(to: url, options: .atomic)
            self.open(url)
        } catch {
            _ = NSAlert(error: error).runModal()
        }
    }

    @objc func toggleLightsOut(_ sender: Any?) {
        lightsOut.toggle()
        UserDefaults.standard.set(lightsOut, forKey: "Pondside.lightsOut")
        controllers.forEach { $0.lightsOut = lightsOut }
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: """
            Your scores are plain LilyPond files. Pondside never stores your music \
            anywhere else and adds nothing you can't take with you: stop using \
            Pondside tomorrow and you lose nothing.

            Engraving by GNU LilyPond.
            """,
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Pondside",
            .applicationVersion: "0.1 (M1)",
            .credits: credits,
        ])
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleLightsOut(_:)) { item.state = lightsOut ? .on : .off }
        return true
    }

    // MARK: Menu

    /// Every command has a key equivalent; the chord system arrives in M3.
    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            for i in items { menu.addItem(i) }
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }

        submenu("Pondside", [
            item("About Pondside", #selector(showAbout(_:)), ""),
            .separator(),
            item("Hide Pondside", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Pondside", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("New Score…", #selector(newDocument(_:)), "n"),
            item("Open…", #selector(openDocument(_:)), "o"),
            .separator(),
            item("Export PDF…", #selector(DocumentWindowController.exportPDF(_:)), "e"),
            item("Reveal in Finder", #selector(DocumentWindowController.revealInFinder(_:)), "r", [.command, .option]),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f").tagged(Int(NSFindPanelAction.showFindPanel.rawValue)),
        ])
        submenu("View", [
            item("Switch Pane", #selector(DocumentWindowController.switchPane(_:)), "j"),
            item("Next File", #selector(DocumentWindowController.nextFile(_:)), "]", [.command, .shift]),
            item("Previous File", #selector(DocumentWindowController.previousFile(_:)), "[", [.command, .shift]),
            .separator(),
            item("Zoom In", #selector(DocumentWindowController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(DocumentWindowController.zoomOut(_:)), "-"),
            item("Actual Size", #selector(DocumentWindowController.actualSize(_:)), "0", [.command, .option]),
            item("Fit Width", #selector(DocumentWindowController.zoomToFitWidth(_:)), "0"),
            .separator(),
            item("Lights Out (display only)", #selector(toggleLightsOut(_:)), "l", [.command, .shift]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
        ])
        return main
    }
}

private extension NSMenuItem {
    func tagged(_ tag: Int) -> NSMenuItem {
        self.tag = tag
        return self
    }
}
