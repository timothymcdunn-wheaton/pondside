# Pondside — design proposal

Status: **M1 done, M2 in progress.** This document answers the four
questions asked before code (module structure, grammar approach,
`entry.toml`, `cues.json`) and lists the places where I think the brief is
wrong, unachievable, or over-specified. Proposals 1–6 in §5 were accepted on
2026-10-27; the rest are still open.

---

## 1. Module structure

```
                 ┌────────────────────────── portable (Linux CI) ──────────────────────────┐
                 │                                                                          │
 PondsideCore    │  stdlib only — not even Foundation. SourceText (line index, LilyPond     │
                 │  coordinates ↔ String.Index ↔ UTF-16), PointAndClickLocation,            │
                 │  TextDiff (minimal replacement), DiskSync, LilyPondVersion.              │
                 │  M2: lossless CST + parser (Syntax/), pitch/duration model (Music/),     │
                 │  ScoreEditor, NoteInput, EngravingMap (Editing/).                        │
                 │                                                                          │
 PondsideEngrave │  Toolchain detection, LilyPond driver (process today, daemon in M4),     │
                 │  diagnostics parser, SVG → EngravedPage scene model (geometry +          │
                 │  point-and-click links), export leak check, polling FileWatcher.         │
                 │                                                                          │
 PondsideTiming  │  (M8) pure functions: event dump + tempo map → seconds. No I/O.          │
 PondsideLexicon │  (M7) entry.toml parsing, three-tier index, scope resolution.            │
 PondsideBridge  │  (M6) JSON-RPC schema + server, MCP server, OSC encode/decode.           │
 PondsideCLI     │  `pondside` executable. Links only the modules above.                    │
                 └──────────────────────────────────────────────────────────────────────────┘
                 ─────────────────────────────────── seam ─────────────────────────────────────
 PondsideUI      AppKit. Score canvas, editor, panes, palette, hint system. Disposable.
 PondsideApp     Executable target: `main.swift` → PondsideUI.
```

Enforcement, all live as of M1:

- `Package.swift` only declares `PondsideUI`/`PondsideApp` under `#if os(macOS)`,
  so on Linux they don't exist and nothing portable can import them.
- CI's Linux job (`swift:6.1-noble`) builds and tests every portable module.
- `scripts/check-seam.sh` rejects Apple-only imports below the seam, and any
  Foundation import in Core. It runs in CI.

Departures from the brief's diagram, and why:

- **Geometry and the scene model live in Engrave, not UI.** Hit-testing,
  link lookup and bounds are pure, so they're portable and tested on Linux.
  The UI only turns paths into `CGPath` and draws them.
- **The CST lives in Core.** With a pure-Swift parser (§2) there is no C
  build to isolate, so the brief's placement stands.

---

## 2. The concrete syntax tree

### Decision: a hand-written lossless parser, not tree-sitter

The brief asks for a tree-sitter grammar. I built the CST as a pure-Swift
recursive-descent parser instead (`Sources/PondsideCore/Syntax`), because:

- **The hard part would be hand-written anyway.** LilyPond's tokenization
  depends on mode (`\lyricmode`, `\chordmode`, `\markup`, Scheme with
  embedded `#{ #}`), which tree-sitter can only express through a
  hand-written C external scanner.
- **The edit model needs semantics the parser can compute for free.**
  Relative octaves, inherited durations, key and note-name language are all
  resolved by LilyPond *lexically* (verified, §6). A single parser pass
  computes them exactly; a tree-sitter tree would need a second pass doing
  the same walk.
- **The seam stays clean.** No C target, nothing to build per platform, and
  Core still imports nothing but the Swift standard library.
- **Speed is not a reason to prefer tree-sitter at our sizes.** A full
  re-parse of a large score is fast enough to run on every keystroke.
  Incremental reparsing can come later behind the same `SyntaxTree` API if
  profiling ever asks for it.

What tree-sitter would still be good for is highlighting in *other*
editors (Helix, Neovim, Zed). That is worth a separate, optional grammar
later, and it would never be the source of truth for Pondside's edits.

### Design principle: structure without meaning

LilyPond can redefine arity and even lexing from Scheme at runtime, so the
parser:

1. **Never encodes arity.** `\foo a b c` is a command followed by a flat
   sequence of items. The CST is a token stream with bracket structure, not
   an AST.
2. **Models what is lexically fixed:** comments, strings, numbers,
   `\commands`, notes (pitch, octave marks, `!`/`?`, octave check), durations
   (dots, `*n/m`), chords, `<< >>`, `{ }`, post-events, assignments,
   property paths, context specs, and Scheme datums, which are opaque except
   for their extent and any embedded music.
3. **Tracks modes** the way LilyPond's lexer does: pending mode set by
   `\lyricmode` etc., consumed by the next block, with `\markup` handled as an
   inline expression up to its first word, string or block.
4. **Never fails.** Stray closers and unterminated blocks are recovered
   and reported in `SyntaxTree.issues`. Every byte belongs to exactly one
   leaf, so `tree.reconstructed == text` always holds, and the tests assert
   it for every file in the corpus.

The only built-in knowledge is in `KnownCommands`: which bare commands
attach as post-events, which take pitch arguments, which switch modes. All
of it concerns attachment, never meaning. A score that redefines one of
these still round-trips byte for byte.

### How edits use it

Edits never re-print the tree. `ScoreEditor` turns an intention into a list
of `TextEdit`s (byte range → replacement) over the exact characters
involved. Two kinds of compensation keep *other* notes unchanged:

- **Octave marks.** In `\relative` mode, moving a note changes the reference
  for the next note in the chain. The editor rewrites the marks of exactly
  the notes whose reference changed, so their absolute pitch is preserved.
  For example, raising `d` in `\relative c' { c d e f }` gives `c d' e, f`.
- **Inherited durations.** Changing a note's duration would change every
  following note that inherits it. The editor writes the old value on the
  first inheriting note: `{ c'4 d' e' }` → `{ c'4 d'8 e'4 }`.

