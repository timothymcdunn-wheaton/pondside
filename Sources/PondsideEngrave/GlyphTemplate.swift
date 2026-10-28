import Foundation
import PondsideCore

extension Graphic {
    /// The same glyph moved by `delta` page units.
    public func translated(by delta: Point) -> Graphic {
        guard delta != .zero else { return self }
        var copy = self
        copy.bounds = Rect(x: bounds.x + delta.x, y: bounds.y + delta.y,
                           width: bounds.width, height: bounds.height)
        switch content {
        case let .path(path, fill, stroke, style):
            copy.content = .path(path.transformed(by: .translation(delta.x, delta.y)),
                                 fill: fill, stroke: stroke, style: style)
        case .text(var run):
            run.transform = run.transform.then(.translation(delta.x, delta.y))
            copy.content = .text(run)
        }
        return copy
    }
}

/// The engraved glyphs belonging to one notehead, in page coordinates.
///
/// LilyPond draws every note as several independent SVG paths. A provisional
/// preview that invents an ellipse looks nothing like the real thing; moving
/// the notehead (and, where unambiguous, its stem, flags, dot and
/// articulations) preserves the shape the user is about to get.
public struct NoteGlyph: Hashable, Sendable {
    /// The notehead's bounds in page coordinates.
    public var head: Rect
    /// The notehead plus nearby glyphs (stem, flags, dot, articulations).
    /// Never includes ledger lines: those depend on the destination pitch and
    /// are drawn at the provisional position instead.
    public var graphics: [Graphic]
    /// One staff space in page units, used to keep horizontal and vertical
    /// offsets in proportion to the staff.
    public var space: Double

    public init(head: Rect, graphics: [Graphic], space: Double) {
        self.head = head
        self.graphics = graphics
        self.space = space
    }

    public var bounds: Rect {
        guard var r = graphics.first?.bounds else { return head }
        for g in graphics.dropFirst() { r = r.union(g.bounds) }
        return r
    }

    /// The glyph moved by `delta` page units.
    public func translated(by delta: Point) -> NoteGlyph {
        guard delta != .zero else { return self }
        return NoteGlyph(head: Rect(x: head.x + delta.x, y: head.y + delta.y,
                                    width: head.width, height: head.height),
                         graphics: graphics.map { $0.translated(by: delta) },
                         space: space)
    }

    /// The glyph with its notehead centred on `center`.
    public func placingHead(at center: Point) -> NoteGlyph {
        translated(by: Point(center.x - head.midX, center.y - head.midY))
    }
}

extension EngravedPage {
    /// The note glyph at one source position, if the engraving has one.
    public func noteGlyph(at position: SourcePosition, path: String? = nil,
                          among staves: [Staff]? = nil) -> NoteGlyph? {
        let graphics = linkedGraphics(at: position, path: path)
        guard let sample = graphics.first,
              let staff = staff(at: Point(sample.bounds.midX, sample.bounds.midY),
                                among: staves ?? self.staves) else { return nil }
        return Self.noteGlyph(among: graphics, space: staff.space)
    }

    /// Extracts the notehead and its immediate companion glyphs from all the
    /// graphics linked to one event.
    ///
    /// When an event is a chord, only the chosen notehead is returned: its
    /// stem is shared with the other notes, so moving it with one pitch would
    /// misrepresent the chord. Accidentals and ledger lines are also left out;
    /// both depend on the destination, not the source note.
    public static func noteGlyph(among graphics: [Graphic], space: Double) -> NoteGlyph? {
        guard space > 0 else { return nil }
        let heads = graphics.filter { isNotehead($0, space: space) }
        guard let head = heads.min(by: {
            abs($0.bounds.height - space) < abs($1.bounds.height - space)
        }) else { return nil }

        let h = head.bounds
        let singleHead = heads.count == 1
        let selected = graphics.filter { g in
            if g == head { return true }
            guard singleHead, isCompanion(g, head: h, space: space) else { return false }
            return true
        }
        return NoteGlyph(head: h, graphics: selected, space: space)
    }

    /// The glyphs to take out of a page for a provisional deletion.
    ///
    /// LilyPond only puts point-and-click links on some grobs: a stem, flag,
    /// accidental or ledger line is usually unlinked even though it belongs to
    /// the note. Removing only the linked graphics would leave those behind.
    /// This expands a note's linked graphics to the nearby unlinked parts of
    /// the same note, without taking adjacent notes or long beams/slurs.
    public static func removalSet(for linked: [Graphic], among pageGraphics: [Graphic],
                                  space: Double) -> Set<Graphic> {
        var out = Set(linked)
        guard space > 0 else { return out }
        let heads = linked.filter { isNotehead($0, space: space) }
        for head in heads {
            for g in pageGraphics where isAttachedToNote(g, head: head.bounds, space: space) {
                out.insert(g)
            }
        }
        return out
    }

    private static func isAttachedToNote(_ g: Graphic, head h: Rect, space: Double) -> Bool {
        guard case .path = g.content, !isNotehead(g, space: space) else { return false }
        let b = g.bounds
        // A stem, flag, accidental, dot, articulation or ledger line. Long
        // beams and slurs belong to several notes and are left for LilyPond.
        guard b.width <= 3 * space, b.height <= 6 * space else { return false }
        // Stay close to this notehead: adjacent notes on the same staff are
        // usually only a couple of spaces away, and their stems are unlinked
        // too. Accidentals still fall inside this window.
        guard b.midX >= h.midX - 1.7 * space, b.midX <= h.midX + 1.7 * space else { return false }
        guard b.midY >= h.midY - 4.5 * space, b.midY <= h.midY + 4.5 * space else { return false }
        return true
    }

    /// A notehead is roughly one staff space tall and at least as wide, unlike
    /// an accidental (taller), stem (thinner), dot or flag.
    static func isNotehead(_ g: Graphic, space: Double) -> Bool {
        guard case .path = g.content else { return false }
        return g.bounds.height >= 0.7 * space && g.bounds.height <= 1.45 * space
            && g.bounds.width >= 0.9 * space && g.bounds.width <= 3 * space
    }

    private static func isCompanion(_ g: Graphic, head h: Rect, space: Double) -> Bool {
        guard case .path = g.content else { return false }
        let b = g.bounds
        // Never take a spanner (slur, tie, beam) or a page-sized object.
        guard b.width <= 3 * space, b.height <= 6 * space else { return false }
        // Ledger lines and other long horizontal strokes are destination-
        // dependent and can be wider than a stem.
        if b.height < 0.3 * space, b.width > 1.5 * space { return false }
        // Keep glyphs that share the notehead's horizontal neighbourhood. The
        // left limit excludes accidentals, which depend on the new pitch and
        // key; the right limit keeps dots and flags.
        guard b.midX >= h.minX - 0.2 * space, b.midX <= h.maxX + 2 * space else { return false }
        guard b.midY >= h.midY - 4 * space, b.midY <= h.midY + 4 * space else { return false }
        return true
    }
}
