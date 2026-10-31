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
- **An editable command line (zsh).** At the prompt, the command you're typing works like a text field. Click to put the cursor anywhere, drag to select part of it, double-click a word, triple-click the whole line. Typing replaces the selection and ⌫ / ⌦ delete it; ⌘X cuts it, ⌘C copies. ⇧ with arrows (and ⌥, Home, End) extends a selection, ⌘← / ⌘→ jump to either end, ⇧⌘← / ⇧⌘→ select to them, ⌘⌫ deletes to the start. zsh stays the editor, so completion, history and plugins like zsh-autosuggestions keep working; its selection (the region) is what's highlighted, in the theme's selection color.
- **Text selection.** Double-click selects a whole token: a path with its line and column (`Sources/App/Main.swift:42:7`), a URL, an email address, an IP and port, a flag with its value. Surrounding brackets, quotes and trailing punctuation are left out. Triple-click selects the line, ⌥-drag a rectangular block. Copy on select is a setting (Settings › Shell › Selection). The scrollback keeps 10,000 lines.
- **Command output (zsh).** Copy or select what a command printed without dragging over it: right-click the output → Copy Output / Select Output, or ⇧⌘C / ⇧⌘A for the last command. Codec finds a command's output from the command line itself, so it stays right however fast the output scrolled by.
- **File tree.** ⇧⌘E, or the sidebar button left of the tabs, opens the files of the focused pane's project: its git repository, or its directory outside one. It follows the pane as you `cd`, opens down to the current directory, updates as files change on disk, and colors files by git status (modified, added, untracked, ignored, with a dot on folders holding changes). Files and folders have Codec's own icons, drawn from the theme's palette: a page with a folded corner and a monogram (SW, TS, PY…) or glyph per type (a `>_` for scripts, signal bars for audio, a key for `.env`…), and folders colored by role (sources, tests, docs, assets, scripts), dimmed for build output and dependencies, with the current one in the accent. Type in the filter field to fuzzy-search every file in the project. Click a folder to open it, click a file to view it in the editor, or right-click: Open in Default App, Open in Terminal Editor (`$EDITOR` in a new pane), Change Directory Here, Open in New Tab, Insert Path, Copy Path / Relative Path, Reveal in Finder. Drag files from the tree or from Finder onto a pane to type their quoted paths. Return opens, ⌘C copies paths, Esc goes back to the terminal; drag the edge to resize.
- **Editor.** Click a file in the tree to see it beside the terminal; the next click replaces it, as a preview tab (in italics). Double-click, press Return, or start typing to keep it in a tab of its own. Code is colored by Codec's own highlighter, from the theme's palette: Swift, JavaScript/TypeScript, Python, Ruby, Go, Rust, C/C++/Objective-C, Java, Kotlin, C#, PHP, Lua, SQL, shell scripts and Dockerfiles, JSON, YAML, TOML/INI, HTML/XML, CSS and Markdown. Editing works as you'd expect from a code editor: line numbers, the current line highlighted, Return keeps indentation (and adds a level after `{` or `:`), Tab and ⇧Tab indent and outdent the selected lines in the file's own style, ⌘/ toggles comments, ⌘F finds, undo is per file. ⌘S saves, ⌘W closes the file while the editor has the keyboard (⌥⌘W from anywhere), and Codec asks before throwing away unsaved changes. If a file changes on disk it reloads, or, when you have edits, asks whether to reload or keep yours. Markdown opens rendered, styled from the theme, with tables, task lists and colored code blocks; switch between Source, Split (live preview beside the source) and Preview with the control in the editor's header or ⇧⌘V. Links open in the browser, links to other files open in the editor. Images and PDFs are shown too; other files offer to open in their app. Drag the editor's edge to resize it.
- **Branch switcher.** Click the branch in the status bar, or in the prompt itself (it works for your own PS1 too, wherever it shows the branch), or press ⇧⌘B to switch branches: fuzzy-search local branches (most recent first) and remote ones, which become tracking branches. Type a new name to create a branch. If git refuses, say because of uncommitted changes that would be overwritten, its explanation is shown in the popover. The prompt and status bar update straight away.
- **History as you type (zsh).** The rest of the most recent matching command appears dimmed after the cursor: → or End takes it, ⌥→ one word. (If you use zsh-autosuggestions, it keeps doing this instead.)
- **History menu and search.** ↑ at the prompt opens a menu just above it, filtered by what you've typed, the newest command nearest the prompt: ↑/↓ to browse, type to narrow it, Return to put the command on the line, ⌘Return to run it. ⌃R at the prompt, or ⌘Y anywhere, opens the full search: every command with where it ran, how long it took, when, and whether it failed, grouped by day, filterable to this folder or to failed commands. Matches rank by how well they match (start of the command, then anywhere, then fuzzy), then by whether they ran in this folder, then by how recent. Right-click a command to copy it or its folder, or remove it from history (⌘⌫). Codec keeps its own record in `~/Library/Application Support/Codec/history.jsonl` and includes your zsh history file, so older commands and those from other terminals are there too. Commands typed with a leading space aren't kept. ↑ and ⌃R are only taken over where they still do zsh's default (an fzf ⌃R stays fzf's); multi-line commands keep ↑ for moving between lines.
- **Friendlier Tab completion (zsh).** Matching ignores case and finds text inside names, so `dev` completes `Development` and `notes` completes `my-notes.txt`; a typo is forgiven in longer words; ambiguous completions open a menu you can move through with the arrows, in the theme's colors, folders first. Codec loads zsh's completion system if your `.zshrc` doesn't, and never overrides completion styles you set yourself. Each of these can be turned off in Settings › Shell.
- **Right-click menu.** Copy, Copy Output, Select Output, Paste, Select All, Split Right/Down, Find, Clear Buffer, Restart Shell, Open in Finder, Copy Path, Switch Branch…, Close Pane. Programs that use the mouse (vim, htop, tmux) still get right-clicks.
- **Shell integration (zsh).** Codec loads a small hook script through `ZDOTDIR`, then your own startup files unchanged. It reports OSC 133 prompt marks, the working directory (OSC 7) and each command's exit status and duration. That gives you:
  - the status bar: directory (click to open in Finder), git branch (click to switch), and the running or last command with its exit status and time,
  - ⌘↑ / ⌘↓ to jump between commands in the scrollback,
  - a notification when a command that ran longer than 10 s finishes in a pane you aren't looking at.
