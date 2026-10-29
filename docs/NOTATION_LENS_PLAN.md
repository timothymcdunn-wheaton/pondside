# Instant Notation Lens Plan

**Status (2026-10-28):** Phases 0–4 implemented; Phase 5 automated checks
done (build, seam, app bundle, lens/command/note-input tests run against a
local XCTest stand-in, offscreen renders of the fixtures). The code lives in
`Sources/PondsideCore/Lens/` rather than `MusicXML/`. Interactive checks in
the running app (Phase 5.2) are still to be done by hand. Implementation
notes and deviations are in `DESIGN.md`, "Instant Notation Lens".

## Decisions

- First lens scope: **active staff only**.
- First lens typography: **Bravura/MuseScore-like**, not LilyPond-identical.
- Full multi-staff systems are deferred until the parser has staff/voice/measure structure.
- Lens content: a local continuous strip around the edit, initially **current measure ±4 measures**. No page breaks.
- `.ly` remains the sole source of truth. The renderer receives a transient in-memory model, never a sidecar score.

## Phase 0 — Toolchain Baseline

1. Install **Swift 6.4.1**, not 6.2:
   - Preferred: `brew install swiftly`, then `swiftly install 6.4.1`, `swiftly use 6.4.1`.
   - Fallback: `brew install swift` and use `/opt/homebrew/opt/swift/bin/swift`.
2. Verify:
   - `swift --version`
   - `swift build`
   - `./scripts/check-seam.sh`
   - `swift build --build-tests`
3. Confirm whether the standalone toolchain provides XCTest. If not, continue with build verification and leave `swift test` to macOS CI.
4. Do not commit or disturb the existing `docs/IDEAS.md` / `docs/IDEAS.pdf` changes.

## Phase 1 — Add Renderer and CI Support

1. In `Package.swift`, under the macOS-only branch:
   - Add exact dependency `swift-sheet-music` `4.11.0`.
   - Add products `SheetMusicMusicXML`, `SheetMusicLayout`, and `SheetMusicUI` to `PondsideUI`.
   - Keep the root tools version at 6.0 and Linux targets unchanged.
2. Update `.github/workflows/ci.yml`:
   - macOS job installs Swift 6.4.1 before building.
   - Linux jobs remain on Swift 6.1 because the package is omitted there.
3. Build once before writing lens code. `4.11.0` is the last release before the `#Preview` macro file; `4.21.0` fails with a standalone toolchain because `PreviewsMacros` is unavailable.

## Phase 2 — Portable Lens Score Builder

Add portable code under `Sources/PondsideCore/MusicXML/`:

1. `LensBlockFinder`
   - Given the selected event offset, find the enclosing assignment body or innermost music sequential.
   - Prefer an assignment body over nested `\tuplet`/`\grace` braces.
   - Support inline `\new Staff` blocks and simultaneous-voice branches.
2. `LensContextScanner`
   - Scan the chosen block for `\clef`, `\time`, `\partial`, `\tuplet`, `\grace`, bar checks, and known post-events.
   - Produce maps keyed by byte range.
   - Flag unsupported constructs such as `\repeat`, `\alternative`, `\transpose`, `\ottava`, tags, Scheme, and Lexicon commands.
3. `LensScoreWindow`
   - Extract the current measure ±4.
   - Build pseudo-measures from explicit bar checks, falling back to meter accumulation.
   - Preserve mapping from every emitted element back to its source event/note.
   - Return `nil` when no music block can be resolved.
4. `MusicXMLLensWriter`
   - Emit MusicXML 4.0 for one part, one staff, one voice.
   - Include divisions, key, time, clef, measures, notes, rests, chords, accidentals, dots, ties, slurs, beams, grace notes, and tuplets.
   - Represent quarter-tone alterations as decimal `<alter>` values.
   - Produce only a UTF-8 `String`; never write it to disk.
5. Add `PondsideCoreTests` for:
   - `invention.ly` upper and lower assignments.
   - A nested tuplet and a chord selection.
   - `quartet.ly` selection isolation.
   - `large-graphic/flute.ly` clef/time extraction.
   - XML contains correct measure count, pitches, durations, and source mapping.

## Phase 3 — macOS 15 Lens UI

Add `Sources/PondsideUI/Lens/`:

1. `NotationLensSession`
   - A macOS-14-available protocol used by `DocumentWindowController`.
   - Hides all macOS 15 and SwiftUI/SheetMusic types behind a guarded implementation.
2. `NotationLensController` (`@available(macOS 15.0, *)`)
   - Full-window `NSVisualEffectView` backdrop with dimming.
   - Backdrop swallows mouse events; the lens window ignores mouse events.
   - Borderless non-activating child `NSPanel`, positioned over the score.
   - White rounded paper strip with a subtle shadow.
   - Small footer: file/staff label, `⎋ close`, and any unsupported-construct badge.
