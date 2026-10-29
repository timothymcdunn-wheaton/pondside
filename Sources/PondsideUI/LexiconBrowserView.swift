import AppKit
import SwiftUI
import PondsideCore
import PondsideEngrave
import PondsideLexicon
import PondsideBridge

/// The Lexicon pane: every entry the score can use, searchable, with its
/// params and README, an engraved preview, and, for drafts an agent
/// proposed, the person's decision: accept into the project or the user's
/// library, or discard (DESIGN.md §7–8). Graphic entries can go over the
/// selection from here.
@MainActor
final class LexiconBrowserModel: ObservableObject {
    @Published var query = ""
    @Published var selected: String?
    @Published var entries: [Lexicon.Loaded] = []
    @Published var preview: NSImage?
    @Published var previewing = false
    @Published var message: String?
    var project: URL?
    var installation: LilyPondInstallation?
    var onInsert: (LexiconEntry) -> Void = { _ in }

    func reload() {
        let lex = Lexicon.load(Lexicon.standardScopes(project: project))
        let words = query.lowercased().split(separator: " ").map(String.init)
        entries = lex.entries.values
            .filter { l in
                words.allSatisfy { w in
                    ([l.entry.id, l.entry.gloss] + l.entry.tags).joined(separator: " ").lowercased().contains(w)
                }
            }
            .sorted { ($0.scope == .draft ? 0 : 1, $0.entry.id) < ($1.scope == .draft ? 0 : 1, $1.entry.id) }
        if let s = selected, !entries.contains(where: { $0.entry.id == s }) { selected = nil; preview = nil }
    }

    var current: Lexicon.Loaded? { entries.first { $0.entry.id == selected } }

    func readme(_ l: Lexicon.Loaded) -> String {
        (try? String(contentsOf: l.directory.appendingPathComponent(l.entry.readmeFile), encoding: .utf8)) ?? ""
    }

    /// Engraves the entry with its defaults, off the main actor.
    func renderPreview() {
        guard let l = current, let lily = installation else {
            message = installation == nil ? "Previews need LilyPond" : nil
            return
        }
        previewing = true
        preview = nil
        let lex = Lexicon.load(Lexicon.standardScopes(project: project))
        let entry = l.entry
        let id = entry.id
        Task {
            let image = await Self.render(entry: entry, include: lex.includeFile(for: [id]), lily: lily)
            guard self.selected == id else { return }
            self.preview = image
            self.previewing = false
            if image == nil { self.message = "The preview didn't engrave" }
        }
    }

    nonisolated static func render(entry: LexiconEntry, include: String, lily: LilyPondInstallation) async -> NSImage? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-lexicon-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(include.utf8).write(to: dir.appendingPathComponent("lexicon.ily"))
            let file = dir.appendingPathComponent("preview.ly")
            try Data(GraphicEdit.previewSource(entry: entry).utf8).write(to: file)
            let result = try await LilyPondEngraver(installation: lily).engrave(file, purpose: .export(.png), outputDirectory: dir.appendingPathComponent("out"))
            guard let png = result.outputFiles.first, let image = NSImage(contentsOf: png) else { return nil }
            return image
        } catch {
            return nil
        }
    }

    func accept(_ l: Lexicon.Loaded, to scope: Lexicon.Scope) {
        guard let project else { return }
        do {
            try Lexicon.promote(id: l.entry.id, project: project, to: scope)
            message = "Accepted \(l.entry.id) into \(scope == .user ? "your library" : "the project's Lexicon")"
        } catch {
            message = "\(error)"
        }
        reload()
    }

    func discard(_ l: Lexicon.Loaded) {
        guard let project else { return }
        let alert = NSAlert()
        alert.messageText = "Discard the draft “\(l.entry.id)”?"
        alert.informativeText = "Its folder in Lexicon/drafts is deleted. Uses of it in the score stay, and will report an unknown entry."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Lexicon.discard(id: l.entry.id, project: project)
            message = "Discarded \(l.entry.id)"
        } catch {
            message = "\(error)"
        }
        reload()
    }
}

struct LexiconBrowserView: View {
    @ObservedObject var model: LexiconBrowserModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search the Lexicon", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                    .onChange(of: model.query) { model.reload() }
                List(model.entries, id: \.entry.id, selection: $model.selected) { l in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(l.entry.id).font(.body.weight(.medium))
                            if l.scope == .draft {
                                Text("draft").font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.orange.opacity(0.25)))
                                    .accessibilityLabel("Draft, not yet accepted")
                            }
                        }
                        Text(l.entry.gloss).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: model.selected) { model.renderPreview() }
            }
            .frame(minWidth: 220, idealWidth: 260)
            detail.frame(minWidth: 300)
        }
        .onAppear { model.reload() }
    }

    @ViewBuilder private var detail: some View {
        if let l = model.current {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(l.entry.id).font(.title3.weight(.semibold))
                        Text("\(l.entry.version) · \(l.scope.rawValue) · \(l.entry.kind.rawValue)")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(l.entry.gloss)
                    Group {
                        if let image = model.preview {
                            Image(nsImage: image).resizable().scaledToFit()
                                .background(Color(nsColor: Theme.lensPaper))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel("Engraved preview of \(l.entry.id)")
                        } else if model.previewing {
                            ProgressView().controlSize(.small)
                        }
                    }
                    actions(l)
                    if let message = model.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("Parameters").font(.headline)
                    ForEach(l.entry.params, id: \.name) { p in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(p.name).font(.body.monospaced())
                                Text(p.type.rawValue).font(.caption).foregroundStyle(.secondary)
                                if let d = p.defaultValue { Text("= \(Lexicon.scheme(d))").font(.caption.monospaced()).foregroundStyle(.secondary) }
                            }
                            if let doc = p.doc { Text(doc).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Divider()
                    Text(model.readme(l)).font(.callout).textSelection(.enabled)
                }
                .padding(14)
            }
        } else {
            Text("Choose an entry").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func actions(_ l: Lexicon.Loaded) -> some View {
        HStack {
            if l.entry.kind == .graphic {
                Button("Insert over Selection") { model.onInsert(l.entry) }
                    .help("From the first selected note to the last, in their staff")
            }
            if l.scope == .draft {
                Button("Accept into Project") { model.accept(l, to: .project) }
                Button("Accept into My Library") { model.accept(l, to: .user) }
                Button("Discard…", role: .destructive) { model.discard(l) }
            }
        }
    }
}

/// The pane's view: the SwiftUI browser in a host the pane system can hold.
@MainActor
final class LexiconBrowserPane: NSView {
    let model = LexiconBrowserModel()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.editorBackground.cgColor
        let host = NSHostingView(rootView: LexiconBrowserView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