- **Prompt builder.** Settings › Prompt › Edit Prompt… works like Warp's: pick the Codec prompt or keep your shell's own (PS1), and build the Codec prompt from chips. Click or drag a chip to add it, drag to reorder, × to remove, right-click to recolor. Chips: working directory, git branch (with `*` for uncommitted changes), git changes (`3 • +10 -2`), Python environment, Kubernetes context, last command's duration and exit status, background jobs, user@host, time and date. By default segments are drawn as chips: tinted, rounded pills like the ones in Codec's status bar, colored from your theme, with the directory in bold. The Text style draws them as a phrase instead (`~/code/codec on main* via venv took 3.2s`). Choose one or two lines and the symbol, which turns red after a failed command. Changes apply to open zsh panes at their next prompt. Values from the shell (branch names and the like) are escaped, so they can't run code even with `prompt_subst` on.
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
| ⇧⌘C / ⇧⌘A | Copy / select the last command's output |
| ⇧⌘B | Switch branch |
| ⇧⌘E | Show / hide the file tree |
| ↑, ⌃R (at the prompt), ⌘Y | History menu, history search |
| →, ⌥→ | Take the suggested command, or its next word |
| ⌘S, ⌥⌘W | Save / close the file in the editor |
| ⌘/ | Toggle comment |
| ⇧⌘V | Markdown: toggle preview |
| ⌘← / ⌘→, ⇧⌘← / ⇧⌘→, ⌘⌫ | Command line: move to, select to, delete to the start or end |
| ⌘F, ⌘G, ⇧⌘G | Find |
| ⌘+ / ⌘− / ⌘0 | Font size |
| ⌘, | Settings |

## Architecture

Three targets, compiled in Swift 6 language mode (strict concurrency):

| Target | What's in it |
|---|---|
| `CodecCore` | Logic with no UI, all of it unit-tested: the split layout tree and pane geometry, shell integration scripts and environment, integration event parsing, bell and exit policies, preferences, git branch lookup and switching, smart selection, command block tracking, syntax highlighting, Markdown rendering, file types, command history ranking and storage, process inspection, system sampling. |
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
