# Development

## Building and testing

```bash
make build         # debug build
make test          # build and run all tests
make run           # build build/Codec.app (release) and open it
make screenshots   # retake the screenshots in docs/images
```

`make` builds with two jobs to keep memory use reasonable; override with `make test JOBS=8`. Without make: `swift build`, `swift test`, `scripts/build-app.sh [debug|release]`.

Tests use [Swift Testing](https://developer.apple.com/documentation/testing). Besides unit tests, some run a real zsh in a headless terminal, end to end. CI (`.github/workflows/ci.yml`) builds, runs the tests and bundles the app on every push and pull request.

## Architecture

Three targets, compiled in Swift 6 language mode (strict concurrency):

| Target | What's in it |
|---|---|
| `CodecCore` | Logic with no UI, all of it unit-tested: the split layout tree and pane geometry, shell integration scripts and environment, integration event parsing, bell and exit policies, preferences, git branch lookup and switching, smart selection, command block tracking, each pane's command timeline and kept output, Intel files and their variables, syntax highlighting, Markdown rendering, file types, command history ranking and storage, process inspection, system sampling. |
| `CodecUI` | AppKit and SwiftUI: app delegate and menus, window controller, tabs, panes, chrome, sidebars, editor, palette, settings, sounds, notifications. |
| `Codec` | The executable; calls `CodecApp.run()`. |

`CodecUI` takes its services through an `AppEnvironment` (preferences, sound player, notifier, system monitor, shell integration, history, app coordinator), and panes talk to their window through the `PaneHost` protocol. Tests swap in fakes for both.

```
Sources/CodecCore/    SplitLayout, ShellIntegration, CommandBlocks, CommandTimeline, CommandHistory,
                      Intel, MarkdownRenderer, SyntaxHighlighter, PromptConfiguration, GitInfo, …
Sources/CodecUI/      AppDelegate, MainMenu, AppEnvironment, TerminalWindowController, TerminalTab,
                      Pane, PaneView, CodecTerminalView, WindowChrome, StatusBar, CommandPalette,
                      FileTreeSidebar, CommandTimelineSidebar, IntelSidebar, EditorPanel, SettingsView, …
Sources/Codec/        main.swift
Tests/CodecCoreTests/ unit tests, plus zsh integration tests that run a real zsh in a headless terminal
Tests/CodecUITests/   panes, sidebars, editor, window layout and actions, palette, end-to-end zsh tests
scripts/              build-app.sh (bundles Codec.app), make-icon.swift (renders the icon),
                      screenshots.sh (retakes docs/images)
```

Terminal emulation is provided by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## Screenshots

The images in `docs/images` come from `make screenshots`, which runs `Tests/CodecUITests/ScreenshotTour.swift`: real Codec windows, a real zsh, and a fresh clone of this repository with a few demo changes, branches, history and Intel items, all in a throwaway home folder under `.build`, so none of your own history, Intel or files show up.

Windows open on screen while it runs (about a minute); leave the Mac alone, and unlocked, until it's done. When a feature's look changes, retake them and commit the new images with it.
