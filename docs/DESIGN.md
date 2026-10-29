# Pondside — design

Status (2026-10-28): the editing loop, multi-file scores, the interface,
speed, the timing and cue tooling, the CLI/MCP/socket, the Lexicon, and
graphic notation on a shared Scheme kit with the agent workflow around it
(§7–8) are built. §9 says what remains.

---

## 0. Principles

- **The `.ly` file is the only source of truth.** Every edit, from the
  score view, the Engraving Settings panel or an agent, is a minimal text
  edit to the user's files. The app keeps no score state anywhere else.
  The only exceptions are derived and disposable: a cache of the latest
  engraving (§8, render cache) and app preferences.
- **LilyPond decides.** Timing, links and diagnostics come from LilyPond
  itself (listeners compiled into the engraving), not from re-implementing
  its semantics. Pondside's own models (the CST, the lens) are checked
  against it.
- **Portable core, disposable shell.** Everything below `PondsideUI` builds
  and tests on Linux. The AppKit front end is a client of the portable
  modules.
- **Pondside computes time; SuperCollider keeps it.** Pondside derives cue
  timestamps from the score and writes them to files. It never schedules,
  plays or sends anything to SuperCollider while it runs. §3 has the
  details.

---

## 1. Module structure

```
                 ┌────────────────────────── portable (Linux CI) ──────────────────────────┐
 PondsideCore    │  stdlib only, not even Foundation. Lossless CST and parser (Syntax/),    │
                 │  pitch/duration model (Music/), ScoreEditor, NoteInput, EngravingMap     │
                 │  (Editing/), the command catalog (Commands/), the Notation Lens's        │
                 │  MusicXML window (Lens/), engraving settings (Settings/).                │
 PondsideEngrave │  Toolchain detection, LilyPond driver and warm daemon, session settings  │
                 │  (point-and-click, fast SVG, timing listener), include graph, SVG →      │
                 │  EngravedPage (geometry, staves, links), diagnostics, watcher, mockup    │
                 │  render, render cache.                                                   │
 PondsideTiming  │  Pure functions: the timing dump → stepped tempo map → cue times         │
                 │  (CueSheet), .scd handler sync. Writes data; plays nothing.              │
 PondsideLexicon │  entry.toml (TOML subset), scopes and tiers, validation, \lexicon        │
                 │  expansion and checking, sound expressions, pondside.toml.               │
 PondsideBridge  │  MCP server (stdio) and the app's JSON-RPC socket. No OSC.               │
 PondsideCLI     │  `pondside`. Links only the modules above.                               │
                 └──────────────────────────────────────────────────────────────────────────┘
                 ─────────────────────────────────── seam ─────────────────────────────────────
 PondsideUI      AppKit (and SwiftUI for panels). Canvas, source panes, lens, palette, hints.
 PondsideApp     Executable target: `main.swift` → PondsideUI.
```

Enforcement:

- **Only on macOS:** `Package.swift` declares `PondsideUI`, `PondsideApp`
  and their packages (SwiftTerm, swift-sheet-music) only under
  `#if os(macOS)`.
- **Linux CI:** builds and tests every portable module, against LilyPond
  2.24.3 and 2.26.0.
- **`scripts/check-seam.sh`:** rejects Apple-only imports below the seam,
  and any Foundation import in Core.

Geometry, hit-testing and link lookup live in Engrave, not UI, so they are
tested on Linux. The UI turns paths into `CGPath` and draws them.

---

## 2. The concrete syntax tree

### Decision: a hand-written lossless parser, not tree-sitter

The CST is a pure-Swift recursive-descent parser
(`Sources/PondsideCore/Syntax`), not a tree-sitter grammar:

- **The hard part would be hand-written anyway.** LilyPond's tokenization
  depends on mode (`\lyricmode`, `\chordmode`, `\markup`, Scheme with
  embedded `#{ #}`), which tree-sitter can only express through a
  hand-written C external scanner.
- **The edit model needs semantics the parser computes for free.** Relative
  octaves, inherited durations, key and note-name language are all resolved
  *lexically* by LilyPond (verified, §6). One parser pass computes them
  exactly.
- **The seam stays clean.** No C target, and Core imports only the standard
  library.
- **Speed is not a reason.** A full re-parse of a large score is fast enough
  to run on every keystroke.

A tree-sitter grammar would still be useful for highlighting in *other*
editors. It would never be the source of truth for Pondside's edits.

### Design principle: structure without meaning

LilyPond can redefine arity and even lexing from Scheme at runtime, so the
parser:

1. **Never encodes arity.** `\foo a b c` is a command followed by a flat
   sequence of items. The CST is a token stream with bracket structure, not
   an AST.
2. **Models what is lexically fixed:** comments, strings, numbers,
   `\commands`, notes (pitch, octave marks, `!`/`?`, octave check),
   durations (dots, `*n/m`), chords, `<< >>`, `{ }`, post-events,
   assignments, property paths, context specs, and Scheme datums. Scheme is
   opaque except for its extent and any embedded music.
3. **Tracks modes** the way LilyPond's lexer does.
4. **Never fails.** Stray closers and unterminated blocks are recovered and
   reported in `SyntaxTree.issues`. Every byte belongs to exactly one leaf,
   so `tree.reconstructed == text` always holds.