### The round-trip proof (M2 acceptance)

- **Property tests** (`RoundTripPropertyTests`): 1,000 random graphical
  edits per real-world score (moves, durations, dots, slurs and
  articulations, inserts, deletes), each checked for:
  - **locality:** only the target event, other notes' octave marks, and
    pure insertions at duration slots change;
  - **semantics:** every non-target note keeps its absolute pitch and every
    non-target event keeps its duration;
  - **losslessness;**
  - **reversibility:** the inverse edits restore the original byte for byte.
- **Corpus:** LilyPond's own regression suite and snippet collection
  (~2,300 files), lossless parse plus 20 random edits per file, in CI.
- **Oracle** (`OracleTests`): an event listener compiled into LilyPond
  (`EventDump`) reports every note's absolute pitch and duration. The model
  must agree on every note of every score, before and after random edits.
  With the property tests, that means an edit never changes a non-target
  note *as LilyPond reads it*.

---

## 3. Lexicon `entry.toml` schema

```toml
# entries/breath-cloud/entry.toml
schema   = 1
id       = "breath-cloud"           # stable, kebab-case, unique per scope
version  = "1.2.0"                  # semver; scores record what they used
gloss    = "Widening cloud of stemless noteheads, density rising over a span"  # Tier 0, ≤ 80 chars
tags     = ["texture", "aleatoric", "graphic", "winds"]
kind     = "texture"                # symbol | texture | pattern | gesture | layout | system
lilypond = ">=2.24"                 # LilyPond versions the impl supports
authors  = ["A. Composer"]
license  = "CC-BY-4.0"

[entry]                             # how it's invoked
command  = "\\lexicon \"breath-cloud\""
attaches = "span"                   # point | span | staff | system — what it binds to
music-arg = true                    # takes the music it decorates as an argument

[params.density]                    # Tier 0 shows names; Tier 1 shows everything
type    = "float"                   # float | int | bool | string | enum | duration | pitch | markup
default = 0.6
min     = 0.0
max     = 1.0
doc     = "Fraction of the span filled with noteheads at the widest point"

[params.span]
type    = "int"
default = 4
min     = 1
unit    = "measures"
doc     = "Length of the cloud"

[params.label]
type    = "markup"
default = ""
doc     = "Text in the dashed box, e.g. a duration like ca. 8″"

[params.shape]
type    = "enum"
values  = ["widen", "narrow", "steady"]
default = "widen"

[sound]                             # optional: the sonic realisation
synthdef = "granularCloud"          # name the patch must provide
cue      = "breathCloud"            # cue name emitted at the entry's start
# Expressions over params and timing. Allowed: + - * /, min, max, and the
# bound names: params by name, beatDur (seconds), spanDur (seconds of the
# attached span), tempo (bpm at onset).
params   = { density = "density", dur = "spanDur", amp = "0.2 + 0.6 * density" }
emit     = "onset"                  # onset | onset+release | every:<duration>

[preview]
file     = "preview.svg"            # rendered by `pondside lexicon render`
source   = "examples/preview.ly"

[files]
impl     = "impl.ily"               # Tier 2
readme   = "README.md"              # Tier 1 prose: when to use, pitfalls
```

Rules:

- **Tiers come from the file, not from discipline.** Tier 0 = `id`, `gloss`,
  `tags`, param names. Tier 1 = the whole `entry.toml` plus `README.md`.
  Tier 2 = `impl.ily`. `index.json` is generated: Tier 0 only, one line per
  entry, sorted by id, so it's diffable and about 20 tokens per entry.
- **Scope resolution:** `core` → `user` → `project`. A later scope overrides
  by `id`. A score records `id@version@scope` in a generated
  `\pondsideLexiconLock` comment block, so old scores resolve the version
  they were engraved with.
- **Sound expressions are a tiny, total language.** No loops, no calls
  except `min`/`max`. They're evaluated in `PondsideTiming`, so tempo changes
  re-derive both score and cues.
- MCP resources: `lexicon://index` (Tier 0), `lexicon://entry/{id}` (Tier 1),
  `lexicon://impl/{id}` (Tier 2).

---

## 4. `cues.json` schema

```jsonc
{
  "schema": 1,
  "score": "piece.ly",
  "scoreHash": "9f2c…",                 // content hash of the source compiled
  "lilypond": "2.26.0",
  "sampleRate": 48000,                  // from pondside.toml; the quark asserts it
  "mockup": { "file": "build/mockup.wav", "hash": "…", "offsetSamples": 0 },
  "timeline": {
    // The tempo map exactly as derived, so SC (or anyone) can re-check.
    "segments": [
      { "from": "1:1", "seconds": 0.0,   "bpm": 72, "beatUnit": "1/4" },
      { "from": "17:1", "seconds": 53.33, "bpm": 72, "toBpm": 96, "beatUnit": "1/4", "curve": "linear-in-tempo" },
      { "from": "24:3", "seconds": 71.9,  "hold": 4.0, "reason": "fermata" },
      { "from": "25:1", "seconds": 75.9,  "unmetered": true, "duration": 30.0 }
    ]
  },
  "cues": [
    {
      "id": "c-0007",                   // stable across edits: hash of name + source anchor
      "name": "fxSwell",
      "index": 7,                       // order in the score
      "position": { "measure": 42, "beat": 1, "moment": "167/4" },  // moment = whole notes, exact rational
      "seconds": 133.333333,
      "samples": 6400000,               // round(seconds * sampleRate); what SC schedules against
      "duration": { "seconds": 4.0, "moment": "1/1" },   // optional
      "params": { "gain": 0.5, "target": "lowStrings" },
      "source": { "file": "piece.ly", "line": 212, "character": 14 },
      "origin": "explicit",             // explicit | lexicon:<id>@<version>
      "handler": "fxSwell"              // the handler key in the generated .scd
    }
  ]
}
```

Notes:

- **Rational moments are canonical, seconds are derived.** Both are shipped so
  consumers never re-implement the tempo map. `samples` is included because
  "SC owns the clock" really means SC owns the *sample* clock.
