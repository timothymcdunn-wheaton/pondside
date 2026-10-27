# Pondside

A native macOS notation environment on the LilyPond engine. The score is a
plain `.ly` file: diffable, git-versionable, and editable by any tool or
agent with no API at all. Pondside watches it, engraves it, and links every
glyph back to the characters that produced it.

> Zero lock-in: Pondside stores nothing but your LilyPond source. Stop using
> it tomorrow and you lose nothing.

The full plan, the schemas, and the parts of the brief I'd change are in
**[docs/DESIGN.md](docs/DESIGN.md)**.

## Status: M1 (the loop)

- Open a `.ly` file. It is engraved by the LilyPond you already have
  (detected on `PATH`, Homebrew, MacPorts, `/Applications`; nothing is
  installed for you).
- Source and score sit side by side. Click a glyph to select its source
  token; move the caret to highlight the glyph; drag a rectangle to select a
  span. `←`/`→` in the score walk through objects in source order.
- Edits autosave after 250 ms and re-engrave. If another tool writes the
  file, Pondside merges the change as a minimal diff, so your caret stays
  put, and re-engraves.
- `⌘E` exports a PDF with point-and-click disabled, then checks the output
  for local filesystem paths before writing it.

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
```

## Layout

| Module | Platform | Role |
|---|---|---|
| `PondsideCore` | portable, stdlib only | source coordinates, diffs, disk sync, versions |
| `PondsideEngrave` | portable | toolchain detection, LilyPond driver, SVG scene, diagnostics, watcher |
| `PondsideTiming` / `Lexicon` / `Bridge` | portable | placeholders for M6 to M8, already under the seam |
| `PondsideCLI` | portable | `pondside` |
| `PondsideUI`, `PondsideApp` | macOS | AppKit front end |

CI builds and tests the portable modules on Linux and everything on macOS.
`scripts/check-seam.sh` rejects Apple-only imports below the seam.