The only built-in knowledge is in `KnownCommands`: which bare commands
attach as post-events, which take pitch arguments, and which switch modes.

### How edits use it

Edits never re-print the tree. `ScoreEditor` turns an intention into
`TextEdit`s (byte range → replacement) over the exact characters involved.
Two kinds of compensation keep *other* notes unchanged:

- **Octave marks:** in `\relative`, the marks of exactly the notes whose
  reference changed are rewritten. Raising `d` in `\relative c' { c d e f }`
  gives `c d' e, f`.
- **Inherited durations:** the old value is written on the first inheriting
  note. `{ c'4 d' e' }` → `{ c'4 d'8 e'4 }`.

### The round-trip proof

- **Property tests:** 1,000 random graphical edits per real score, each
  checked for:
  - locality;
  - semantics (every other note keeps its absolute pitch and duration);
  - losslessness;
  - reversibility (inverse edits restore the file byte for byte).
- **Corpus, in CI:** LilyPond's regression suite, snippets and init files
  (2,423 files, 40k edits). Every file is lossless; two exotic
  Scheme-generated files need syntax recovery.
- **Oracle:** an event listener compiled into LilyPond (`EventDump`)
  reports every note's pitch and duration. The model agrees with it on
  every note of every fixture, before and after random edits.

What the corpus taught the edit model:

- **Separators:** inserted and removed text must not fuse tokens.
- **Downstream bare durations:** are written out so they keep sounding the
  same pitch.
- **Chords repeated by `q`:** a chord a later `q` repeats is copied into it
  when the chord is deleted.
- **Refused edits:** edits that can't be meaning-preserving in writing are
  refused rather than guessed.

---

## 3. Time and sound: Pondside computes, SuperCollider plays

This boundary is settled. Pondside does not own a clock, and nothing passes
between Pondside and SuperCollider at run time: no OSC, no live link. The
patch is responsible for playing cues at the right times.

**What Pondside produces**

| Output | From |
|---|---|
| Cue timestamps | `pondside cues score.ly [--format json\|cues] [--rate 48000]` |
| Cue Inspector | the app's pane |
| Handler stubs | `pondside handlers score.ly --scd cues.scd` |
| Mockup | `pondside mockup` |

- **Cue timestamps.** For each cue: measure:beat, the exact rational
  moment, seconds and samples at the project rate, a stable id, and a
  handler name. The `cues` format (`seconds<TAB>bar<TAB>cue N`) is
  byte-for-byte what the lilypond-supercollider loaders already read.
- **Handler stubs.** One stub per cue. Code inside a handler is never
  touched; orphaned handlers are commented out and restored if their cue
  returns.
- **Mockup.** A WAV rendered from LilyPond's own MIDI with MuseScore, or
  fluidsynth as a fallback. Every render is measured, and silence or a
  wrong rate is refused.

**How the times are derived.** Seconds are the MIDI's seconds. The mockup
is rendered from LilyPond's MIDI, which only knows tempo steps, so the
tempo map is stepped:

- a fermata, caesura or timed section is a hidden `\playTempo` step;
- a ritardando is a run of steps.

