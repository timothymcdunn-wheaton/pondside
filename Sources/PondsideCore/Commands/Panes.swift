/// What a pane can show. Panes are frames; content is cargo: swapping
/// content never changes a pane's geometry.
public enum PaneContent: String, CaseIterable, Codable, Hashable, Sendable {
    case score, lilypond, compilerOutput, terminal, supercollider, python, agent, cues, lexicon, osc

    public var title: String {
        switch self {
        case .score: return "Score"
        case .lilypond: return "LilyPond Source"
        case .compilerOutput: return "Compiler Output"
        case .terminal: return "Terminal"
        case .supercollider: return "SuperCollider Source"
        case .python: return "Python Source"
        case .agent: return "Agent"
        case .cues: return "Cue Inspector"
        case .lexicon: return "Lexicon"
        case .osc: return "OSC Monitor"
        }
    }

    /// ⌃1…⌃9, then ⌃0.
    public var number: Int {
        let i = Self.allCases.firstIndex(of: self)! + 1
        return i == 10 ? 0 : i
    }

    /// The key after `␣ p`.
    public var chordKey: Character {
        switch self {
        case .score: return "s"
        case .lilypond: return "l"
        case .compilerOutput: return "o"
        case .terminal: return "t"
        case .supercollider: return "c"
        case .python: return "y"
        case .agent: return "a"
        case .cues: return "u"
        case .lexicon: return "x"
        case .osc: return "m"
        }
    }
}

/// A window's arrangement: panes side by side (columns) or stacked (rows),
/// each with its share of the space and its content.
public struct PaneLayout: Codable, Hashable, Sendable {
    public enum Axis: String, Codable, Hashable, Sendable { case columns, rows }

    public var name: String
    public var axis: Axis
    public var contents: [PaneContent]
    /// Shares of the window, summing to 1.
    public var fractions: [Double]
    public var focused: Int

    public init(name: String, axis: Axis = .columns, contents: [PaneContent], fractions: [Double]? = nil, focused: Int = 0) {
        self.name = name
        self.axis = axis
        self.contents = contents
        let n = Double(max(contents.count, 1))
        self.fractions = fractions ?? Array(repeating: 1 / n, count: contents.count)
        self.focused = min(max(focused, 0), max(contents.count - 1, 0))
    }

    public static let presets: [PaneLayout] = [
        PaneLayout(name: "Write", contents: [.lilypond, .score], fractions: [0.42, 0.58], focused: 1),
        PaneLayout(name: "Read", contents: [.score]),
        PaneLayout(name: "Electronics", contents: [.supercollider, .score], fractions: [0.42, 0.58], focused: 1),
        PaneLayout(name: "Debug", contents: [.lilypond, .score, .compilerOutput], fractions: [0.34, 0.46, 0.2], focused: 0),
        PaneLayout(name: "Terminal", contents: [.terminal, .score], fractions: [0.42, 0.58], focused: 0),
    ]

    public var focusedContent: PaneContent? { contents.indices.contains(focused) ? contents[focused] : nil }

    /// Moves focus to the next pane, wrapping.
    public mutating func focusNext() {
        guard !contents.isEmpty else { return }
        focused = (focused + 1) % contents.count
    }

    /// Steps the focused pane through `available` content (skipping what
    /// another pane already shows), keeping every frame where it is.
    public mutating func cycle(forward: Bool = true, available: [PaneContent] = PaneContent.allCases) {
        guard let current = focusedContent else { return }
        let others = Set(contents.enumerated().filter { $0.offset != focused }.map(\.element))
        let candidates = available.filter { !others.contains($0) || $0 == current }
        let n = candidates.count
        guard n > 1 else { return }
        // Content outside `available` steps onto its first or last entry.
        let i = candidates.firstIndex(of: current) ?? (forward ? n - 1 : 0)
        contents[focused] = candidates[(i + (forward ? 1 : n - 1)) % n]
    }

    /// Shows `content` in the focused pane. If another pane shows it already,
    /// the two swap, so nothing is shown twice and nothing moves.
    public mutating func show(_ content: PaneContent) {
        guard let current = focusedContent, current != content else { return }
        if let other = contents.firstIndex(of: content) { contents[other] = current }
        contents[focused] = content
    }
}

/// Named arrangements saved by the user (`⌘⇧S`). Encoded as JSON by the UI.
public struct Workspaces: Codable, Hashable, Sendable {
    public var saved: [PaneLayout]

    public init(saved: [PaneLayout] = []) { self.saved = saved }

    /// Saves `layout` under `name`, replacing one of the same name.
    public mutating func save(_ layout: PaneLayout, as name: String) {
        var l = layout
        l.name = name
        if let i = saved.firstIndex(where: { $0.name == name }) { saved[i] = l } else { saved.append(l) }
    }
}
