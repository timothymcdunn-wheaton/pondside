# AGENTS.md

Pondside is a macOS LilyPond notation app with a portable core, CLI and MCP
server. The `.ly` file is the only source of truth: the app watches and
rewrites it, and stores no score state elsewhere.

Read `docs/DESIGN.md` §8 for current milestone state before planning work.
The status at the top of that file is stale, and the `README.md` module
table still calls Timing/Lexicon/Bridge placeholders. CLI, MCP,
`cues.json`, `pondside.toml` and the RPC socket are documented in
`docs/API.md`.

## Commands

```sh
./scripts/check-seam.sh          # after touching any portable source
swift build                      # portable modules; on macOS also UI/app
swift build --build-tests
swift test                       # engraving tests skip without LilyPond
swift test --filter PondsideCoreTests/KeyboardAuditTests
swift run pondside check score.ly
scripts/make-app.sh debug        # .build/Pondside.app (macOS only)
open .build/Pondside.app --args path/to/score.ly
```

CI order is seam check → `swift build --build-tests` → `swift test
--skip-build`. There is no linter, formatter or codegen step.

## Prerequisites and platform

- Swift 6; macOS 14+ and Xcode 16+ for the app.
- `swift test` on macOS needs a full Xcode toolchain. With Command Line
  Tools only it fails with `no such module 'XCTest'`.
- LilyPond must be installed for real engraving tests (PATH, Homebrew,
  MacPorts, `/Applications`, or `PONDSIDE_LILYPOND`).
- Linux CI builds and tests only the portable targets; UI/app compile
  errors are caught by the macOS job.

## Architecture and the portability seam

`Package.swift` is authoritative for the target graph.

- `PondsideCore` — lossless LilyPond CST/parser, music model, minimal-diff
  `ScoreEditor`, note input. **Swift stdlib only, not even Foundation.**
- `PondsideEngrave` — toolchain detection, LilyPond driver and warm
  daemon, include graph, SVG scene/geometry, diagnostics, watcher, timing.
- `PondsideTiming`, `PondsideLexicon`, `PondsideBridge` — tempo/cues,
  Lexicon, MCP and Unix-socket JSON-RPC.
- `PondsideCLI` — the `pondside` executable.
- `PondsideUI` / `PondsideApp` — AppKit front end; macOS-only and treated
  as the disposable shell.

Everything below `PondsideUI` must build on Linux. `scripts/check-seam.sh`
rejects Apple-only imports there and any `import Foundation` in
`PondsideCore`. Keep hit-testing, geometry and other logic in `Engrave` so
it stays portable and testable.

## Editing conventions

- Score edits are minimal `TextEdit`s over byte ranges. Do not re-print or
  re-emit the CST: tests assert `tree.reconstructed == text` and that
  inverse edits restore the file byte for byte.
- New user commands go in `Sources/PondsideCore/Commands/Catalog.swift`.
  `KeyboardAuditTests` fails if a command lacks a key/chord or two chords
  collide.
- Core Lexicon entries live in
  `Sources/PondsideLexicon/Core/Lexicon/entries/<id>/` as `entry.toml`,
  `impl.ily` and `README.md`. The folder name must equal `id`; the whole
  `Core` directory is a SwiftPM resource and is scanned at runtime, so new
  entries need no registry update.

## Testing quirks

- LilyPond integration tests use `XCTSkip` when it is absent, so a green
  run may have tested nothing about engraving. Check skipped tests before
  claiming success.
- `PONDSIDE_CORPUS=/path/to/lilypond/sources` enables the corpus
  round-trip/fuzz test (CI uses the 2.24.3 regression suite and snippets);
  it skips locally by default.
- `PONDSIDE_ORACLE_SEED` seeds the engraving oracle fuzz test; the default
  is deterministic.
- `Tests/Scores` is shared by path relative to `#filePath`, not through a
  test bundle. `Tests/PondsideEngraveTests/Fixtures` is copied via
  `.copy("Fixtures")` in `Package.swift`.
- CI runs against LilyPond 2.24.3 and 2.26.0; daemon/settings/SVG behavior
  differs between them, so don't assume one version.
- There are no UI tests; `PondsideUI` is only compile-checked on macOS.
