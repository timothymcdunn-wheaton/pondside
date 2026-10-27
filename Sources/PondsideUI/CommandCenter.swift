import AppKit
import PondsideCore

/// The app's keymap and palette history, shared by every window. The
/// catalog itself is portable (PondsideCore); this adds AppKit plumbing.
@MainActor
final class CommandCenter {
    static let shared = CommandCenter()

    private(set) var keymap: Keymap
    var palette: CommandPalette
    /// Why the user's keymap file was ignored, if it was.
    private(set) var keymapProblem: String?

    static var keymapURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pondside/keymap.txt")
    }

    private init() {
        var remap: [CommandID: [Chord]] = [:]
        var problem: String?
        if let data = FileManager.default.contents(atPath: Self.keymapURL.path) {
            do {
                remap = try Keymap.parseRemap(String(decoding: data, as: UTF8.self),
                                              known: Set(CommandCatalog.standard.map(\.id)))
            } catch {
                problem = "keymap.txt ignored: \(error)"
            }
        }
        var keymap = Keymap(remap: remap)
        if problem == nil, let first = keymap.problems().first {
            // A broken remap must never cost the user their keyboard.
            problem = "keymap.txt ignored: \(first)"
            keymap = Keymap()
        }
        self.keymap = keymap
        self.keymapProblem = problem
        self.palette = CommandPalette(keymap: keymap)
    }

    func spec(_ id: CommandID) -> CommandSpec? { keymap.commands[id] }

    /// A menu item that runs `id` through the responder chain, titled and
    /// keyed from the catalog so menus, palette and hints never disagree.
    func menuItem(_ id: CommandID, action: Selector = #selector(CommandResponder.performCommand(_:))) -> NSMenuItem {
        let spec = keymap.commands[id]
        let item = NSMenuItem(title: spec?.title ?? id.rawValue, action: action, keyEquivalent: "")
        item.representedObject = id.rawValue
        if let s = spec?.shortcut {
            item.keyEquivalent = Self.keyEquivalent(s)
            item.keyEquivalentModifierMask = Self.modifierFlags(s.modifiers)
        }
        item.toolTip = spec.map { tip(for: $0) }
        return item
    }

    /// "Gloss — keys", for tool tips.
    func tip(for spec: CommandSpec) -> String {
        var keys: [String] = []
        if let s = spec.shortcut { keys.append(s.description) }
        keys += spec.chords.map(\.description)
        keys += spec.keys
        return keys.isEmpty ? spec.gloss : "\(spec.gloss) — \(keys.joined(separator: " or "))"
    }

    static func keyEquivalent(_ s: KeyStroke) -> String {
        switch s.key {
        case "tab": return "\t"
        case "space": return " "
        case "return": return "\r"
        case "escape": return "\u{1b}"
        case "delete": return "\u{8}"
        case "up": return String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        case "down": return String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        case "left": return String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
        case "right": return String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        default: return s.key
        }
    }

    static func modifierFlags(_ m: KeyStroke.Modifiers) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if m.contains(.command) { f.insert(.command) }
        if m.contains(.control) { f.insert(.control) }
        if m.contains(.option) { f.insert(.option) }
        if m.contains(.shift) { f.insert(.shift) }
        return f
    }
}

/// Anything in the responder chain that runs catalog commands.
@MainActor
@objc protocol CommandResponder {
    func performCommand(_ sender: Any?)
}

extension NSMenuItem {
    /// The command a catalog-built item runs.
    var commandID: CommandID? { (representedObject as? String).map(CommandID.init(rawValue:)) }
}
