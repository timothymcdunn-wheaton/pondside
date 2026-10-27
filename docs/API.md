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
pondside lexicon list | show <id> | impl <id> | check score.ly | include score.ly
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
| `lexicon_check` | `file` | problems with `\lexicon` uses, by line |

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
      "handler": "cue12"            // the handler's name in the generated .scd
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
