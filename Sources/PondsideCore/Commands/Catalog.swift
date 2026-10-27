/// Every command Pondside has. The keyboard audit (CommandTests) runs over
/// this list: each entry needs a chord, a shortcut or a direct key, and no
/// two chords may collide or shadow each other.
public enum CommandCatalog {
    /// Names shown in the hint bar after the leader and a group key.
    public static let groups: [Character: String] = [
        "f": "file", "g": "go", "a": "add", "e": "edit", "v": "view", "p": "pane", "w": "workspace", "h": "help",
    ]

    public static let standard: [CommandSpec] = file + go + add + edit + view + pane + help

    static let file: [CommandSpec] = [
        CommandSpec("file.new", "New Score…", "Create a LilyPond file from a template and open it", category: "File",
                    chords: ["fn"], shortcut: KeyStroke("n", .command)),
        CommandSpec("file.open", "Open…", "Open a .ly or .ily file", category: "File",
                    chords: ["fo"], shortcut: KeyStroke("o", .command)),
        CommandSpec("file.exportPDF", "Export PDF…", "Engrave a PDF for performers, without local file paths", category: "File",
                    chords: ["fe"], shortcut: KeyStroke("e", .command)),
        CommandSpec("file.reveal", "Reveal in Finder", "Show the score's file in the Finder", category: "File",
                    chords: ["fr"], shortcut: KeyStroke("r", [.command, .option])),
        CommandSpec("file.close", "Close", "Close this window; your work is already saved", category: "File",
                    chords: ["fw"], shortcut: KeyStroke("w", .command)),
    ]

    static let go: [CommandSpec] = [
        CommandSpec("go.file", "Go to File…", "Pick one of the score's files to edit", category: "Go",
                    chords: ["gf"], shortcut: KeyStroke("p", .command)),
        CommandSpec("go.nextFile", "Next File", "Edit the next file the score includes", category: "Go", requires: .severalFiles,
                    chords: ["gn"], shortcut: KeyStroke("]", [.command, .shift])),
        CommandSpec("go.previousFile", "Previous File", "Edit the previous file the score includes", category: "Go",
                    requires: .severalFiles, chords: ["gp"], shortcut: KeyStroke("[", [.command, .shift])),
        CommandSpec("go.error", "Go to Error", "Jump to the next compiler error in the source", category: "Go", requires: .errors,
                    chords: ["ge"], shortcut: KeyStroke("'", .command)),
        CommandSpec("go.first", "Go to First Note", "Select the first note of the file", category: "Go",
                    chords: ["gg"]),
        CommandSpec("go.last", "Go to Last Note", "Select the last note of the file", category: "Go",
                    chords: ["gl"]),
        CommandSpec("go.next", "Next Object", "Select the next note or rest", category: "Go", keys: ["→"]),
        CommandSpec("go.previous", "Previous Object", "Select the previous note or rest", category: "Go", keys: ["←"]),
    ]

    static let add: [CommandSpec] = [
        CommandSpec("add.slur", "Add Slur", "Slur the selection from its first note to its last", category: "Add",
                    requires: .selection, chords: ["as"], keys: ["(", ")"]),
        CommandSpec("add.beam", "Add Beam", "Beam the selection manually", category: "Add",
                    requires: .selection, chords: ["ab"], keys: ["[", "]"]),
        CommandSpec("add.tie", "Add Tie", "Tie the selected note to the next", category: "Add",
                    requires: .selection, chords: ["ai"], keys: ["~"]),
        CommandSpec("add.tuplet", "Add Tuplet", "Make the selection a triplet (\\tuplet 3/2)", category: "Add",
                    requires: .selection, chords: ["at"]),
        CommandSpec("add.dynamic", "Add Dynamic…", "Put a dynamic on the selection: pp p mp mf f ff sfz…", category: "Add",
                    requires: .selection, chords: ["ad"], keys: ["\\f⏎"]),
        CommandSpec("add.crescendo", "Add Crescendo", "A crescendo hairpin over the selection", category: "Add",
                    requires: .selection, chords: ["ac"]),
        CommandSpec("add.decrescendo", "Add Decrescendo", "A decrescendo hairpin over the selection", category: "Add",
                    requires: .selection, chords: ["ar"]),
        CommandSpec("add.staccato", "Add Staccato", "Toggle a staccato dot", category: "Add",
                    requires: .selection, chords: ["a."], keys: ["-."]),
        CommandSpec("add.accent", "Add Accent", "Toggle an accent", category: "Add",
                    requires: .selection, chords: ["aa"], keys: ["->"]),
        CommandSpec("add.tenuto", "Add Tenuto", "Toggle a tenuto line", category: "Add",
                    requires: .selection, chords: ["a-"], keys: ["--"]),
        CommandSpec("add.fermata", "Add Fermata", "Toggle a fermata", category: "Add",
                    requires: .selection, chords: ["af"], keys: ["\\fermata⏎"]),
        CommandSpec("add.note", "Insert Note", "Insert a note after the selection: a–g, nearest octave", category: "Add",
                    keys: ["a", "b", "c", "d", "e", "f", "g"]),
        CommandSpec("add.rest", "Insert Rest", "Insert a rest after the selection", category: "Add", keys: ["r"]),
        CommandSpec("add.mouse", "Place Note with Mouse", "With a duration armed, click a staff to put a note there",
                    category: "Add", keys: ["click"]),
    ]

