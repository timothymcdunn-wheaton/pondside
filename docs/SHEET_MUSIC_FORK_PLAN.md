# swift-sheet-music Fork Plan: Manual and Feathered Beams

Status: **tabled** (2026-10-28). Slurs did not need a fork; see DESIGN.md,
"Instant Notation Lens".

## Why a fork

The lens renders with `swift-sheet-music` (pinned `4.11.0`), a Swift port of
MuseScore's engraving. It ports beam *drawing* but not beam *grouping
controls*:

- `Chord` has no beam mode (MuseScore's `<BeamMode>`: begin / mid / no /
  begin16 / begin32). Only `beamVisible` exists.
- `TimeSignature` has no beam groups (MuseScore's `Groups`, e.g. 9/8 as
  2+2+3+2).
- `BeamGrouping.groups` (`Sources/SheetMusicCore/Score/BeamGrouping.swift`)
  is purely meter-driven: beat = `4/denominator` quarter, compound x/8 grouped
  by dotted quarter, tuplets as hard breaks. It is `package`-scoped, so it
  cannot be overridden from outside.
- No feathered beams (MuseScore's `growLeft` / `growRight` on `Beam`).
- `4.21.0` (latest) parses `<beam>` in `MusicXMLStemBeam` but uses it only to
  propagate stem direction through a beam, not to group. It also cannot build
  with a standalone toolchain (`#Preview` in `ScoreView+FramesPreview.swift`).

So LilyPond `[ ]`, `\noBeam`, `\autoBeamOff` and feathered beams
(`\featherDurations`, `Beam.grow-direction`) cannot be shown.

## Fork logistics

1. Fork `jiyimeta/swift-sheet-music` at tag `4.11.0` to a branch
   `pondside/4.11-beams`; tag releases `4.11.0-pondside.N`.
2. Point `Package.swift` at the fork with `exact:` the new tag.
3. Keep changes additive and default-off so upstream tests pass unchanged;
   offer them upstream as PRs.
4. Run the fork's own tests (`BeamGroupingTests`, `BeamingTests`,
   `HiddenVoiceBeamTests`, `RasterBeam*`) — needs Xcode or a toolchain with
   XCTest.

## Phase 1 — Manual beam grouping

Model (`SheetMusicCore`):

- `public enum BeamMode { case auto, begin, middle, end, none }` (map
  MuseScore `begin`/`mid`/`no`; `end` is MusicXML's, useful for import).
- `Chord.beamMode: BeamMode = .auto`, included in `ScoreFingerprint`.
- Optional, later: `TimeSignature.beamGroups: [Int]?` (eighths per group).

Grouping (`BeamGrouping.groups`):

- If no chord in the voice has a non-`.auto` mode, behave exactly as today.
- Otherwise walk the voice: `.begin` opens a group (closing any open one),
  `.middle` continues, `.end` closes after this chord, `.none` stands alone
  and closes any open group; `.auto` chords fall back to the meter rule
  within the stretch between manual groups.
- Rests inside an explicit group stay in it (beams over rests); tuplet
  boundaries no longer force a break inside an explicit group.
- Group `level` = max beam level of members, as now.

Import:

- MusicXML: map `<beam number="1">` begin/continue/end to the mode
  (`MusicXMLStemBeam` from 4.21 is a model to copy); notes without `<beam>`
  inside a beamed run → `.middle`; eighths and shorter with no `<beam>` at
  all → `.none` when the document has any `<beam>` (MusicXML beams are
  explicit), else `.auto`.
- MSCX: decode/encode `<BeamMode>` on `Chord`/`Rest`.

Pondside side:

- `MusicXMLLensWriter` already knows `[`/`]`; emit `<beam>` begin/continue/
  end for manual beams and for LilyPond's autobeam result where computable;
  `\noBeam` → no `<beam>`.
- Remove "beams are automatic" from DESIGN.md scope limits.

Tests: grouping with explicit begin/end across beats; beam over a rest;
`.none` inside a run; mixed auto/manual voice; MusicXML round-trip;
untouched output for scores without modes.

## Phase 2 — Feathered beams

Model:

- `public enum BeamGrow { case none, left, right }` or MuseScore's pair
  `growLeft: Double = 1`, `growRight: Double = 1` on the chord that leads a
  beam group (as `beamVisible` already is).

Layout (`SheetMusicLayout`):

- `BeamGeometry.levelOffsetDy` — secondary beams are offset uniformly today.
  For a feathered group, each level's offset becomes a line, not a constant:
  at the narrow end all levels converge on the primary; at the wide end they
  spread by the usual `sp * 0.75` per level. Emit per-level start/end Y.
- `LayoutEngine.computeBeamLine` / `LayoutEngine+Emit` — carry both
  endpoints per level into the `.beam` `LayoutElement`.
- Stems: stem lengths must reach the outermost beam at each chord's x;
  recompute from the per-level line (`LayoutEngine+YBounds`, beam-stem
  adjustment in `LayoutEngine+Placement`).
- `BeamRenderer.draw` (`SheetMusicUI/Rendering`) — draw each level as a
  quadrilateral between its own endpoints instead of a parallel copy.
- Collision/skyline (`LayoutEngine+YBounds`): use the widest extent.

Import: MusicXML `<beam fan="accel|rit">` on the first note of the group;
MSCX `<Beam><growLeft>/<growRight>`.

Pondside side: emit `fan` from `\featherDurations` / `grow-direction`
overrides where the writer can see them; otherwise keep the badge.

Tests: geometry of a 3-level accel and rit group (converging point, spread),
stem lengths, unchanged output when `grow` is default.

## Phase 3 — Engraving rules the lens exposed

Small layout fixes, each default-on only where MuseScore itself does it.

- **Beams reach the middle line.** `LayoutEngine.computeBeamLine` places
  the most extreme end at `defaultStemLength` and stops. When every note of
  a group is on ledger lines (e.g. `b'''16 a''' as''' ges''' f'''` with
  stems down), MuseScore and LilyPond lengthen the stems so the beam
  reaches the middle staff line. Add that clamp after the slant is chosen,
  shifting both ends by the same amount. Tests: a group above and below
  the staff, a group inside it unchanged.
- **Two-chord tremolo heads.** The renderer picks noteheads from the
  sounding duration (`NoteheadGlyph`, `DurationInterpretation.split`), so
  a whole-note tremolo pair, which sounds as two halves, gets half-note
  heads and stems. MuseScore doubles the displayed value of both chords of
  a `TremoloTwoChord` (and drops stems at whole); port that, and place the
  bars between the heads when there are no stems. Tests: whole, half and
  quarter pairs.
- **Written values of tuplet members.** The MusicXML import keeps only
  the scaled duration, and `DurationInterpretation.split` guesses the
  written value back from a table of common ratios (3:2, 5:4, 6:4, 7:4,
  …). Nested or unusual ratios (e.g. a triplet inside a quintuplet) miss
  the table and draw with the wrong head or flag. Keep the written type
  on the chord at import instead of guessing.

Pondside side: none; the lens already attaches tremolos and tuplets.

## Estimate

Phase 1 ≈ a third of the lens session; Phase 2 ≈ half, riskier (beam and
stem geometry); Phase 3 small, mostly tests. Fork overhead is small.