A model with ramps would disagree with the audio it is meant to sync. The
timing listener (`TimingDump`, injected with `-dinclude-settings` into
every canvas compile) writes the tempo, cue, mark, note and meter rows.
`PondsideTiming` turns them into `CueSheet`. Two different tempos on one
moment produce a warning (the "never put a `\playTempo` where a printed
`\tempo` is" rule).

**On the SuperCollider side.** The patch reads the cue file and schedules
everything on its own clock. `sc/Pondside` is an optional SuperCollider
quark that does this:

- it reads the cue file;
- it plays the mockup and fires the handlers, all from one logical start
  time;
- it refuses to run at the wrong sample rate.

It is SuperCollider code running in sclang, not a connection to Pondside.

**cues.json**, as built (`CueSheet`):

```jsonc
{
  "schema": 1,
  "score": "piece.ly",
  "sampleRate": 48000,
  "tempo": [ { "moment": "0", "seconds": 0, "bpm": 72 } ],
  "cues": [
    { "id": "cue-12", "name": "12", "index": 11,
      "position": { "measure": 42, "beat": 1, "moment": "167/4" },
      "seconds": 133.333333, "samples": 6400000, "handler": "cue12",
      "source": { "file": "electronics.ly", "line": 212, "character": 14 } }
  ],
  "marks": [ { "text": "improv 1", "position": { … }, "seconds": 61.2 } ],
  "duration": 410.5,
  "warnings": []
}
```

Moments are canonical and seconds are derived; `samples` is what a patch
schedules against. Measure:beat is for humans: pickups and cadenzas make it
ambiguous, and `moment` is not.

**Known limits:**

- A file with several `\score` blocks restarts moments in each one.
- The quark and the mockup have not been tested against a real
  SuperCollider and MuseScore.

---

## 4. The Lexicon, as built

The Lexicon is Pondside's library of reusable notation with typed
parameters. Its first part is built (`PondsideLexicon`).

**Entries.** An entry is a folder `entries/<id>/` holding:

- `entry.toml`: id, version, gloss, tags, kind, params, an optional
  `[sound]`;
- `README.md`: when to use it, pitfalls;
- `impl.ily`: LilyPond/Scheme.

```toml
schema   = 1
id       = "air-tone"
version  = "1.0.0"
gloss    = "Air sound: diamond noteheads and a label; cues the patch's air noise"
tags     = ["extended", "winds", "air", "electronics"]
kind     = "texture"                # symbol | texture | pattern | gesture | layout | system
lilypond = ">=2.24"

[entry]
command   = "\\lexicon \"air-tone\" #'((amount . 0.7)) { d''2 e'' }"
attaches  = "span"                  # point | span | staff | system
music-arg = true

[params.amount]
type = "float"                      # float | int | bool | string | enum | duration | pitch | markup
default = 0.5
min = 0.0
max = 1.0
doc = "Air to tone: 0 is nearly all tone, 1 all air"

[sound]                             # optional: names a cue and the patch's parameters
synthdef = "airNoise"
cue      = "airTone"
params   = { amp = "0.05 + 0.4 * amount", dur = "spanDur", rate = "tempo / 60" }
emit     = "onset"
```

**Built**

- **Tiers.**
  - Tier 0: `index.json`, one line per entry (id, gloss, tags, param
    names; about 20 tokens).
  - Tier 1: `entry.toml` plus `README.md`.
  - Tier 2: `impl.ily`.

  Over MCP these are `lexicon://index`, `lexicon://entry/{id}` and
  `lexicon://impl/{id}`.
- **Scopes:** core (bundled) → user (`~/Library/Application
  Support/Pondside/Lexicon`, `$XDG_DATA_HOME` or `$PONDSIDE_LEXICON`) →
  project (`Lexicon/` beside the score). Later scopes win by id, and
  shadowed or broken entries are reported.
- **Validation:** reports every problem at once, so an agent can fix an
  entry in one pass.
- **Sound expressions:** `+ - * /`, parentheses, `min`/`max`. Names are
  checked against the params and `beatDur`/`spanDur`/`tempo`.
- **Invocation:**
  - `\lexicon "id" #'((param . value) …) music`, through a generated
    include (`pondside lexicon include score.ly`).
  - A `[sound]` entry puts a hidden `cue-label` at its start, so its cue
    reaches cues.json like any `\ecue`.
- **Static checking:** `pondside lexicon check` reports unknown entries
  (with near matches), unknown params and out-of-range values, by line.
- **Core entries:**
  - `air-tone`
  - `feathered-beam`
  - `niente-hairpin`
  - `proportional`
  - `senza-misura`
  - `timed-fermata`

**Built since** (2026-10-28):

- **Graphic entries** on the kit (§7): `grain-cloud`, `staff-ripple`, `wedge`,
  `swell-shape`, `scribble`, `arc`, `squiggle`, `pitch-band`,
  `aleatoric-box`. `kind = "graphic"`, `envelope` and `list` param types.
- **Drafts:** a fourth scope, `Lexicon/drafts/`, for entries an agent
  proposed. They are usable at once and accepted (`pondside lexicon promote`,
  or the Lexicon pane) or discarded by a person.
- **The Lexicon pane:** search, params, README, an engraved preview, accept
  or discard drafts, insert a graphic over the selection.
- **The version lock:** `pondside lexicon lock` writes a
  `%% pondside-lexicon-lock` comment block; `check` reports drift.
- **Sound params in cues.json:** the hidden cue event carries the entry, its
  length and its params; the dump passes them on; `CueSheet` evaluates the
  `[sound]` expressions with the cue's real `beatDur`, `spanDur` and `tempo`.
- **Checks and includes** cover every file of the score's include graph.

---

## 5. Engraving and speed

Instant editing is solved. What stands:

- **Warm daemon.** One long-lived `lilypond` process runs the per-file half
  of `lilypond-all` for each job. Nothing in LilyPond is patched.
  - Startup costs 2.9 s of a 3.3 s cold compile on a small score, so warm
    compiles are 10–20× faster.
  - It is robust: a stuck or dead job falls back to a cold compile, and the
    daemon restarts every 150 jobs. Export never uses it.
  - On 2.26, `include-settings` is append-only and the backend must be set
    at start; both are handled, and CI runs 2.24.3 and 2.26.0.
- **Fast SVG.** On large scores the SVG backend, not engraving, dominated:
  `output-svg.scm` searched the whole SVG font with a regular expression
  for every glyph. `SessionSettings.fastSVG` replaces that with a per-font
  table, taking 18.2 s to 5.0 s on a 12-page score. All pages are
  byte-identical, pinned by a test on each CI LilyPond. It checks its own
  answers and turns itself off on any difference.
- **Single-flight renders.** A new edit cancels the render in flight and
  advances a generation counter. Only the newest generation may publish
  pages.
- **The screen answers first.** Edits draw provisional marks at once: the
  real engraved notehead moved, a strike-through, or a duration badge.
- **The Notation Lens** (§8) shows the edited passage engraved instantly.
- **Render cache** (§8): a reopened score shows its last engraving
  immediately.

Rejected along the way:

- **A per-system tile renderer:** it never fitted the old page reliably.
- **`-dsvg-woff`:** it crashes on 2.24.3.
- **The brief's sub-100 ms *compiled* feedback:** impossible, since
  LilyPond breaks lines and pages globally. The perceived latency is met
  instead.

### Multi-file scores, the interface and the programmable surface

- **Multi-file scores.**
  - **The include graph:** `SourceGraph` resolves `\include`s from the
    includer's directory, then the root's, then `-I`. It parses each file in
    the language earlier includes left in effect, iterating to a fixed point.
  - **Per-file state:** every file has its own text, tree, undo stack,
    autosave, watcher, snapshot, diagnostics and links.
  - **Following clicks:** clicking a glyph from another file shows that
    file. Files with notes but no links are named in the status line.
  - **Known limit:** the default duration does not carry across
    `\include`.
- **The catalog** (`PondsideCore/Commands`) is the single list of commands.
  - **Readers:** menus, the palette, hints, the ⌥ reveal and the context
    overlay all read it.
  - **Leader:** Space in the score, ⌥Space anywhere. Groups: `f` file, `g`
    go, `a` add, `e` edit, `v` view, `p` pane, `w` workspace, `h` help.
  - **Audit:** `KeyboardAuditTests` fails if a command has no keys, or if
    chords collide or shadow each other.
  - **Remapping:** `keymap.txt`, ignored as a whole if it breaks the audit.
- **Panes** are frames and content is cargo: content is unique across
  panes, and cycling never changes geometry. The panes are score, source,
  compiler output, terminal (SwiftTerm, pinned 1.5.x), Agent, Cue Inspector and Lexicon.
  Planned content shows a placeholder.
- **CLI:** `check`, `render`, `cues`, `timeline`, `handlers`, `mockup`,
  `lexicon …`, `links`, `doctor`, `watch`, `rpc`, `mcp`, `completion`.
- **MCP** (`pondside mcp`, stdio): tools `check`, `query`, `render`, `cues`,
  `lexicon_check`, and the graphic workflow of §8; the Lexicon tiers and the
  two skills are resources (the skills are prompts too).
- **JSON-RPC socket** for the running app:
  - methods: document state, selection, context, select, engrave, cues, open;
  - events: `score.changed`, `compile.finished`, `selection.changed`.
- **`pondside.toml`:** the LilyPond pin, sample rate, renderer, SoundFont
  and SuperCollider paths. docs/API.md documents all of it.

---

## 6. Facts established empirically (LilyPond 2.24.3, checked on 2.26 where noted)

Pinned in tests, so an upgrade that changes them fails loudly:

- **Point-and-click URIs** are `textedit://PATH:LINE:CHAR:COLUMN`:
  - `LINE` is 1-based.
  - `CHAR` is a 0-based offset in **Unicode scalars**: `{ c'4^"ééé" d'4 }`
    puts `d` at 12.
  - `COLUMN` is 1-based and tab-expanded.
- **Diagnostics** are `FILE:LINE:COLUMN: error: MSG`. `COLUMN` is a 1-based
  display column with tabs at 8.
- **Canvas SVG** uses `<path>`, `<rect ry>`, `<line>`, `<polygon>`,
  `<circle>`, `<ellipse>`, `<text><tspan>`. Colours are on `<g color>` with
  `fill="currentColor"`.
- **`\pointAndClickOff` in a user's file** (musicxml2ly writes it) is
  neutralized in canvas compiles. The session settings wrap `ly:set-option`
  and ignore any `'point-and-click` value but `#t`. Export passes
  `-dno-point-and-click` and scans its output for leaked paths.

Music semantics, measured with `EventDump` (`SemanticsTests`):

- **The `\relative` chain is lexical.** It runs across `<< >>` voices and
  `\repeat` alternatives. Chord members chain from one another, and the
  next event is relative to the chord's first note. Nested `\relative`,
  `\fixed` and `\absolute` are isolated.
- **`\transpose` pitch arguments** become the chain's reference; `\key`
  and `\transposition` arguments do not.
- **Octave checks** pin the pitch, and the chain continues from there.
- **`\relative` without a start pitch** reads as relative to the F below
  middle C.
- **The default duration is lexically global**, multipliers included.
  Tuplets scale the sounding length, not the inherited written value.
- **A bare duration repeats the previous pitch**, or the previous chord
  like `q`. A space between pitch and duration is allowed.

---

## 7. Graphic notation as Lexicon entries on a Scheme kit

Built as proposed below, with two departures found while building it:

- **Params are declared once**, in `entry.toml`; the kit merges the
  defaults. A second declaration in `\defineGraphic` would have had to be
  kept in step. Entries register with `(define-graphic! "id" (lambda (g p) …))`.
- **The invocation is a post-event on any event**, a skip or a note
  (`c''4\startGraphic …`), so a box can sit on the notes it boxes.

The kit is tested by rendering: every graphic entry across a line break,
twice (identical SVG), with its point-and-click link to the invocation.

### What graphic scores need

`Tests/Scores/large-graphic/graphics.ily` (1,700 lines, 129 definitions)
is the reference. Each graphic there:

- **is a spanner** from one moment to another on a staff;
- **is drawn at layout time**, in staff spaces, so it follows the music
  when spacing changes;
- **responds to the layout:** tongue rams sit on the real note columns,
  textures stay clear of the pitch collections, and staff lines turn into
  ripples;
- **survives line breaks**, as one piece per system;
- **is shaped by time:** envelopes (swells, densities, LFOs) driven by
  moments and by the cue times the score itself produces;
- **is reproducible** from fixed seeds.

Most of its 65 `ly:grob-*` calls are the same layout plumbing written again
for each graphic: which system, coordinates relative to a common
reference, other grobs' extents, broken spanner pieces, and note columns.
That plumbing is where the fragility lives, and it is the hard part for an
agent.

### Options considered

| | Raw Scheme per graphic | Python → data | Python → Scheme | **Kit + entries** |
|---|---|---|---|---|
| Sees the layout (columns, other grobs, systems) | yes | no | partly | **yes** |
| Follows respacing | yes | roughly | yes | **yes** |
| Languages, build steps | 1, none | 2, generate | 2, generate | **1, none** |
| What an author writes | everything | shapes | everything, twice | **shapes** |
| Reuse | copy-paste | classes | poor | **entries with typed params** |
| Compiles without Pondside | yes | yes | yes | **yes** |

**Python is out as the drawing language.** LilyPond's horizontal spacing
is not proportional to time (unless proportional notation is on), so a
drawing computed beforehand puts notes and cues in the wrong place. It also
cannot see the other grobs or the system breaks. Python stays as an
optional source of *data*: a script that turns a sound file's analysis into
a list of numbers, which an entry takes as a parameter.

### The kit: `pondside-graphics.ily`

The kit is a core Lexicon file, written and tested once, that owns the
plumbing. An entry receives a context `g` and returns shapes as plain data;
the kit turns them into the stencil.

| Kit API | Gives |
|---|---|
| `(g-width g)`, `(g-pieces g)` | the span's width; its pieces when broken across systems |
| `(g-x-at g moment)`, `(g-x-at-cue g "12")`, `(g-columns g)` | x of a moment, cue or note column, from the real paper columns |
| `(g-staff-y g line)`, `(g-lines g)` | staff line heights (y = 0 is the middle line, in staff spaces) |
| `(g-clear-of g interface)` | intervals to keep clear of (e.g. collections, dynamics), from the skylines |
| `(g-seconds g x)` | time at x, from the score's own tempo (the timing listener) |
| `(g-rand g)` | a seeded random source: same drawing every compile |
| envelopes | `(constant v)`, `(linear a b)`, `(swell peaks lo hi)`, `(lfo rate depth)`, `(from-cues …)`, composable with `env+`/`env*` |
| shapes | `(dot x y r)`, `(stroke pts thick)`, `(fill pts)`, `(wedge x0 x1 h0 h1)`, `(curve pts thick)`, `(text x y markup)`, with `gray` |

The kit handles line breaks. An entry draws as if the span were one strip,
and the kit cuts the strip at each system and shifts each piece. Entries
that care (a ripple that restarts its phase each line) can ask
`(g-pieces g)` instead.

### The entry contract

```scheme
% entries/grain-cloud/impl.ily
\defineGraphic grain-cloud
  #'((density 0.5  number?   "dots per staff space, 0..1")
     (height  (swell 3 0.5 4) envelope? "half-height of the band, staff spaces, over the span")
     (avoid   (note-collection-interface) list? "grobs to keep clear of")
     (seed    0    integer?  "same seed, same drawing"))
  #(lambda (g p)
     ;; returns a list of shapes; nothing else
     …)
```

- **One procedure, `(lambda (g p) → shapes)`.** `p` holds the declared
  params with defaults merged in. It must not draw stencils or touch grobs
  directly, so everything fragile stays in the kit.
- **Declared params are the schema.** `entry.toml` lists the same params
  for tier 0 and tier 1, and `pondside lexicon check` keeps the two in
  step.
- **Invocation is a spanner caused by an event:** `\startGraphic
  grain-cloud #'((density . 0.7)) … \stopGraphic`, in a voice of skips. It
  is linked by point-and-click, so a click on the drawing selects its
  invocation (§8).
- **Entries are generalized versions of specific code.** `graphics.ily`
  becomes a handful of entries (`staff-ripple`, `grain-cloud`, `wedge`,
  `swell-shape`, `echo-burst`, `pixelate`, `tongue-ram-row`) and one
  invocation per passage. A new piece reuses them with new params.
  Promotion is how one piece's custom code becomes the library.

### Two skills, served by the MCP

An agent works at two levels, and each has its own skill. Both are
published by `pondside mcp` as resources and prompts
(`lexicon://guide/graphics`, `lexicon://guide/entries`), and live in the
repo as Claude-style skills, so any agent gets them.

**1. Graphic notation with the Lexicon** (high level, the default). It
assumes the agent stays on the API:

- **Workflow:**
  1. `score_context` (§8).
  2. `lexicon_search`.
  3. Choose an entry and params.
  4. `graphic_preview`.
  5. `graphic_insert`.
- **The kit's vocabulary:** envelopes, shapes, `avoid` lists, cue- and
  system-relative spans, and how words map to params ("expanding and
  contracting" → `swell`; "until the next system" → end at the system
  break).
- **Composition before invention:** layer two entries, or pass an envelope
  built from others, before writing anything new.
- **When to drop down a level:** the user rejects every combination, or the
  idea needs a shape no entry can make.

**2. Writing Lexicon entries** (low level, the recourse). It is for an
agent writing an original entry, or extending the kit, from scratch:

- **The contract:** `\defineGraphic`, param predicates, shapes as data,
  determinism, and what a procedure may and may not do.
- **LilyPond and Guile conventions and gotchas:**
  - Guile 3 has no `string-match`.
  - Music types are lowercase and music names CamelCase.
  - `ly:make-duration` takes the factor as two integers.
  - Callbacks run before the layout is final, so their results get cached.
  - When `after-line-breaking` or a deferred stencil is needed.
  - Skylines and `ly:grob-extent` reference points.
  - Broken spanners and `ly:spanner-broken-into`.
  - Units: staff spaces versus `\mm`.
  - Making the drawing look the same in the PDF and the SVG backends.

  This draws on the existing `lilypond` and
  `lilypond-contemporary-notation` skills.
- **Extending the kit itself:** when a new layout query belongs there
  instead of in an entry, and how to add it with a test.
- **The entry folder:** `entry.toml`, `README.md` (when to use it,
  pitfalls), `impl.ily`, `examples/preview.ly`, and the checks to pass:
  - `pondside lexicon check`;
  - a preview compile on 2.24 and 2.26;
  - two compiles giving identical output.

The low-level skill is long and loaded only when needed. The high-level
one stays short because the kit carries the complexity.

### Preview, validation, trust

- **Preview.** `graphic_preview` compiles a snippet (the passage's staff,
  bars around the span, the entry) on the warm daemon in about 0.2 s and
  returns an SVG. The agent iterates without touching the score.
- **Validation.** `pondside lexicon check` compiles every entry's example
  and checks determinism (two compiles, identical SVG). It also checks that
  `entry.toml` and `\defineGraphic` agree.
- **Trust.** Scheme inside LilyPond can read and write files, so an
  agent's entry is untrusted until the user accepts it. It lives in
  `Lexicon/drafts/` and is used in the score so the user can judge it
  engraved. Accepting promotes it with a version, a README and a preview.

---

## 8. Agents and the MCP ("put a grainy texture here")

Built: `score_context` (from the files, plus the app's `document.context`
for the system: its first and last events in the staff, and the next
system's first), `lexicon_search`, `lexicon_entry`, `graphic_preview`,
`graphic_insert` (which also writes `lexicon.ily` and includes it in the
root), `lexicon_propose`, and the two skills as resources and prompts.
Systems are found from the engraved staves by their gaps
(`EngravedPage.systems`). Promotion is deliberately not an MCP tool.

The intended workflow is right. The user points, the agent reads what
"here" means, reuses or writes an entry, and the user accepts the result
before it joins the Lexicon. The best practices that make it work:

1. **"Here" comes from the app, as data, not from the agent's guess.**
   - **Today:** the MCP server runs separately and the running app's state
     is only on the JSON-RPC socket.
   - **Proposed:** the MCP server reads the socket when the app is open and
     adds a `score_context` tool. It returns:
     - the clicked point: file, line:char, staff name;
     - measure:beat, moment and seconds;
     - the system it is on: the moments where that system starts and ends,
       from the engraved pages and their links;
     - the pertinent `.ly`: the staff block's measures around the point, as
       the lens already finds them (`LensBlockFinder`), plus any
       definitions the passage uses.

     "Until the next system" is then a moment the app supplies, not an
     inference.
2. **Graphics are selectable.** Today a click on an unlinked graphic
   explains itself and selects nothing. Graphics made with the kit
   are spanners caused by an event (`\startGraphic`), so LilyPond links
   them to their invocation. `score_context` on a graphic returns its
   invocation, its entry's id and its params. Hand-written
   Scheme graphics that are spanners started by an event (as
   `\startRipples` is) should link the same way; that needs checking,
   since today such clicks report unlinked music.
3. **Few tools, compact answers.** The tools are:
   - `score_context`;
   - `lexicon_search` (tier 0 lines ranked by tags and gloss);
   - `lexicon_entry` (tier 1);
   - `graphic_preview` (compile an entry on the span in a snippet and
     return an SVG);
   - `graphic_insert` (one minimal edit: the invocation in the right voice
     plus its data file);
   - `lexicon_propose` (write a new entry to the project's
     `Lexicon/drafts/`);
   - the two skills of §7, as resources and prompts.

   Each answer is JSON with source positions, so the agent's next edit is
   exact.
4. **Reuse before writing.** The agent searches the Lexicon, then tries
   existing entries with new params or layered together. Only if the user
   still rejects the result does it switch to the low-level skill and write
   a new entry.
5. **A human gate on the library.**
   - A draft is used in the score at once, so the user sees it engraved,
     but it stays in `drafts/`.
   - The app shows the preview and the diff.
   - Accept promotes the draft to project or user scope, with a version,
     README and preview.
   - Reject removes the draft and its invocation as one undoable edit.
6. **Agent code is untrusted until accepted.** Scheme can reach the file
   system, so drafts run only in previews and in the user's score, and stay
   in `drafts/` until the user accepts them (§7).

---

## 9. What remains

Built in this pass (2026-10-28) and no longer listed: the graphics kit and
nine graphic entries, the two skills, the MCP tools of §8 with the app's
`document.context`, drafts with promotion and discarding, previews, the
version lock, sound params in cues.json, the Lexicon and Agent panes, source
colouring, the LilyPond version picker, mockup padding and per-staff stems,
in-app audition, the shadow history and the CLI installer (§10).

**Notation Lens** (tabled, 2026-10-29)
- Multi-staff systems and repeats: tabled with the fork.
- The `swift-sheet-music` fork (`docs/SHEET_MUSIC_FORK_PLAN.md`): manual and
  feathered beams, beams reaching the middle line, and two-chord tremolo
  heads.

**Editing**
- Adding a note to a chord from the score view.
- Hover tips and the ⌥ reveal only cover a few controls.
- Vim/Emacs presets: dropped as planned. The chords are remappable
  (`keymap.txt`), but the source pane isn't a modal editor, so a preset
  would only rename chords. Revisit with M5's editor.
- Inserting before a staff's first note and tab or percussion staves were
  mouse-entry limits; mouse entry is gone.

**M5: editor and toolchains**
- An LSP client for SuperCollider and Python source panes (those panes are
  still placeholders). Source colouring of `.ly` comes from the CST, not
  tree-sitter.

**M6: programmability**
- `pondside insert` (notes from the command line) and `query --measures`.
  Agents insert graphics through `graphic_insert`.

**M7: Lexicon**
- Previews are rendered on demand (the browser, `graphic_preview`), not
  shipped as `preview.svg`.

**M8: time and sound**
- Playing the mockup through the quark against a booted server (the quark
  compiles and loads its cues in SuperCollider 3.14.1; MuseScore 4 renders
  mockups and stems; nothing was played aloud in testing).
- The timing dump reads the scores with a `\layout`; a `\score` that has only
  `\midi` (an unfolded copy for playback) restarts moments. Point the
  dump at the layout score, or keep one `\score` with both.

**M9: graphic notation**
- Microtonal accidental entries and annotation layers.
- The full aleatoric-box system with links and arrows lives in the
  `lilypond-contemporary-notation` library; `aleatoric-box` is the drawn,
  single-box form.

**From the brief**
- Licensing: a decision for the author (LilyPond is GPL-3 and runs as a
  separate process; SwiftTerm and swift-sheet-music are MIT).
- Glass on macOS 26: needs the macOS 26 SDK; floating chrome uses
  `GlassView` (blur plus a dimming layer) meanwhile.
- Canvas text fonts fall back through C059 → TeX Gyre Schola → …; only
  text can differ from the PDF.

---

## 10. Built since M3 (2026-10-28)

### Notation Lens

The lens answers the typing gap with a disposable local engraving, not a
second score file.

- **How it renders.**
  1. `PondsideCore/Lens` finds the staff-level block around the edit (the
     outermost `{ … }` below any staff group, a voice split kept whole,
     named by its top-level assignment).
  2. It scans that block's clefs, meters, pickup, tuplets, tremolos and
     graces, following variables such as `\global`.
  3. It writes one staff of MusicXML in memory.
  4. `swift-sheet-music` (pinned 4.11.0) parses and lays it out.
- **Timing comes from structure, not bar checks.** A sequence adds
  durations, every branch of `<< >>` starts together, graces take no time,
  and tuplets and `\repeat tremolo` scale.
- **What the writer spells out.** Explicit accidentals, by LilyPond's
  default rule per voice and measure.
- **Attached after parsing.** Slurs, tuplet brackets and tremolos, all of
  which the importer drops.
- **What the importer can't do.** Manual or feathered beams.
- **Presentation** (HIG Popovers and Loading; `.claude/skills/pondside-ui`).
  - **Popover:** an `NSPopover` above the edited staff, on paper a shade
    off white. It never takes key focus and stays put once open.
  - **Showing it:** it appears without animation, and fades out once the
    render has landed and it has been up 1.5 s since it last changed.
  - **Keys:** `⌘L` keeps it open until `⎋`, and ←→ step through the
    target's voice.
  - **Reduce Motion:** turns the motion into jumps.
- **Speed.** Building the window takes under 1 ms; parse plus layout
  takes 14–16 ms warm.
- **Requirements.** macOS 15 behind a macOS-14-safe protocol, built with
  Swift 6.4.1.

### Engraving Settings

File › Engraving Settings… (`⌘⇧E`, `␣ f s`) is a floating panel, because
people change a setting and watch the score. It holds LilyPond's
score-wide settings in seven groups:

- **Page:** paper size, margins, indents, page numbers.
- **Staves & Systems:** staff size, staff and system distances,
  justification and page filling.
- **Notes & Beams:** automatic and subdivided beaming, note spacing.
- **Accidentals:** style, key cancellation.
- **Meters & Bar Lines:** time signature visibility and style, bar line
  style, bar numbers, compressed rests.
- **Tuplets:** brackets, numbers.
- **Text:** tagline.

The defaults are LilyPond's own, and every statement compiles on 2.24 and
2.26.

**How it reads and writes** (`PondsideCore/Settings`):

- **Where settings are read:** each setting is read where the score keeps
  it: top-level `\paper` and `\header`, any `\layout`, and its `\Score` and
  `\Staff` contexts.
- **How a change is written:**
  - it replaces that statement in place (comments kept);
  - or it adds one line at the end of its block;
  - at the default, it removes the line.

  A missing block is added where LilyPond reads it. A user's alist is read
  but never rewritten.
- **Other files** are only read. What they set is shown under the control,
  and changing it writes an explicit statement in the root.
- **Undo:** each change is one undoable edit.

musicxml2ly writes `autoBeaming = ##f` and `printKeyCancellation = ##f`.
The first time a score with such a file opens, Pondside offers once to
write LilyPond's defaults in the root. Its `\pointAndClickOff` needs
nothing (§6).

The Add menu also gained Clef…, Time Signature…, Key Signature…, Tempo…,
Text…, Cue and a Tuplet… picker for any ratio. Clef, meter, key and tempo
replace the same command already standing before the note.

### Render cache and Open Recent

- **Render cache.** A reopened score shows its last engraving at once
  while LilyPond engraves it afresh.
  - **Where:** `PondsideEngrave/RenderCache`, one entry per score in
    `~/Library/Caches/Pondside/Renders`.
  - **What an entry holds:** LilyPond's SVG pages plus each file's text as
    engraved, so links map onto text that has changed since.
  - **Writing:** atomic replacement, one store at a time, the 50 most
    recent entries within 500 MB.
  - **Status bar:** reads "Last engraving · Engraving..." until the fresh
    pages land.
- **Open Recent.** Uses the list macOS keeps.

### Interface details

- **First engraving:** a subtle drawing staff in the empty pane, after
  250 ms.
- **Status dot:** pulses, and the ellipsis fills in, during engravings
  longer than 300 ms. Both stay still under Reduce Motion.
- **Hints:** include "⌘/ all actions".
- **Delete:** deleting a staff's last note selects the note before it, not
  the next staff's first.
- **Glass chrome** (palette, hover tips, the lens popover): the blur stays,
  with a dark layer inside (`GlassView`) so a white page behind can't wash
  out the text, and lighter secondary text (`Theme.glassSecondaryText`, above
  4.5:1). Solid under Reduce Transparency; darker, with a border, under
  Increase Contrast.
- **Menus show their keys:** commands without a macOS shortcut show their
  score key or chord in the shortcut column (in the secondary colour).
  ⌘⇧E works: Engraving Settings was missing from the File menu.
- **Panes:** the Lexicon pane (§4) and the Agent pane (a terminal running
  `[agent] command` from pondside.toml, default `claude`, which reaches
  Pondside through `pondside mcp`).
- **Source colouring** from the CST's token kinds (commands, strings,
  numbers, comments, Scheme, braces), as TextKit 2 rendering attributes, so
  undo and the text are untouched.
- **File › LilyPond Version…** lists every installation; choosing one pins
  it in pondside.toml, which the app now honours as the CLI does.
- **View › Play from Here** (⌘⇧P) plays the mockup from the selected bar,
  timed by the score's own tempo map; again to stop.
- **Pondside › Install Command-Line Tool…** (Appendix A.11).

---

## Appendix A. Corrections to the brief (decided 2026-10-27)

1. **No MusicXML export from LilyPond.** Mockups go through LilyPond's
   MIDI (§3).
2. **Leader chords:** Space is the leader in the score (⌥Space anywhere),
   because `a`–`g` enter notes. LilyPond syntax typed into the score is the
   fast path.
3. **Sub-100 ms compiled feedback** is impossible; perceived latency is met
   instead (§5).
4. **Core Graphics into Core Animation, not Metal.** Revisit only if
   profiling asks for it.
5. **Automatic commits never touch the user's repository.** Built as
   `ShadowHistory`: a git repository per score under
   `~/Library/Application Support/Pondside/History` (its work tree the
   score's folder, so nothing is written into the project, not even a
   `.pondside/` folder, and no consent is needed). A checkpoint follows 30 s
   after the last save and on close; `pondside history` lists, shows and
   restores.
6. **Autosave races:** content-hash ownership, atomic writes, minimal-diff
   merges, and a conflict sheet with recovery files.
7. **`\ecue`, not `\cue`** (LilyPond already has cue notes). Timing comes
   from a LilyPond listener, not from parsing tempo out of the CST.
8. **Shortcuts:** they avoid macOS conventions. Workspace save is `⌘⌥S`;
   `⌘/` is the context overlay in the score.
9. **Hold-⌥ reveal:** arms only on a bare ⌥ held 500 ms.
10. **Canvas text fonts:** see §9.
11. **Install location:** Pondside › Install Command-Line Tool… links
    `pondside` into `~/.local/bin` (no admin rights) and says how to add it
    to `PATH`.
12. **Licensing:** see §9.
13. **Muse Sounds from the CLI:** silence detection and the fluidsynth
    fallback are mandatory, and both are built.
14. **Over-specified brief items** (gradient budget, music font, layout
    presets) are defaults, not acceptance criteria.
15. **Glass on macOS 14 vs 26:** see §9.
