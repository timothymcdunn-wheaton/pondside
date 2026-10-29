# Pondside for agents and scripts

Pondside's first API is the file. A score is plain LilyPond. Any tool can
read and write it, and the app re-engraves when it changes on disk, merging
the change into whatever is open. Everything below is for when a tool wants
more than text: diagnostics from LilyPond itself, events with resolved
pitches, cue times, the Lexicon.

Every surface here is portable: the CLI and MCP server link no AppKit and
run on Linux.

## The CLI

```
pondside check   score.ly [--json]                 compile; diagnostics; exit 1 on errors
pondside render  score.ly [--format pdf|svg|png] [--out dir] [--json]
pondside cues    score.ly [--format json|cues] [--rate 48000] [--out file]
pondside timeline score.ly [--json]                tempo steps: moment, seconds, quarters/min
pondside handlers score.ly --scd cues.scd [--project dir]
pondside lexicon list | search <words> | show <id> | impl <id>
pondside lexicon check score.ly | include score.ly | lock score.ly
pondside lexicon drafts | promote <id> [--to user] | discard <id>   agent drafts: only people promote them
pondside mockup  score.ly [--out file.wav] [--stems]   padded to the end mark; --stems: one file per staff
pondside history score.ly [--show <rev> [--file f]] [--restore <rev>]   checkpoints, kept outside your repo
pondside links   page.svg [--json]                 point-and-click links with bounds
pondside doctor  [--json]                          every LilyPond found, version and origin
pondside watch   file --on-change <command>
pondside mcp     [--project dir]
pondside completion zsh|bash                       eval "$(pondside completion zsh)"
```

- `render` always disables point-and-click, then scans the output for local
  paths before writing it.
- `cues` and `timeline` come from LilyPond's interpretation of the score:
  a dump engraver runs during a normal compile. No timing is guessed from
  the text. Seconds are the MIDI's seconds: stepped tempos, 60 quarters a
  minute before any `\tempo`, hidden `\playTempo` changes included.
- `--format cues` writes `seconds<TAB>bar<TAB>cue N` lines, the format
  SuperCollider loaders in the lilypond-supercollider workflow already
  read.

## Project settings: `pondside.toml`

Put `pondside.toml` at the project root. The CLI and the app read the
nearest one at or above the score, and command-line options override it.

```toml
[lilypond]
version = "2.26.0"            # compile with this LilyPond; wins over \version

[audio]
sample-rate = 48000           # cue samples and the mockup; the quark checks it
renderer = "musescore"        # or "fluidsynth"
soundfont = "sounds/piano.sf2"

[supercollider]
handlers = "patch/cues.scd"   # the default for `pondside handlers`
resources = "patch/resources"

[agent]
command = "claude"            # what the app's Agent pane runs (default "claude")
```

File › LilyPond Version… in the app writes `[lilypond] version` for you.

## MCP

`pondside mcp` speaks the Model Context Protocol on stdin/stdout (JSON-RPC
2.0, one message per line). Protocol versions: 2025-06-18, 2025-03-26 and
2024-11-05.

Setup:

| Client | How |
|---|---|
| Claude Code | `claude mcp add pondside -- pondside mcp` |
| opencode | in `opencode.json`: `"mcp": { "pondside": { "type": "local", "command": ["pondside", "mcp"] } }` |
| anything else | `{ "command": "pondside", "args": ["mcp"] }` in the client's MCP server list |

Pass `--project <dir>` if the client starts servers somewhere other than
the score's folder. Relative `file` arguments and the project Lexicon scope
resolve against it.

### Tools

| Tool | Arguments | Returns |
|---|---|---|
| `check` | `file` | `{ ok, pages, diagnostics: [{ severity, file, line, column, message }] }` |
| `query` | `file`, `from_line?`, `to_line?` | events in order: `{ kind, text, line, character, pitches, duration, explicitDuration }` |
| `render` | `file`, `format?` (`pdf`·`svg`·`png`), `out?` | `{ files }` |
| `cues` | `file`, `rate?` | cues.json (below) |
| `lexicon_check` | `file` | problems with `\lexicon` and `\startGraphic` uses, by line |
| `score_context` | `file?`, `line?`, `character?` | what "here" means: the event, its staff's `.ly`, its bar, the graphic it is in (entry, params, start, stop); from the running app also `system: { first, last, next }`. Without arguments, the app's selection |
| `lexicon_search` | `query`, `limit?` | tier 0 lines, best first |
| `lexicon_entry` | `id` | tier 1: params with types, ranges and docs; README |
| `graphic_preview` | `id`, `params?`, `bars?`, `music?`, `out?` | `{ svg, source, diagnostics }`: the entry engraved on its own staff |
| `graphic_insert` | `file`, `id`, `params?`, `start_line`, `start_character`, `stop_line`, `stop_character`, `root?` | inserts `\startGraphic`…`\stopGraphic` on those events (one staff), writes `lexicon.ily` and includes it in the root |
| `lexicon_propose` | `id`, `entry_toml`, `impl`, `readme` | writes a validated draft to `Lexicon/drafts/entries/<id>`; the user accepts or discards it |

`query` pitches are absolute Dutch names (`c'` is middle C) in any input
language, with `\relative` and chord-repeat (`q`) resolved. `character` is
the 0-based Unicode-scalar offset within the line, as in LilyPond's
point-and-click. Tool failures, such as a missing file or LilyPond not
installed, come back as results with `isError: true`, not as protocol
errors.

