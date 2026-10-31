# Codec

A native macOS terminal: Liquid Glass chrome, tabs and split panes in one window, shell integration that tracks every command, a command palette, and codec-style system meters.

## Build, run, test

Requires macOS 26+ and Xcode 26+ (Swift 6).

```bash
make run       # build build/Codec.app (release) and open it
make test      # build and run all tests
make build     # debug build only
```

`make` builds with two jobs to keep memory use reasonable; override with `make test JOBS=8`. Without make: `scripts/build-app.sh [debug|release]`, `swift test`.

### Sounds

Put `codec_call.mp3`, `codec_lock.mp3` and `codec_exit.mp3` in `Resources/Sounds/` and the build script bundles them. They're git-ignored, since they're game audio; without them Codec synthesizes similar cues.

## Features

- **Tabs and splits.** Tabs live in the title bar. Split any pane right (⌘D) or down (⇧⌘D); inactive panes dim. New tabs and panes open in the current directory.
- **Tab names.** A tab is titled after what's running in it. Double-click it, right-click → Rename Tab…, or press ⇧⌘R to give it a name of your own; clear the name to go back to the automatic title.
- **Right-click menu.** Copy, Paste, Select All, Split Right/Down, Find, Clear Buffer, Restart Shell, Open in Finder, Copy Path, Close Pane. Programs that use the mouse (vim, htop, tmux) still get right-clicks.
- **Shell integration (zsh).** Codec loads a small hook script through `ZDOTDIR`, then your own startup files unchanged. It reports OSC 133 prompt marks, the working directory (OSC 7) and each command's exit status and duration. That gives you:
  - the status bar: directory (click to open in Finder), git branch, and the running or last command with its exit status and time,
  - ⌘↑ / ⌘↓ to jump between commands in the scrollback,
  - a notification when a command that ran longer than 10 s finishes in a pane you aren't looking at.
- **System meters.** The right end of the status bar shows CPU, memory and network as codec-style rising bars and seven-segment readouts; bars turn red above 85 %. Click to open Activity Monitor. Can be hidden in Settings.
- **Command palette.** ⇧⌘P, or the ⌘ button in the tab bar. Fuzzy search over every action, theme and open tab.
- **Attention.** A bell or a finished long command in a background pane marks its tab, badges the Dock icon and posts a notification; clicking it takes you there. In the focused pane, the bell shows a small "!" at the cursor.
- **Exits.** A clean `exit` closes the pane. If the shell crashes or is killed, the pane stays with a banner: Return restarts it, Esc closes it.
- **Themes.** Codec, Arctic, Amber and Daylight, with adjustable blur and opacity.

### Shortcuts

| | |
|---|---|
| ⌘T / ⌘N | New tab / new window |
| ⌘D / ⇧⌘D | Split right / split down |
| ⌘W / ⇧⌘W | Close pane / close window |
| ⌘] / ⌘[ | Next / previous pane |
| ⌥⌘←→↑↓ | Focus the pane in that direction |
| ⇧⌘] / ⇧⌘[, ⌃⇥ | Next / previous tab |
| ⌘1…⌘9 | Go to tab |
| ⇧⌘R | Rename tab |
| ⌘↑ / ⌘↓ | Previous / next command |
| ⇧⌘P | Command palette |
| ⌘K | Clear buffer |
| ⌘F, ⌘G, ⇧⌘G | Find |
| ⌘+ / ⌘− / ⌘0 | Font size |
| ⌘, | Settings |

## Architecture

Three targets, compiled in Swift 6 language mode (strict concurrency):

| Target | What's in it |
|---|---|
| `CodecCore` | Logic with no UI, all of it unit-tested: the split layout tree and pane geometry, shell integration scripts and environment, integration event parsing, bell and exit policies, preferences, git branch lookup, process inspection, system sampling. |
| `CodecUI` | AppKit and SwiftUI: app delegate and menus, window controller, tabs, panes, chrome, palette, settings, sounds, notifications. |
| `Codec` | The executable; calls `CodecApp.run()`. |

`CodecUI` takes its services through an `AppEnvironment` (preferences, sound player, notifier, system monitor, shell integration, app coordinator), and panes talk to their window through the `PaneHost` protocol. Tests swap in fakes for both.

```
Sources/CodecCore/   SplitLayout, Commands, ShellIntegration, Policies, Preferences,
                     GitInfo, ProcessInspector, SystemMonitor, FuzzyMatch
Sources/CodecUI/     AppDelegate, MainMenu, AppEnvironment, TerminalWindowController, TerminalTab,
                     Pane, PaneView, CodecTerminalView, WindowChrome, StatusBar, CommandPalette,
                     SettingsView, Theme, SevenSegment, CodecSound, Notifier, Session, Log
Sources/Codec/       main.swift
Tests/CodecCoreTests unit tests, plus zsh integration tests that run a real zsh in a headless terminal
Tests/CodecUITests   panes, context menu, tabs, window layout and actions, palette, end-to-end zsh tests
scripts/             build-app.sh (bundles Codec.app), make-icon.swift (renders the icon)
```

Tests use [Swift Testing](https://developer.apple.com/documentation/testing). CI (`.github/workflows/ci.yml`) builds, runs the tests and bundles the app on every push and pull request.

Terminal emulation is provided by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
