# Pondside

A native macOS notation environment on the LilyPond engine. The score is a
plain `.ly` file: diffable, git-versionable, and editable by any tool or
agent with no API at all. Pondside watches it, engraves it, and links every
glyph back to the characters that produced it.

> Zero lock-in: Pondside stores nothing but your LilyPond source. Stop using
> it tomorrow and you lose nothing.

The full plan, the schemas, and the parts of the brief I'd change are in
**[docs/DESIGN.md](docs/DESIGN.md)**.

## Status

**Done:** M1 (the loop), M2 (editing), M2.1 (multi-file scores) and mouse entry.
**In, with first parts of later milestones:** M3 (the interface), M4 (a warm LilyPond daemon), M6 (CLI, MCP server),
M7 (the Lexicon) and M8 (the timing engine, cue sheets, SuperCollider handlers and quark). CI builds and tests
everything on Linux and macOS. The app's UI compiles in CI, but mouse entry and the M3 interface (chords, palette,
panes, terminal) have not been tried by hand yet. See `docs/DESIGN.md` §7 for what each milestone still lacks.

- **Open and engrave.** Open a `.ly` file. It is engraved by the LilyPond
  you already have, detected on `PATH`, Homebrew, MacPorts or
  `/Applications`. Nothing is installed for you.
- **Point-and-click both ways.** Click a glyph to select its source; move
  the caret to highlight the glyph; drag a rectangle to select a span.
- **Multi-file scores just work.** Clicking a note that lives in an
  `\include`d file opens that file in the source pane. Every file in the
  include graph is watched, autosaved and undoable on its own. Pondside
  keeps point-and-click on even when a file says `\pointAndClickOff` (as
  musicxml2ly output does), and it never edits your file to do so.
- **Edit in the score.** Keyboard note entry turns into minimal text
  edits. Only the characters that must change do, and other notes keep
  their pitch and duration, even in `\relative`. ⌘Z undoes score and text
  edits alike, in order.
- **Never lose work.** Edits autosave after 250 ms and re-engrave. If
  another tool writes a file, the change is merged as a minimal diff so
  your caret stays put.
- **Mouse entry.** Arm a duration (type `8` with nothing selected), then
  click a staff: a ghost notehead shows where the note will go. The clef is
  read from the notes already on that staff.
- **Two keys to everything.** Press Space in the score (⌥Space anywhere)
  and the hint bar lists what can follow: `g` go, `a` add, `e` edit, `v`
  view, `p` pane, `w` workspace, `f` file, `h` help. `␣ a s` slurs the
  selection, `␣ g e` jumps to the next error, `␣ ␣` opens the palette.
  `⌘K` is the fuzzy palette (every row shows its keys), `⌘/` lists what
  you can do right now, and holding `⌥` shows the keys on the controls.
  Remap anything in `~/Library/Application Support/Pondside/keymap.txt`
  (`go.error = x`). A test fails the build if any command lacks a key or
  two chords collide.
- **Panes are frames, content is cargo.** `⌃⇥` cycles the focused pane
  through score, source, compiler output and a terminal, and `⌃1`…`⌃0`
  jump straight to one. The frames never move. `⌘1`…`⌘5` switch layouts,
  `⌘⌥S` saves a workspace (⌘⇧S stays Save As), and `␣ w o` opens one.
- **Fast recompiles.** A warm LilyPond process stays loaded for each open
  score, so a recompile skips LilyPond's startup: 10–20× faster on slow
  machines. It falls back to a fresh process if anything goes wrong.
- **Electronics cues.** `pondside cues score.ly` times every `\ecue` exactly
  as the MIDI plays (hidden `\playTempo` included). `pondside handlers`
  keeps a SuperCollider file of cue handlers in step with the score
  without touching your code, and `sc/Pondside` is a quark that plays the
  mockup and fires them on SuperCollider's clock.
- **The Lexicon.** `\lexicon "timed-fermata" #'((seconds . 6)) { g'1 }`:
  reusable, parametric notation with typed, range-checked params, in
  three scopes (core, user, project). Entries can carry a sound, which
  places a cue. Agents browse it in tiers: `pondside lexicon list` or the
  MCP resources.
- **For agents.** `pondside mcp` is an MCP server: check, query (events
  with resolved absolute pitches), render, cues, Lexicon checks, and the
  Lexicon as resources. See [docs/API.md](docs/API.md).
- **Export.** `⌘E` exports a PDF with point-and-click disabled, then checks
  the output for local filesystem paths.

### Score keys

Keys are LilyPond wherever LilyPond has an answer.

| Keys | Effect |
|---|---|
| `a`–`g` (`h`) | insert that note after the selection: nearest octave, the key's accidental |
| `r` | insert a rest |
| `1 2 4 8 16 32 64 128` | duration, as in LilyPond; changes the selection and arms the next note |
| `.` | toggle dot |
| `↑` `↓` | diatonic step · `⇧` octave · `⌥` chromatic |
| `←` `→` | previous / next object · `⇧` extends |
| `( ) ~ [ ]` | slur, tie, beam: toggled on the selection |
| `-.` `->` `^-` `_1` … | articulations and fingerings, exactly as typed in LilyPond |
| `\trill` `⏎` | any post-event command, typed as in LilyPond |
| `⌫` | delete |
| `⎋` | cancel / deselect / disarm |
| click a staff | with a duration armed: place a note there |
| `Space` | leader: chords such as `␣ a s` (slur), `␣ g e` (next error), `␣ g c` (go to cue), `␣ ␣` (palette) |
| `⏎` | edit in source |
| `⌘J` | switch between score and source |
| `⌘⇧]` `⌘⇧[` | next / previous file |

## Build

Requires Swift 6 (Xcode 16+) and macOS 14+ on Apple Silicon for the app.
The portable modules and the CLI also build on Linux.

```sh
swift build                      # everything (the app only on macOS)
swift test                       # integration tests run if LilyPond is installed
scripts/make-app.sh              # → .build/Pondside.app
open .build/Pondside.app --args path/to/score.ly
```

## CLI

```sh
pondside doctor                  # every LilyPond found, with version and origin
pondside check score.ly --json   # compile, report diagnostics
pondside render score.ly --format pdf --out build/
pondside links score.svg --json  # point-and-click map of a canvas SVG
pondside watch score.ly --on-change 'pondside render score.ly'
pondside cues score.ly --format cues     # seconds<TAB>bar<TAB>cue N, for SuperCollider
pondside handlers score.ly --scd cues.scd
pondside lexicon list                    # tier 0 of the Lexicon
pondside mcp                             # MCP server on stdio (claude mcp add pondside -- pondside mcp)
```

Everything the CLI and MCP server offer is documented in [docs/API.md](docs/API.md).

## Layout

| Module | Platform | Role |
|---|---|---|
| `PondsideCore` | portable, stdlib only | lossless LilyPond CST, music model (pitches, durations, relative octaves), minimal-diff score editor, note input |
| `PondsideEngrave` | portable | toolchain detection, LilyPond driver, include graph, SVG scene, diagnostics, watcher, event oracle |
| `PondsideTiming` / `Lexicon` / `Bridge` | portable | placeholders for M6 to M8, already under the seam |
| `PondsideCLI` | portable | `pondside` |
| `PondsideUI`, `PondsideApp` | macOS | AppKit front end |

CI builds and tests the portable modules on Linux and everything on macOS.
`scripts/check-seam.sh` rejects Apple-only imports below the seam.