    static let edit: [CommandSpec] = [
        CommandSpec("edit.undo", "Undo", "Undo the last change in this file", category: "Edit",
                    chords: ["eu"], shortcut: KeyStroke("z", .command)),
        CommandSpec("edit.redo", "Redo", "Redo the last undone change", category: "Edit",
                    chords: ["eU"], shortcut: KeyStroke("z", [.command, .shift])),
        CommandSpec("edit.delete", "Delete", "Delete the selection; every other note keeps its pitch and duration",
                    category: "Edit", requires: .selection, chords: ["ex"], keys: ["⌫"]),
        CommandSpec("edit.source", "Edit in Source", "Put the text cursor at the selection", category: "Edit",
                    chords: ["ee"], keys: ["↩"]),
        CommandSpec("edit.find", "Find…", "Search the source", category: "Edit",
                    chords: ["ef"], shortcut: KeyStroke("f", .command)),
        CommandSpec("edit.selectAll", "Select All", "Select everything in the focused pane", category: "Edit",
                    chords: ["ea"], shortcut: KeyStroke("a", .command)),
        CommandSpec("edit.up", "Pitch Up", "Raise a step · ⇧ an octave · ⌥ a semitone", category: "Edit",
                    requires: .selection, keys: ["↑", "⇧↑", "⌥↑"]),
        CommandSpec("edit.down", "Pitch Down", "Lower a step · ⇧ an octave · ⌥ a semitone", category: "Edit",
                    requires: .selection, keys: ["↓", "⇧↓", "⌥↓"]),
        CommandSpec("edit.duration", "Set Duration", "1 2 4 8 16 32: change the selection, or arm the next note",
                    category: "Edit", keys: ["1", "2", "4", "8", "16"]),
        CommandSpec("edit.dot", "Toggle Dot", "Add or remove a duration dot", category: "Edit", keys: ["."]),
        CommandSpec("edit.disarm", "Disarm Duration", "Stop mouse entry; ⎋ also deselects", category: "Edit", keys: ["⎋"]),
    ]

    static let view: [CommandSpec] = [
        CommandSpec("view.zoomIn", "Zoom In", "Enlarge the score", category: "View",
                    chords: ["v="], shortcut: KeyStroke("=", .command)),
        CommandSpec("view.zoomOut", "Zoom Out", "Shrink the score", category: "View",
                    chords: ["v-"], shortcut: KeyStroke("-", .command)),
        CommandSpec("view.actualSize", "Actual Size", "Show the paper at its printed size", category: "View",
                    chords: ["v0"], shortcut: KeyStroke("0", [.command, .option])),
        CommandSpec("view.fitWidth", "Fit Width", "Fit the page width to the pane", category: "View",
                    chords: ["vw"], shortcut: KeyStroke("0", .command)),
        CommandSpec("view.lightsOut", "Lights Out", "Dim the paper for night work (display only, never exported)",
                    category: "View", chords: ["vl"], shortcut: KeyStroke("l", [.command, .shift])),
        CommandSpec("view.fullScreen", "Full Screen", "Use the whole display", category: "View",
                    chords: ["vf"], shortcut: KeyStroke("f", [.command, .control])),
    ]

    static let pane: [CommandSpec] = {
        var specs: [CommandSpec] = [
            CommandSpec("pane.focusNext", "Focus Next Pane", "Move the keyboard to the next pane", category: "Pane",
                        chords: ["pj"], shortcut: KeyStroke("j", .command)),
            CommandSpec("pane.cycleNext", "Next Content", "Show the next kind of content in the focused pane", category: "Pane",
                        chords: ["pn"], shortcut: KeyStroke("tab", .control)),
            CommandSpec("pane.cyclePrevious", "Previous Content", "Show the previous kind of content in the focused pane",
                        category: "Pane", chords: ["pp"], shortcut: KeyStroke("tab", [.control, .shift])),
        ]
        for c in PaneContent.allCases {
            specs.append(CommandSpec(CommandID(rawValue: "pane.show.\(c.rawValue)"), "Show \(c.title)",
                                     "Put \(c.title.lowercased()) in the focused pane, keeping the layout", category: "Pane",
                                     chords: [Chord("p" + String(c.chordKey))],
                                     shortcut: KeyStroke(String(c.number), .control)))
        }
        for (i, preset) in PaneLayout.presets.enumerated() {
            specs.append(CommandSpec(CommandID(rawValue: "workspace.preset\(i + 1)"), "Layout: \(preset.name)",
                                     "Switch to the \(preset.name.lowercased()) layout", category: "Workspace",
                                     chords: [Chord("w\(i + 1)")], shortcut: KeyStroke("\(i + 1)", .command)))
        }
        specs.append(CommandSpec("workspace.save", "Save Workspace…", "Save this arrangement of panes under a name",
                                 category: "Workspace", chords: ["ws"], shortcut: KeyStroke("s", [.command, .shift])))
        return specs
    }()

    static let help: [CommandSpec] = [
        CommandSpec("help.palette", "Command Palette", "Find any command by typing a few letters", category: "Help",
                    chords: [" "], shortcut: KeyStroke("k", .command)),
        CommandSpec("help.context", "What Can I Do Here?", "Every action for the current selection, with its keys",
                    category: "Help", chords: ["?"], shortcut: KeyStroke("/", .command)),
        CommandSpec("help.keys", "All Keys", "Every command and its chord", category: "Help", chords: ["hk"]),
        CommandSpec("help.about", "About Pondside", "Version, and why you can leave any time", category: "Help",
                    chords: ["ha"]),
    ]
}