- **Measure:beat is for humans.** Partial measures, pickups and cadenzas make
  it ambiguous. `moment` is unambiguous.
- `id` is stable across unrelated edits, so the `.scd` handler sync can tell
  *moved* cues from *new* ones.

---

## 5. Where I think the brief is wrong, unachievable, or over-specified

Ordered by consequence. **1–6 accepted** (2026-10-27), with #3 left open to
creative solutions.

1. **LilyPond has no MusicXML export.** The mockup path "export MusicXML
   from LilyPond, invoke `mscore`" doesn't exist. `musicxml2ly` only imports,
   and python-ly's exporter is partial. **(proposed)** Mockups go through
   LilyPond's own **MIDI** output (with `articulate.ly` for articulations),
   which MuseScore can render with Muse Sounds. MusicXML export stays
   best-effort through python-ly and is labelled that way. `pondside export
   --format musicxml` must not promise more than it can deliver.

2. **Leader chords conflict with letter-name note entry, and law 3 forbids
   modes.** In the score view, `a`–`g` are pitches, so `a s` / `g c` can't
   be leaders there without a mode. **(proposed)** Use **Space as the leader**
   (Helix/Spacemacs idiom): `␣ g c`, `␣ l i`. And recognise that the most
   frequent notation actions *already have* two-keystroke bindings, namely
   LilyPond's own syntax: `(` slur, `~` tie, `\f` dynamic, `-.` staccato.
   Typing LilyPond into the score view is the fast path, and the chords
   cover navigation and commands. Two keystrokes holds for the hot path;
   chords are three with a big key.

3. **Sub-100 ms *compiled* feedback isn't achievable in general.** LilyPond
   line-breaks and page-breaks globally, and even a warm process spends
   100–400 ms laying out a page. A "windowed compile of the affected
   `\score`" can still reflow everything. **(proposed)** Hit the target as
   *perceived* latency: on a pitch or duration edit, the canvas immediately
   draws a **provisional glyph** at the predicted staff position (we have
   exact staff-line geometry from the last SVG), then cross-fades to the real
   engraving when it lands. The daemon (M4) is a Guile server loop inside
   one long-lived `lilypond` process. It's feasible but unofficial, so I'll
   publish the numbers honestly.

4. **"Metal-backed canvas" is the wrong first move.** The score is vector
   paths and text. Metal would mean writing a GPU path rasteriser with
   analytic antialiasing and glyph rendering, which is months of work.
   Core Graphics into Core Animation layers is already GPU-composited, and
   with per-page layers plus cached page bitmaps it scrolls at display rate.
   **(proposed)** CG/CA now. Revisit Metal only if profiling shows a
   bottleneck, which I don't expect.

5. **Automatic git commits must not touch the user's repository.**
   Committing every few seconds into their history would be hostile.
   **(proposed)** A shadow repository in `.pondside/history` (separate
   `GIT_DIR`, worktree = project) holds checkpoints. Their own repo is never
   written. Add `.pondside/` to a generated `.gitignore` entry, with consent.

6. **Autosave every 250 ms races with external editors.** Agents and editors
   write the same file. M1 handles this with content-hash ownership, atomic
   writes, minimal-diff merges and a conflict sheet that saves the losing
   side to a recovery folder. The remaining hole is a sub-second
   simultaneous write, which nobody can fully close without locking, and
   locking would break the "any tool can edit" promise.

7. **`\cue` is a poor name.** LilyPond already has "cue notes"
   (`\cueDuring`, `\cueClef`, …), and `#:params` keyword syntax is awkward to
   type. **(proposed)** `\ecue fxSwell #'((gain . 0.5))`, with
   `\ecueSpan <duration> name params` for cues with a duration. And the
   timing engine must **not** parse tempo from the CST. A small Scheme
   listener included at compile time dumps every tempo, fermata, `\ecue` and
   moment as JSON, so the interpreter is the source of truth.
   `PondsideTiming` is pure functions over that dump. Same reasoning as the
   static-analysis warning.

8. **Shortcut collisions with macOS conventions.** `⌘⇧S` is Save As /
   Duplicate. `⌃1…⌃9` are Mission Control's "Switch to Desktop N" when
   enabled. `⌘/` is "toggle comment" in every code editor. **(proposed)**
   Workspace save `⌘⌥S`. Pane jumps `⌃1…⌃9`, with a one-time warning if
   Mission Control owns them. `⌘/` is the context overlay in the score and
   comment-toggle in code panes, where `⌃/` opens the overlay.

9. **Hold-`⌥` reveal vs. `⌥` as a typing modifier.** It has to arm on a
   *bare* `⌥` held 500 ms with no other key, and cancel on any keystroke,
   or composers typing `⌥e` accents will flash hints. That's doable; noting
   it as an acceptance criterion.

10. **Canvas text fonts.** LilyPond's SVG names fonts (`serif` → C059). If
    they aren't installed on the Mac, canvas text is drawn in a metric
    relative and won't match the PDF exactly. Music glyphs are paths and
    are always exact. **(proposed)** M4 or M5 compiles the canvas with
    `-dsvg-woff` or ships the URW fonts, so the canvas and PDF match.

11. **Installing to `/usr/local/bin`** needs admin rights on Apple Silicon,
    and that directory may not exist. **(proposed)** Offer
    `~/.local/bin`, `/opt/homebrew/bin` if writable, or `/usr/local/bin`
    via an authorization prompt, and show the exact symlink.

12. **Licensing should be decided now.** LilyPond is GPL-3. Invoking it as a
    separate process is fine for any license. Bundling `sclang-lsp`
    (GPL-3.0-or-later) is "mere aggregation" if it runs as its own process,
    but shipping a bundled GPL binary obliges us to offer its source. I
    couldn't verify `sclang-lsp`'s maturity from here, so treat it as a
    candidate.

13. **Muse Sounds from the CLI** requires MuseHub-installed libraries and has
    the documented silent-render problem. The silence detector and the
    fluidsynth fallback are mandatory, not optional.

