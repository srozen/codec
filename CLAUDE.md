# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Codec is a native macOS 26+ terminal written in Swift 6 (strict concurrency) with AppKit, SwiftUI and [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). It's a SwiftPM package; there's no Xcode project.

## Quality gates

Before calling a change done, run what CI (`.github/workflows/ci.yml`) runs, in this order, and report failures with their output:

```bash
swift build -j 2 --build-tests     # 1. builds the app and both test targets
swift test -j 2 --skip-build       # 2. every test (~460, about a minute); UI tests open real windows
ARCHS="arm64 x86_64" scripts/build-app.sh release   # 3. universal Codec.app, as releases are built
```

`make test` does 1 and 2. Gate 3 takes about 4 minutes (two release builds joined with `lipo`); run it in the background. It matters most when you touch `Package.swift`, `scripts/`, `Resources/` or architecture-specific code, but CI runs it on every push. There's no linter or formatter: match the surrounding code.

Keep `-j 2` (the Makefile's default `JOBS`) unless asked otherwise: more jobs use a lot of memory.

## Commands

```bash
make build                     # debug build
make run                       # release Codec.app in build/, then open it
swift test --skip-build --filter TextSearch           # one suite (type name or regex)
swift test --skip-build --filter "FindTests|SplitLayoutTests"
swift test --skip-build --filter splitsLeftAndUpPutTheNewPaneFirst   # one test
make screenshots               # retakes docs/images; opens windows for ~1 min, leave the Mac alone
```

`--filter` matches the test's type and function names (not the `@Suite("…")` display name). Build with `--build-tests` before `--skip-build`, or the run uses stale test binaries.

## Architecture

Three targets (details in `docs/development.md`):

- **`CodecCore`**: all logic with no UI, fully unit-tested: the split layout tree (`SplitLayout`), shell integration, command blocks and timelines, history, Intel, preferences, git, syntax highlighting, Markdown, updates. It doesn't depend on SwiftTerm. Put anything testable without AppKit here.
- **`CodecUI`**: AppKit and SwiftUI. `TerminalWindowController` owns tabs (`TerminalTab`, a `SplitLayout<Pane>` plus split sizes) and handles most menu actions. `Pane` owns one shell: the process, its `PaneView` (the `CodecTerminalView` plus overlays: find bar and highlights, command marks, dimmer, exit banner) and its observable `Session`.
- **`Codec`**: `main.swift`, which calls `CodecApp.run()`.

Services come in through `AppEnvironment` (preferences, sounds, notifier, system monitor, shell integration, history, coordinator), and a pane reaches its window only through the `PaneHost` protocol. Tests build both with fakes: `TestEnvironment` and `FakeHost` in `Tests/CodecUITests/TestSupport.swift`.

**Shell integration.** The zsh scripts are string literals in `CodecCore/ShellIntegration.swift`, installed into Application Support and loaded through `ZDOTDIR`. The user's own `.zshrc` still loads. They report OSC 133 prompt marks, OSC 7 for the directory, and OSC 6973 (`IntegrationEvent`) for each command and its exit status. `Pane` turns these into command blocks and timeline entries.

**Terminal rows.** SwiftTerm is used through public snapshots (`terminalContentSnapshot`) and a subclass, `CodecTerminalView`. Row numbers (`absoluteRow`) survive scrolling but change when the terminal rewraps on resize. Code that remembers rows must handle that, as `Pane.relocateBlocksIfNeeded` and `TerminalFinder` do. `TerminalGrid` maps cells to window points; it measures cells from the caret.

**Adding a user-facing action** usually means touching several places together: `MainMenu` (key equivalent, `W.` selector), the `@objc` action on `TerminalWindowController`, the command palette list in the same controller, the pane's right-click menu in `Pane.contextMenu`, the docs (`docs/shortcuts.md` and the relevant page), and the tests that pin menus (`ModelTests` for key equivalents, `PaneContextMenuTests` for the context menu's exact titles).

## Tests

- Swift Testing (`@Suite`, `@Test`, `#expect`), not XCTest. UI suites are `@MainActor` and `.serialized`, and wait with `waitUntil { … }`.
- UI tests open real windows and run real shells (`/bin/sh` by default; `TestEnvironment(shell: "/bin/zsh", integration: true)` for zsh end to end).
- `terminal.feed(text:)` draws text without going through the process, so `Pane`'s output tick doesn't see it. To test anything that reacts to output, have the shell print it with `terminal.send(txt:)`.
- The terminal only draws while its window counts as visible. Test processes' windows never do, so `ScreenshotTour` swaps `NSWindow.occlusionState` to capture them.
- Calling `NSButton.performClick` in a test can make the test process exit once its last window closes. Set `state` and use `sendAction` instead.

## Conventions

- Comments and docs are plain prose explaining why, in the voice already used throughout; match their density.
- User-facing behavior is documented in `docs/*.md` (keyboard shortcuts in `docs/shortcuts.md`); update them with the change. When a feature's look changes, retake the screenshots (`make screenshots`) and commit the images with it.
- Commit messages: a short imperative title ("Split panes left and up too"), then a prose body on what changed and why.
- Releases are `v*` tags, built by `.github/workflows/release.yml`. Don't tag or touch `Casks/codec.rb` unless asked.
