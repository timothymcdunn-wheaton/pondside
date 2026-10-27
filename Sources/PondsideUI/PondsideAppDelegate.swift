import AppKit
import UniformTypeIdentifiers
import PondsideCore

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
        lightsOutItem?.state = lightsOut ? .on : .off
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

    func validateMenuItem(_ item: NSMenuItem) -> Bool { true }

    /// The menu item's checkmark follows the setting wherever it changes.
    private weak var lightsOutItem: NSMenuItem?

    // MARK: Commands

    /// Commands that need no window.
    func runAppCommand(_ id: CommandID) {
        switch id.rawValue {
        case "file.new": newDocument(nil)
        case "file.open": openDocument(nil)
        case "view.lightsOut": toggleLightsOut(nil)
        case "help.about": showAbout(nil)
        default: NSSound.beep()
        }
    }

    // MARK: Menu

    /// Menus are built from the command catalog, so titles and shortcuts
    /// match the palette, the hints and the keyboard audit exactly.
    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let center = CommandCenter.shared

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
        func command(_ id: CommandID) -> NSMenuItem { center.menuItem(id) }
        func commands(category: String) -> [NSMenuItem] {
            center.keymap.specs.filter { $0.category == category && ($0.shortcut != nil || !$0.chords.isEmpty) }
                .map { center.menuItem($0.id) }
        }

        submenu("Pondside", [
            command("help.about"),
            .separator(),
            item("Hide Pondside", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Pondside", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            command("file.new"),
            command("file.open"),
            .separator(),
            command("file.exportPDF"),
            command("file.reveal"),
            .separator(),
            center.menuItem("file.close", action: #selector(NSWindow.performClose(_:))),
        ])
        submenu("Edit", [
            center.menuItem("edit.undo", action: Selector(("undo:"))),
            center.menuItem("edit.redo", action: Selector(("redo:"))),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            center.menuItem("edit.selectAll", action: #selector(NSText.selectAll(_:))),
            .separator(),
            center.menuItem("edit.find", action: #selector(NSTextView.performFindPanelAction(_:)))
                .tagged(Int(NSFindPanelAction.showFindPanel.rawValue)),
            .separator(),
            command("edit.delete"),
            command("edit.source"),
        ])
        submenu("Go", commands(category: "Go"))
        submenu("Add", commands(category: "Add"))
        var view = commands(category: "View").filter { $0.commandID != "view.fullScreen" }
        view += [.separator()] + commands(category: "Pane")
        view += [.separator(), center.menuItem("view.fullScreen", action: #selector(NSWindow.toggleFullScreen(_:)))]
        lightsOutItem = view.first { $0.commandID == "view.lightsOut" }
        lightsOutItem?.state = lightsOut ? .on : .off
        submenu("View", view)
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
        ] + commands(category: "Workspace"))
        submenu("Help", [command("help.palette"), command("help.context"), command("help.keys")])
        return main
    }
}

extension PondsideAppDelegate: CommandResponder {
    /// Reached when no window handles a command (e.g. none is open).
    @objc func performCommand(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.commandID else { return }
        runAppCommand(id)
    }
}

private extension NSMenuItem {
    func tagged(_ tag: Int) -> NSMenuItem {
        self.tag = tag
        return self
    }
}