14. **Over-specified:** the exact 4% gradient budget, Bravura vs. Leland,
    and the `⌘1…⌘5` layout presets. Fine as defaults, but they shouldn't be
    acceptance criteria before M3 shows real screens.

15. **Glass on macOS 14 vs. 26.** macOS 26's Liquid Glass changes what
    "native translucency" means. With a macOS 14 floor, floating chrome uses
    `NSVisualEffectView` on 14/15 and the system glass material on 26+.
    That's one code path per OS behind a single `Chrome.floatingMaterial`.

---

## 6. Facts established empirically (LilyPond 2.24.3)

These are pinned in tests so a LilyPond upgrade that changes them fails loudly:

- Point-and-click URIs are `textedit://PATH:LINE:CHAR:COLUMN`. `LINE` is
  1-based. `CHAR` is a **0-based offset in Unicode scalars**, not bytes:
  `{ c'4^"ééé" d'4 }` puts `d` at 12. `COLUMN` is 1-based and tab-expanded.
- Diagnostics are `FILE:LINE:COLUMN: error: MSG`, where `COLUMN` is a
  **1-based display column with tabs at 8**, followed by two lines quoting
  the source split at the error.
- The canvas SVG uses `<path>`, `<rect ry>`, `<line>`, `<polygon>`,
  `<circle>`, `<ellipse>`, `<text><tspan>`. Colours are written as
  `rgb(100.0000%, …)` on `<g color>` with `fill="currentColor"`. Glyph
  paths use `scale(0.004, -0.004)`.
- Point-and-click is on by default. Export passes `-dno-point-and-click`
  explicitly and then scans the output.

Music semantics, measured with the `EventDump` listener (and encoded in
`SemanticsTests`):

- **The `\relative` chain is purely lexical.** It runs across `<< >>` voices
  (the second voice continues from the end of the first, and the note after
  `>>` from the end of the last voice) and across `\repeat` alternatives.
- **Chords:** members chain from one another, and the next event is relative
  to the chord's **first** note.
- **Isolation:** nested `\relative`, `\fixed` and `\absolute` are isolated;
  the outer chain resumes as if they weren't there.
- **`\transpose`'s pitch arguments** are written in absolute octaves but
  become the chain's reference. `\key` and `\transposition` arguments do not.
- **Octave checks** (`c=''`) pin the pitch to the checked octave, and the
  chain continues from there.
- **`\relative` with no start pitch** behaves as if relative to the F below
  middle C, so the first note reads as absolute.
- **The default duration is lexically global** (across blocks and lines)
  and **includes multipliers**: `c'4*2 d'` gives `d'` a length of `4*2`.
  Tuplets scale the sounding length but not the inherited written value.
- **Whitespace between a pitch and its duration is allowed:** `d' 8` is `d'8`.
- **A bare duration repeats the previous pitch:** `f'1~ 2`, `g'16 4`, and
  `\breve` likewise. This applies in music position: after an event or bar
  check, or at the start of a block. After a chord it repeats the whole
  chord, like `q`. With no previous pitch (RhythmicStaff) it is a pitchless
  note.

---

## 7. Status

### M1

| M1 item | State |
|---|---|
| Open `.ly`, render SVG via detected LilyPond | ✅ `ToolchainDetector`, `LilyPondEngraver`, `EngravedPage` |
| Dark canvas, true-colour paper, never recoloured | ✅ `ScoreCanvasView` / `PageView`; highlights are overlays; lights-out is a dim filter |
| Text/score split | ✅ `DocumentWindowController` |
| Point-and-click score → source | ✅ hit-test (smallest box wins) → token select |
| Point-and-click source → score | ✅ caret/selection → linked positions → highlight + scroll |
| Range selection both ways | ✅ drag rectangle ↔ text selection |
| File watcher, hot reload, caret preserved | ✅ polling watcher, content-hash ownership, minimal-diff merge |
| Never lose work | ✅ 250 ms atomic autosave, conflict sheet + recovery files |
| PDF export with paths stripped | ✅ `-dno-point-and-click` + leak scan (brought forward from M5) |
| Portability seam, Linux CI | ✅ |
| `pondside` CLI: `render`, `check`, `links`, `doctor`, `watch` | ✅ (subset of M6, because CI needed it anyway) |

Not in M1, on purpose: the CST (M2), the chord system and hover popovers
(M3; M1 shows key equivalents in menus and the status line), and the
daemon (M4).

### M2

| M2 item | State |
|---|---|
| CST (lossless, mode-aware, error-recovering) | ✅ `SyntaxTree`, `Parser`, `Lexer` |
| Music model: absolute pitches, durations, keys, languages | ✅ computed in the parse; oracle-verified |
| Score selection model | ✅ the text selection is the selection; chord members selectable alone |
| Minimal-diff edits with compensation | ✅ `ScoreEditor` |
| 1,000-edit round-trip proof on real scores | ✅ fixtures in `Tests/Scores`; LilyPond corpus in CI |
| Keyboard note input | ✅ `NoteInput`: LilyPond durations and syntax as keys |
| Unified undo across both views | ✅ score edits are text edits on the window's undo stack |
| Mouse entry (click a staff position with a duration armed) | ⏳ needs staff-geometry hit-testing; next |

M2 test results (Linux CI): 84 tests, all passing.

- **Corpus:** 2,423 files from LilyPond's regression suite, snippets and
  init files; 29,673 notes; 40,357 random edits. Every file is lossless.
  Two files (0.1%) need syntax recovery, both deliberately exotic
  Scheme-generated music. Every edit satisfies locality, semantics and
  reversibility.
- **Fixtures:** 1,000 edits per score, all invariants holding.
- **Oracle:** the model agrees with LilyPond on every note of every fixture,
  before and after random edits.

What the corpus taught the edit model, beyond the plan:

- **Separators:** inserted and removed text must not fuse tokens
  (`e(d` → `e( g d`, `c4~8` → `c4 8`).
- **Bare durations downstream** of an insert or delete are written out
  (`f'1~ g f'2`, `q` after chords), so they keep sounding the same pitch.