### Resources: the Lexicon in three tiers

| URI | Tier | Content |
|---|---|---|
| `lexicon://index` | 0 | one JSON line per entry: id, gloss, kind, tags, param names, whether it has a sound |
| `lexicon://entry/{id}` | 1 | entry.toml plus the README: param types and ranges, when to use, pitfalls |
| `lexicon://impl/{id}` | 2 | impl.ily, to read only when adapting the entry |

Read the index first, open an entry only when it is a candidate, and read
its implementation only to adapt it.

### Skills (resources and prompts)

| URI / prompt | Use |
|---|---|
| `lexicon://guide/graphics` · `graphic-notation` | the default for graphic notation: `score_context` → `lexicon_search` → `graphic_preview` → `graphic_insert`; the core graphic entries; envelopes; combining entries |
| `lexicon://guide/entries` · `lexicon-entries` | writing a new entry when no combination satisfies the user: the graphics kit's API, the entry folder, LilyPond and Guile gotchas, checks |

### Graphic entries

`\startGraphic "id" #'((param . value) …)` on an event and `\stopGraphic`
on a later one in the same staff draw a graphic between them, at layout
time, through the graphics kit (`pondside-graphics.ily`, included by
`lexicon.ily`). Core graphic entries: `grain-cloud`, `staff-ripple`,
`wedge`, `swell-shape`, `scribble`, `arc`, `squiggle`, `pitch-band`,
`aleatoric-box`. `envelope` params take a number or `(swell n lo hi)`,
`(linear a b)`, `(pulse …)`, `(lfo …)`, `(points (q v) …)`, `(sum …)`,
`(product …)`, `(smooth …)`. Graphics are linked by point-and-click to
their `\startGraphic`. Drafts in `Lexicon/drafts/` are usable at once and
listed as drafts; `pondside lexicon lock` records the versions a score uses
in a comment block, and `check` warns when an entry has changed since.

## cues.json

```jsonc
{
  "schema": 1,
  "score": "piece.ly",
  "sampleRate": 48000,
  "tempo": [ { "moment": "0", "seconds": 0, "bpm": 72 }, … ],   // quarters per minute
  "cues": [
    {
      "id": "cue-12",               // name + occurrence: stable when the cue moves
      "name": "12",
      "index": 12,
      "position": { "measure": 42, "beat": 1, "moment": "167/4" },  // moment: whole notes, exact
      "seconds": 133.333,
      "samples": 6400000,           // round(seconds × sampleRate)
      "handler": "cue12",           // the handler's name in the generated .scd
      "entry": "air-tone",          // a Lexicon entry's cue: the entry, and its
      "params": { "amp": 0.25, "dur": 4, "rate": 1 }   // [sound] params with real timing
    }
  ],
  "marks": [ { "text": "improv 1", "position": { … }, "seconds": 210.5 } ],
  "duration": 412.0,                // to the "end" mark, else the last event
  "warnings": [ "two different tempos at moment 21/2: …" ]
}
```

Cues are `\ecue "N"` (the electronics staff library) or Lexicon entries
with a `[sound]` binding. Both put a `cue-label` on a hidden text event.

## SuperCollider

`pondside handlers score.ly --scd cues.scd` writes one handler stub per
cue. Run it again after editing the score: it adds stubs for new cues,
updates the comment line above each handler, and comments out handlers
whose cue has gone (with `//~ `, restored exactly if the cue returns). It
never changes code inside a handler.

The quark in `sc/Pondside` plays the mockup and fires the handlers:

```supercollider
p = Pondside("~/scores/piece/resources");   // piece.cues + piece.wav
p.on(\cue12, { |cue| ~swell.set(\amp, 0.5) });
p.play(from: "42");                          // bar 42, or seconds
```

It refuses to play when the server's sample rate differs from the
mockup's, and prints the line that fixes it.

## The running app: JSON-RPC over a Unix socket

While Pondside runs, it listens on
`~/Library/Application Support/Pondside/pondside.sock` (or
`$PONDSIDE_SOCKET`). Only the user can connect: the socket is mode 0600.
Messages are JSON-RPC 2.0, one per line. `pondside rpc <method> [params]`
calls a method from the shell.

| Method | Params | Result |
|---|---|---|
| `app.version` | | name, version, socket path |
| `app.documents` | | each open score: `root`, `files`, `active` file, `status` |
| `document.text` | `path?` | `{ path, text }`: the app's current text, including unsaved edits |
| `document.selection` | `path?` | `{ path, start, end, text, events }`, with positions as `{ line, character }` |
| `document.context` | `path?`, `line?`, `character?` | the selection's (or that point's) `score_context`, with `system: { first, last, next }` from the engraving |
| `document.select` | `path, line, character` | puts the caret there (the score highlights it); returns the selection |
| `document.engrave` | `path?` | starts a compile; the result arrives as `compile.finished` |
| `document.cues` | `path?` | the latest cues.json |
| `document.open` | `path` | opens a score in a window |
| `subscribe` / `unsubscribe` | `events: [names]` (`"*"` for all) | the current subscriptions |

`path` names any file in an open score's include graph. Without it, the
frontmost score is used.

Events, sent as notifications to subscribers:

| Event | Params |
|---|---|
| `score.changed` | `{ path, by }`, where `by` is `app` (typed in Pondside) or `disk` (another tool wrote the file) |
| `compile.finished` | the score's summary, as in `app.documents` |
| `selection.changed` | the selection, as in `document.selection` |