3. `LensScoreHost`
   - `MusicXMLParser.parse(Data(xml.utf8))`.
   - `LayoutEngine.layout` with `wrapToViewWidth: false`, `breakPolicy: .ignoreAll`, `includeTitleFrame: false`, `breakIndicatorVisibility: .none`, `lyricsVisible: false`.
   - Host `ScoreView(document:score:options:selection:)` inside an `NSScrollView`.
   - Use `ScoreSelection.single(ScoreItemID.note(...))` for the cursor note.
   - Scroll so `LayoutDocument.chordStemOrigin(at:)` sits in the center; animate over ~80 ms and cancel prior scroll animations.
4. Failure handling:
   - Import/layout failure dismisses the lens and flashes a status message.
   - Unsupported constructs render the written block once and display a badge; they do not crash or silently lie.
   - Custom graphic commands get a concise “graphic” placeholder badge, not an attempted reimplementation.

## Phase 4 — Controller Integration and Keyboard-Only Editing

1. Add `view.lens` to `Sources/PondsideCore/Commands/Catalog.swift`:
   - Title: “Notation Lens”.
   - Chord `vy`, shortcut `⌘⌥L`.
   - No `.selection` requirement; show a status message if no event can be found.
2. In `DocumentWindowController`:
   - `apply(_:)` opens or refreshes the lens after a successful score edit.
   - `run("view.lens")` presents the lens explicitly.
   - Escape is intercepted before `NoteInput` whenever the lens is open, so it dismisses only the lens.
   - `documentDidEngrave` closes a lens opened by an edit once that edit’s render completes.
   - Track the next render generation so an older in-flight render cannot close the lens prematurely.
   - Close on file switch, window close, and source-pane edits.
3. Remove click-to-add-note:
   - Remove `add.mouse` from the catalog.
   - Remove `canvasWantsMouseEntry` and `clickedStaff` UI paths.
   - Keep mouse selection/highlighting.
   - Keep keyboard duration arming and keyboard note insertion.
   - Keep `MouseEntry` portable code/tests for now unless cleanup is explicitly requested.
4. Update hints and status text so they no longer mention clicking a staff to place notes.

## Phase 5 — Verification and Tuning

1. Build and seam checks:
   - `swift build`
   - `./scripts/check-seam.sh`
   - `swift build --build-tests`
   - `swift test` where XCTest is available
   - `scripts/make-app.sh debug`
2. Manual tests:
   - `Tests/Scores/invention.ly`: edit upper staff; verify lens shows only that assignment.
   - `Tests/Scores/quartet.ly`: verify selection isolation.
   - `Tests/Scores/large-graphic/score.ly`: verify lens opens instantly while LilyPond continues rendering; verify custom graphics show a placeholder.
   - Verify single continuous staff, no page breaks, centered cursor, smooth scrolling.
   - Verify Escape dismisses only the lens.
   - Verify the lens closes automatically when the background render finishes.
   - Verify the page, cross-fade, ghosts, and provisional actions are unchanged.
   - Verify clicking the score selects but never inserts notes.
3. Performance gate:
   - Target under 50 ms from keypress to refreshed lens for the 7–9 measure window.
   - Hard ceiling 100 ms.
   - If exceeded: reduce window to ±2 measures, cache font/layout, then move XML parse/layout off the main actor.
4. Update `docs/DESIGN.md` with the lens architecture, scope limits, toolchain requirement, and fallback behavior.

## Acceptance Criteria

- First note, pitch, duration, dot, delete, or articulation edit opens the lens without waiting for LilyPond.
- Lens shows a local, single-staff, continuous strip with accurate notes/rests/durations.
- Keyboard edits update the lens immediately; mouse cannot edit notes.
- Escape closes only the lens; the next completed render also closes it.
- Page engraving remains authoritative and visually unchanged outside the lens.
- macOS 14 still builds and runs; the lens command reports that macOS 15 is required.
- Unsupported LilyPond constructs degrade gracefully with a visible badge.

## Main Risks

- MusicXML import may mishandle tuplets, microtones, repeats, or custom constructs. Fallback: direct in-memory score construction for supported cases, and page-only fallback for unsupported ones.
- Swift package resolution/build may fail despite Swift 6.4.1. Stop after the Phase 1 build spike before investing in the UI.
- Layout latency may exceed the budget. The local measure window and precomputed `LayoutDocument` are the first mitigations.
- Blur/child-window layering may look wrong on macOS 15.2. Fallback to a dimmed backdrop without blur.