- **A chord that a later `q` repeats** is copied into that `q` when the
  chord is deleted. In `\relative` the delete is refused, because a
  written-out chord would join the octave chain.
- **Refused edits:** deleting the sole operand of `\relative c' c1`, and
  inserting a pitch before pitchless rhythm. Neither can be made
  meaning-preserving in writing, so the editor declines rather than
  guessing.

### M2.1 — real multi-file scores (from first real-world use)

**Do this before mouse entry.** On the first real piece opened in the app,
score editing did nothing. Clicking a note drew no highlight, and `a`–`g`
inserted nothing. The piece is a flute score migrated from Dorico with
musicxml2ly, and its `score.ly` only `\include`s the parts that hold
content: definitions, the flute music, graphics, electronics and timing.
There were two causes:

1. **`\pointAndClickOff` in an included file.** musicxml2ly writes it at
   the top of its output. LilyPond then emits no `textedit://` links for
   that music, the hit-test finds nothing, and `canvas(_:didClick:)`
   silently clears the selection.
2. **Only the opened file is editable.** Even with links, a glyph from
   `flute.ly` only flashes "That object comes from flute.ly:N". The opened
   file holds no notes, so there is nothing to edit.

#### A. Neutralize `\pointAndClickOff` at compile time

| Option | Verdict |
|---|---|
| Comment the line out while the file is open, and restore it on close | ✗ Mutates the user's file. A crash or force-quit leaves it changed, and autosave, the watcher, git and other tools all see the edit. It breaks "the file is the only state". |
| Edit a temp copy, merge back on save, skip the comment-out | ✗ Relative `\include`s and the links' embedded paths point at the copy, so every link needs remapping. It adds a second merge path, and the special exception will rot. |
| **Override it in an injected settings file** | ✓ No file is touched and nothing can be left behind. Links carry the real paths. |

Do what `EventDump` already does (`-dinclude-settings`, see
`Sources/PondsideEngrave/EventDump.swift`) in `LilyPondEngraver` for
**interactive SVG compiles only**. The injected `pondside-session.ily`
redefines `pointAndClickOff` as a no-op and makes `pointAndClickTypes`
permissive. PDF export keeps `-dno-point-and-click` and the leak scan,
unchanged.

- **Spike first** (2.24 and 2.26): does a definition in an
  `include-settings` file shadow `\pointAndClickOff` for music in the
  user's included files? If not, the settings file should wrap
  `ly:set-option` so that it ignores `'point-and-click #f`. That also
  catches a raw `#(ly:set-option 'point-and-click #f)`.
- **Test:** an integration fixture whose included music file starts with
  `\pointAndClickOff`. Assert that its graphics are linked.

#### B. Diagnose, never fail silently

- After a compile, if a file contributed notes but no links, say so in
  the status line and name the file.
- A click on unlinked music should explain itself, not silently deselect.

#### C. Edit across `\include`

