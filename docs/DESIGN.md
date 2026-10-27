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
   with per-page layers plus cached system tiles it scrolls at display rate.
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
