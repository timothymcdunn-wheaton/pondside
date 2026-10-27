# Pondside — design proposal

Status: **M1 in progress.** This document answers the four questions asked
before code (module structure, tree-sitter approach, `entry.toml`, `cues.json`)
and lists the places where I think the brief is wrong, unachievable, or
over-specified. Decisions marked **(proposed)** want a yes/no from you.

---

## 1. Module structure

```
                 ┌────────────────────────── portable (Linux CI) ──────────────────────────┐
                 │                                                                          │
 PondsideCore    │  stdlib only — not even Foundation. SourceText (line index, LilyPond     │
                 │  coordinates ↔ String.Index ↔ UTF-16), PointAndClickLocation,            │
                 │  TextDiff (minimal replacement), DiskSync, LilyPondVersion.              │
                 │  M2 adds: CST wrapper, edit model, selection model, undo log.            │
                 │                                                                          │
 PondsideSyntax  │  (M2) tree-sitter runtime + LilyPond and Scheme grammars as C targets,  │
                 │  wrapped in Swift. Depends on Core. Portable C, builds on Linux.         │
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
- **A separate `PondsideSyntax`.** tree-sitter is C. Keeping it out of Core
  means Core stays a stdlib-only Swift module that compiles anywhere in
  seconds, and the C build lives in one place.

---

## 2. Tree-sitter grammar approach

**Start by evaluating the grammars that already exist** (there is at least
one community `tree-sitter-lilypond` plus a companion Scheme grammar). Two
gates: (a) it round-trips the LilyPond regression suite with zero `ERROR`
nodes in files LilyPond itself accepts, and (b) its tokens line up with
point-and-click locations. If it passes, vendor it and contribute fixes
upstream. If not, write our own along the lines below. In both cases it's
pinned as a C target in `PondsideSyntax`.

### Design principle: structure without meaning

The brief's warning is right and decides everything here: LilyPond's arity
and even its lexing can be changed from Scheme at runtime. So the grammar:

1. **Never encodes arity.** `\foo a b c` parses as a command followed by a
   flat sequence of items. Whether `\foo` takes 0, 1 or 3 arguments is known
   only to the compiler. The CST is a token stream with bracket structure,
   not an AST.
2. **Models what is lexically fixed:** comments (`%`, `%{ %}`), strings,
   numbers, `\commands`, notes (pitch + octave marks + `!`/`?` + duration +
   dots + `*n/m` multipliers), chords `< >`, simultaneous `<< >>`,
   sequential `{ }`, post-events (`-.`, `^"x"`, `(`, `)`, `~`, `\f`, …),
   bar checks, top-level assignments, `\header`/`\paper`/`\layout` blocks,
   and **Scheme** after `#`/`$` via injection into the Scheme grammar.
3. **Uses an external scanner for modes.** `\lyricmode`, `\lyrics`,
   `\addlyrics`, `\chordmode`, `\figuremode`, `\drummode` and `\markup` change
   tokenization of the next block. The scanner tracks a mode stack keyed on
   the keyword that preceded `{`. Unknown user-defined mode switches fall
   back to note mode. When that's wrong, the result is an `ERROR` node local
   to that block, and the daemon is still the truth.
4. **Recovers from errors.** tree-sitter's error recovery is why we use it.
   An unbalanced brace while typing must not invalidate the rest of the
   file's structure.

### How edits use it

The CST is consulted to *locate* the bytes to change. It is never re-printed.
A graphical edit is:

```
selection (point-and-click position) → CST leaf → semantic sub-token
(e.g. the octave marks of a note) → (byte range, replacement) → apply
```

Text outside the range is never touched, so formatting, comments and
whitespace survive by construction, not by care. `TextDiff` and
`UTF16Replacement` (M1) are the primitives this builds on.

### The round-trip proof (M2 acceptance)

- **Corpus:** LilyPond's own `input/regression` (~1,500 files) plus a
  Mutopia sample. Test-only, never shipped.
- **Property test:** for each file, apply 1,000 random graphical edits
  (transpose, change duration, add/remove articulation, insert/delete note).
  After each edit, assert: (1) bytes outside the edit range are identical;
  (2) re-parsing yields the same tree outside the edited subtree; (3)
  applying the inverse edit restores the file byte-for-byte.
- **Oracle check:** for a subset, compile before and after with LilyPond and
  diff the event dump. A transpose of one note must change exactly one event.

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

Ordered by consequence.

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

---

## 7. M1 scope and status

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