- **The root:** the opened file stays the engraved root.
- **The include graph:** resolve `\include` strings with LilyPond's rules
  (relative includes, `-I`, the root's directory). Cross-check against the
  links, which already carry every glyph's real path.
- **Following a click:** clicking a glyph from another file switches the
  source pane to that file (tabs or a file picker). Note input,
  `ScoreEditor`, undo, autosave and the external-merge watcher then all
  work on that file's text and `SyntaxTree`. The source → score highlight
  works from any file in the graph.
- **Recompiling:** every file in the graph is watched. A change to any of
  them recompiles the root.
- **Data model:** generalize `ScoreDocument`, `EngravingMap` and
  `linkOffsets` from one path to per-file state keyed by the canonical
  path. `PathMatching` already handles symlinks.
- **Undo:** one stack per file, as in text editors. A score edit lands on
  the stack of the file it changed.
- **Acceptance:** a multi-file fixture in `Tests/Scores`:
  - The files: a root, a `defs.ily`, a music file that starts with
    `\pointAndClickOff`, and a file of Scheme and markup only.
  - Clicking a note in the included music file selects it, `c` inserts
    into that file, `⌘Z` undoes, and the root re-engraves.
  - The opened root file is untouched throughout.

#### D. README

The README's "Status: M1" section is stale. Describe score-view editing,
the key table from `NoteInput`, and the fact that included files are
editable.

**Order:** A and B first. They are small and immediately restore
highlighting on real scores. C comes next, and mouse entry after it.

#### M2.1 — what was built, and where it departs from the plan

- **A.** The spike showed that redefining `pointAndClickOff` in the
  settings file does **not** reach music in the user's files (observed;
  the mechanism wasn't investigated). So `pondside-session.ily` wraps
  `ly:set-option` and ignores any `'point-and-click` value other than
  `#t`. That neutralizes `\pointAndClickOff`, `\pointAndClickTypes` and
  raw `ly:set-option` calls. Verified on 2.24.3 only; 2.26 still needs a
  check, which `MultiFileTests` will do once CI has 2.26.
- **B.** As planned: the status line names files that have notes but no
  links, and a click on unlinked music explains itself.
- **C.** `SourceGraph` (PondsideEngrave) resolves includes from the
  includer's directory, then the root's directory, then `-I`. It parses
  each file with the language left in effect by earlier includes, and
  iterates to a fixed point because an include's result can depend on the
  language it is entered with. `ScoreDocument` holds one `SourceFile` per
  graph file (text, tree, undo, autosave, watcher, snapshot, diagnostics,
  links). The source pane shows one file at a time: a file bar, plus
  ⌘⇧] / ⌘⇧[. A drag selection edits the file most of its links come
  from.
- **Known limit:** the default duration does not carry across
  `\include` boundaries. Music in an include that starts with a bare
  note inherits LilyPond's duration from the includer, but Pondside
  assumes a quarter. This is rare, because parts start with explicit
  durations. The oracle tests will show it if it matters.

### Mouse entry

- **Staves come from geometry.** LilyPond's SVG has no staff objects, so
  `EngravedPage.staves` looks for five horizontal strokes of the same
  length with even spacing.
- **The clef is never parsed.** The pitch of the nearest notehead on the
  same staff calibrates the click: `diatonic = pitch(anchor) −
  position(anchor) + position(click)`. That handles every clef,
  transposing clefs and `\ottava` without a model of any of them. The
  catch is that a staff needs one note before mouse entry works on it.
  Pondside says so instead of guessing a treble clef.
- **The interaction.** Mouse entry is not a mode: it is on while a
  duration is armed (type `8` with nothing selected), and the status line
  shows that. A ghost notehead, with ledger lines, previews the
  placement. Click to insert after whatever stands to the left; that
  works in any file of the graph. ⎋ with nothing selected disarms. The
  accidental comes from the key, as in keyboard entry, and `⌥↑↓` fixes
  it afterwards.
- **Not yet:** adding to a chord by clicking at an existing note's x;
  inserting before a staff's first note; tab and percussion staves
  (fewer than five lines).

### M3 — the interface

**Built**

- **The catalog** (`PondsideCore/Commands`) is the single list of
  commands. Each entry has a title, a one-line gloss, a requirement
  (selection, errors, several files) and its keys. Menus, the palette,
  hover tips, the ⌥ reveal, the hint bar and the context overlay all
  read it, so they can't disagree. `KeyboardAuditTests` is the "full
  keyboard coverage audit". It fails if any command lacks a chord,
  shortcut or direct key, or if chords collide, shadow each other, or run
  past three keys after the leader. It runs on Linux.
- **The leader.** Space in the score, ⌥Space anywhere. Departure from the
  brief: Helix-style chords can't start with a bare letter here, because
  `a`–`g` enter notes. ⌃Space was the first choice for the source pane,
  but macOS reserves it for switching input sources. Groups: `f` file,
  `g` go, `a` add, `e` edit, `v` view, `p` pane, `w` workspace, `h`
  help. `␣ ␣` opens the palette and `␣ ?` the context overlay. Lexicon
  chords (`l i`, `l p`, `l b`) arrive with M7, and `g m` / `g c` with the
  timing work in M8, since they need measures and cues.
- **Remapping.** `keymap.txt` holds lines of `command = chords` (or
  `none`). A file that breaks the audit is ignored as a whole, so a typo
  can never cost the user their keyboard. Vim and Emacs presets are
  still to do: they are remap files, and they need the editor work in
  M5 to be meaningful.
- **The palette** ranks by fuzzy match: word starts and runs score best,
  and a chord's letters typed as a query find their command. Then come
  availability in context and recency. File, dynamic and workspace
  pickers use the same panel.
- **Panes.** `PaneLayout` keeps content unique across panes, and cycling
  or jumping never changes geometry. Content that doesn't exist yet
  (SuperCollider, Python, agent, cues, Lexicon, OSC) shows a placeholder
  naming its milestone. Cycling skips those.
- **Terminal.** SwiftTerm, macOS only. It is the first external package,
  added only inside the macOS block of `Package.swift`, so the portable
  build has no dependencies. Pinned to 1.5.x: later versions pull in
  swift-subprocess.
- **New score operations:** `toggleSpan` (slur, beam and hairpin from the
  first selected note to the last) and `wrapTuplet`. `wrapTuplet` refuses
  selections that cross `{ }` or `<< >>`, or that hold a scope operand.

**Not yet**

- Hover tips and the ⌥ reveal only cover the file menu and the status
  line, because those are the only controls the window has. New controls
  must call `HelpOverlay.register`.
- The UI half of M3 has not been compiled; see the README status.

### M8 (first part) — the timing engine

**Plan change: seconds are the MIDI's seconds.** The cues.json sketch in
§4 had tempo ramps, holds and unmetered segments. The composer's working
setup (the lilypond-supercollider workflow: `timing.ily`, `playback.ily`,
`lily_timing.py`) shows a better rule. The mockup is rendered from
LilyPond's MIDI, and the MIDI only knows tempo steps. A fermata, a
caesura or a timed section is therefore a hidden `\playTempo` step,
and a ritardando is a run of steps. A timing model with ramps would
disagree with the audio it is meant to sync. So:

- `TempoMap` is stepped, defaulting to 60 quarters a minute as the MIDI
  does. A tempo at moment *m* applies from *m*. When two different
  tempos land on one moment, Pondside warns: that is the "never put a
  `\playTempo` where a printed `\tempo` is" rule.
- `TimingDump` (PondsideEngrave) installs an engraver through
  `-dinclude-settings`. It writes timing.ily's rows (`tempo`, `text`
  with `cue N` from `\ecue`'s `cue-label` and marks from `timing-label`,
  `note`, `group`), plus the position in the bar and `meter` rows, so
  each cue gets a measure:beat. `TimingLog` reads both formats, so an
  existing `score.timing` works too.
- `CueSheet` is cues.json. Per cue it holds the exact moment, measure,
  beat, seconds, samples at the project rate, a stable id (name plus
  occurrence) and an SC handler name. It also carries the tempo steps,
  the other marks (`improv 1`, `end`), the duration and warnings. Its
  `cuesText` is byte-for-byte the `piece.cues` format, so the existing
  `~scoreSync` loader can read Pondside's output.
- CLI: `pondside cues score.ly [--format json|cues] [--rate 48000]` and
  `pondside timeline score.ly`.

**Next in M8:** the `.scd` handler sync (add stubs, comment out orphans,
never touch a handler body), the sample-rate guard in the quark, the
Cue Inspector pane, and the mockup render through MuseScore with silence
detection.

**Known limit:** a file with several `\score` blocks that have layouts
restarts moments in each one. The dump should be pointed at the score
the MIDI comes from.

### M7 — the Lexicon (first part)

**Built**

- `PondsideLexicon` (portable):
  - A TOML-subset reader: tables, dotted and quoted keys, all string
    forms, numbers, booleans, multi-line arrays, inline tables.
  - `LexiconEntry`: validation that reports every problem at once, so an
    agent fixes an entry in one pass. Params keep their file order.
  - The sound-expression language: `+ - * /`, parentheses, `min`/`max`,
    nothing else. Its names are checked against the entry's params and
    `beatDur`/`spanDur`/`tempo` when the entry loads.
  - Scoped loading: core is bundled, user is
    `~/Library/Application Support/Pondside/Lexicon` (or
    `$XDG_DATA_HOME`, or `$PONDSIDE_LEXICON`), project is `Lexicon/`
    beside the score. Later scopes win, and shadowed and broken entries
    are reported.
  - The tiers: `index.json` is tier 0, one line per entry; tier 1 is
    entry.toml plus the README; tier 2 is impl.ily.
- **Invocation.** `\lexicon "id" #'((param . value) …) music` comes from a
  generated include file (`pondside lexicon include score.ly`). It holds
  a dispatcher, each entry's defaults merged under the given params, the
  implementations (each calls `pondside-lexicon-register!`), and, for
  entries with a `[sound]`, a hidden `cue-label` text at the start. The
  timing dump therefore sees the cue like any `\ecue`, and the sound
  binding's cue lands in cues.json with no extra machinery.
- **Static checking.** `pondside lexicon check score.ly` reports unknown
  entries (with near matches), unknown params and out-of-range values,
  by line, before LilyPond runs.
- **Core entries:** `niente-hairpin`, `timed-fermata` (the hidden-tempo
  hold, packaged), `air-tone` (with a sound binding) and
  `feathered-beam`. All of them compile on 2.24.3, and the timing of
  `timed-fermata` plus the `air-tone` cue was checked against a real
  dump.

**Not yet:** the browser pane, promotion, preview rendering, MCP
resources (they come with M6), `\pondsideLexiconLock`, and evaluating
sound params into cues.json (`soundParams` exists; the cue sheet needs the
span length from the dump).

### M4 — speed (first part): the warm daemon

**Measured first** (LilyPond 2.24.3, CI-class Linux container): a
two-bar score takes 3.3–3.6 s cold, and 2.9 s of that is startup (Guile
and the init files). The daemon removes the startup cost from every
compile after the first.

**How:** LilyPond already compiles a list of files in one process,
resetting its session between them (`lilypond-all`). `LilyPondDaemon`
starts `lilypond -e <expr> placeholder.ly`. The expression loads a small
loop into the `(lily)` module: it initialises the session once
(`declarations-init.ly` may only be parsed once per process), then for
each `<source>\t<settings>` line on stdin runs the per-file half of
`lilypond-all`: parse, check expected warnings, `session-terminate`,
restore options, reset fonts. A marker line on stderr ends each job.
Nothing in LilyPond is patched, and no private API is called outside
the `(lily)` module's own procedures.

- **Same output as cold.** The working directory is the score's folder
  (Scheme `load` resolves there). Output goes to the job's folder through
  `\paper { output-filename = … }` in the job's settings file, which also
  carries the point-and-click session settings. Those settings are now
  idempotent, because they are read once per job in one process.
- **Robust.** A score's stdout is merged into stderr, so its output stays
  with its job. A dead process, a stuck job (120 s) or any daemon error
  falls back to a cold compile, and the daemon restarts on the next
  compile and every 150 jobs. Export never uses the daemon.
- **Results:** warm compiles of the test scores take 0.17–0.38 s here,
  against 3.3–3.5 s cold, a 10–20× speed-up. CI prints
  `Pondside benchmark:` for the multi-file fixture on every run. The
  first CI run gave 1502 ms cold and a median of 166 ms warm, 9× (GitHub
  Linux runner, LilyPond 2.24.3).

**Still to do in M4:** content-addressed caching of rendered pages and
the windowed preview compile of the edited `\score` (only where a file
has several). With a warm compile at a few hundred milliseconds on slow
hardware, the windowed compile matters less than the brief assumed.
Provisional rendering is what still separates "fast" from "instant".

### M8 (second part): the Cue Inspector and the mockup render

- **Cue Inspector:** a pane (`⌃8`, or `␣ p u`) listing every cue with
  bar, beat, time and handler. Columns sort; ↩ jumps to the `\ecue`. Cues
  with no `p.on(\name, …)` in the `.scd` files beside the score are
  flagged. `␣ g c` is the brief's "go to cue". The data comes free:
  every canvas compile carries the timing listener.
- **Mockup, plan change:** LilyPond has no MusicXML export, so the
  "export MusicXML, then MuseScore" path in the brief doesn't exist
  without a converter. The composer's working path does exist: render
  LilyPond's own MIDI with MuseScore 4 (`mscore -o piece.wav
  piece.midi`). The MIDI is also exactly what the cue times follow.
  `pondside mockup` compiles the MIDI, tries MuseScore, then fluidsynth
  with a SoundFont. Every result is measured (`WAVInfo`: rate, length,
  peak, RMS). A silent file or a wrong sample rate is refused with the
  reason and the alternatives. Renders are cached by the MIDI's content
  hash plus renderer and rate.
- **Not yet:** per-staff stems for muting live parts, padding the render
  to the `end` mark, and in-app audition (AVAudioEngine).

### M6 — programmability

- **CLI:** `check`, `render`, `cues`, `timeline`, `handlers`, `mockup`,
  `lexicon …`, `links`, `doctor`, `watch`, `rpc`, `mcp` and
  `completion zsh|bash`. It links only portable modules.
- **MCP** (`pondside mcp`, stdio): tools `check`, `query`, `render`,
  `cues` and `lexicon_check`; the Lexicon tiers are resources. No vendor
  is hardcoded. docs/API.md shows setup for Claude Code, opencode and any
  other client.
- **JSON-RPC socket** for the running app: document state, selection,
  select, engrave, cues and open, plus `score.changed`,
  `compile.finished` and `selection.changed` events. The server core is
  portable and tested over real sockets on Linux.
- **`pondside.toml`:** the LilyPond version pin, sample rate, renderer,
  SoundFont and SuperCollider paths. The CLI and the app read it.
- **Not yet:** the agent pane (today the terminal pane runs any agent,
  and that agent reaches Pondside through MCP), `pondside insert` and
  `query --measures`, OSC.

### M9 — graphic notation (groundwork)

The contemporary primitives arrive as Lexicon entries, so each comes with
a chord-free invocation, typed params, a README with pitfalls, and
timing that the cue engine understands:

- Done: `feathered-beam`, `niente-hairpin`, `air-tone` (with a sound),
  `timed-fermata`, `senza-misura` (unmetered, with a decided length) and
  `proportional`.
- To do: box notation with repeat-until-cue, aleatoric boxes, squiggle
  lines, pitch bands, graphic inclusion anchored to time, microtonal
  accidentals, and annotation layers. The composer's own
  contemporary-notation library is the obvious source for several of
  these, as project or user Lexicon entries.
- Natural-language authoring needs the agent surface. The Lexicon tiers
  over MCP are the part that makes it cheap; the authoring loop itself is
  not built.

## 8. Where things stand

| Milestone | State |
|---|---|
| M1 the loop | done |
| M2 editing | done; round-trip proven on the 2.24.3 corpus (2,423 files, 40k edits) |
| M2.1 multi-file scores | done |
| Mouse entry | done; not yet tried by hand |
| M3 interface | catalog, chords, palette, hints, ⌥ reveal, panes, terminal, keyboard audit: done; not yet tried by hand |
| M4 speed | warm daemon (10–20× on recompiles), provisional previews from real engraved glyphs, cancellable full-score re-engraving on every edit with provisional ghost glyphs; in-app verification and content-addressed page caching not started |
| M5 editor and toolchains | not started (LSP client, tree-sitter highlighting, toolchain manager UI) |
| M6 programmability | CLI, MCP, socket, pondside.toml: done; agent pane not started |
| M7 Lexicon | storage, tiers, validation, expansion, checking, six core entries: done; browser, promotion, previews, lock not started |
| M8 time and sound | timing engine, cues.json, handler sync, quark, Cue Inspector, mockup render: done; quark and mockup untested against a real SuperCollider and MuseScore |
| M9 graphic notation | groundwork (entries above) |

### LilyPond 2.26 and the warm daemon (found on macOS, fixed in `LilyPondDaemon`)

CI only runs LilyPond 2.24.3. On 2.26.0 (the Homebrew version) the daemon
broke in two ways the tests would have caught:

- **`include-settings` is an append-only list** in 2.26. `ly:set-option`
  refuses it with a warning, so the job's settings were never read. Output
  then went to the score's own folder, the app found no pages, and the
  status read "LilyPond exited with status 0". Fix: a fixed dispatcher file
  is registered once at start, and it includes the file the loop names in
  `pondside-job-settings`. Also, a job that reports success but leaves no
  pages in its folder now counts as a daemon failure, so the engraver falls
  back to a cold compile.
- **The backend has to be set at start.** LilyPond reads it once while
  initialising: `music-strings-to-paths` (glyphs as paths, not text) and the
  default text fonts in `paper-defaults-init.ly` both depend on it. Setting
  it per job gave dynamics in a text font and fonts laid out differently
  from how they were drawn. The daemon now starts with `-dbackend=svg`, and
  its pages are byte-identical to a cold compile's (links aside).

**Done:** CI has a `linux-lilypond-2-26` job (official 2.26.0 tarball), next to 2.24.

**Measured** on a real 5-page score: the warm and cold compiles both take
about 10 s, because engraving dominates. The startup saving matters only
for small scores. Perceived speed on large scores depends on the
provisional noteheads.

### Instant edits on large scores (plan change, 2026-10-28)

Tim's feedback: 10 s per edit is far too slow; edits must feel instant.
Two parts, since no LilyPond compile will ever take 0 s:

1. **Most of the 10 s was the SVG backend, not engraving.** On a 12-page
   generated score (2.24.3): null backend 2.9 s, PDF 4.9 s, SVG 17.5 s.
   `output-svg.scm` finds every glyph with a regular expression over the
   whole SVG font, copying the font's text each time. `SessionSettings.fastSVG`
   replaces its `cache-font` with a per-font table built in one linear scan,
   plus a memo of named glyphs: **18.2 s → 5.0 s, all 12 pages
   byte-identical** (`testFastSVGIsByteIdentical` pins this on each CI
   LilyPond). It installs only when the procedures it needs exist, checks
   its first answers against the original and turns itself off on any
   difference or error, so a LilyPond whose `output-svg.scm` changed gets
   the stock speed, never wrong output. Both cold and daemon compiles use it.
   - Departure: `-dsvg-woff` (glyphs as font text) looked faster but
     crashes on 2.24.3 (`ly:paper-get-font: Wrong type argument`) and
     leaves pages incomplete. Dropped.
2. **The screen answers before LilyPond does.** Insert, move, delete and
   duration changes draw provisional marks at once (the real engraved
   notehead and stem moved to the new position, a strike-through, a duration
   badge) that the next engraving replaces. Mouse entry uses the same
   engraved glyph instead of an invented ellipse.

Every edit recompiles the whole score. A per-system tile renderer was
tried and removed: fitting a filtered one-system engraving back onto the
old page needed paper-width guesses, horizontal scaling and special cases
for graphic scores, and it was not trustworthy enough to replace the full
render. Provisional ghost glyphs still cover the wait; the full render is
the only source of pages.

Renders are single-flight. A new edit cancels the render in flight, stops
the daemon's current job, and advances a generation counter; only the
newest generation may publish pages. An earlier compile that has already
answered is discarded, so it cannot briefly restore deleted notes. Undo
and redo go through the same edit path and schedule the same full render.
Provisional deletion also refreshes the selection overlay after its
glyphs are marked removed, so the accent highlight cannot outlive the
notes it came from.

Also from that feedback: pages drew in the wrong places after zooming
until hovered (a page view now redraws when it is resized); note keys
went to the text editor when the source had focus (clicking the score now
gives it focus, the focused pane gets an accent border, and the status bar
says where keys go).
