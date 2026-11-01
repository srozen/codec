# Getting started

## Requirements

- macOS 26 or later
- Xcode 26 or later (Swift 6), to build it

## Build and install

Codec isn't distributed as a download yet; you build it from source.

```bash
git clone https://github.com/srozen/codec.git
cd codec
make run
```

`make run` builds `build/Codec.app` in release and opens it. Drag it to `/Applications` to keep it, or run it from where it is: the next `make run` rebuilds it in place, so you always run what's in your checkout.

Other targets:

```bash
make build     # debug build only
make test      # build and run all tests
make app       # build build/Codec.app without opening it
```

`make` builds with two jobs to keep memory use reasonable; override with `make run JOBS=8`. Without make: `scripts/build-app.sh [debug|release]`, `swift test`.

### Sounds

Codec plays short codec cues: a call when a background pane needs you, and, if you turn them on, a lock-on when a pane opens and a static burst when one closes or its shell crashes. Put `codec_call.mp3`, `codec_lock.mp3` and `codec_exit.mp3` in `Resources/Sounds/` and the build bundles them. They're git-ignored, since they're game audio; without them Codec synthesizes similar cues. See [Settings › Alerts](settings.md#alerts).

## First steps

Open a few panes and try the things Codec adds on top of a terminal:

1. **Split** the window with ⌘D (right) or ⇧⌘D (down). New panes open in the current directory.
2. **Run a few commands**, then press ⇧⌘L: the [Commands sidebar](commands-sidebar.md) lists them, with their output, so you can go back to any of them.
3. **Press ↑** at an empty prompt for the [history menu](command-line.md#history-menu), or ⌘Y to search everything you've run, anywhere.
4. **Press ⇧⌘E** for the [file tree](files-and-editor.md) of the project you're in, and click a file to read it beside the terminal.
5. **Press ⇧⌘I** for [Intel](intel.md): save a command you'll need again, with blanks to fill in next time.
6. **Press ⇧⌘P** for the command palette: every action, theme and tab, fuzzy-searched.

## Shell integration (zsh)

Codec loads a small hook script into zsh through `ZDOTDIR`, then your own startup files (`.zshenv`, `.zprofile`, `.zshrc`, `.zlogin`), unchanged. The hooks report:

- where each prompt starts and ends, and where each command's output starts and ends (OSC 133 marks),
- the working directory (OSC 7),
- each command's text, exit status and duration.

That's what the Commands sidebar, the status bar, ⌘↑ / ⌘↓ between commands, Copy Output, history with folders and durations, notifications for long commands, the editable command line and Codec's prompt are built on.

Turn it off in Settings › Shell › Shell integration; it applies to new panes. Other shells (bash, fish, nushell…) run as plain terminals: set one in Settings › Shell.

## Where Codec keeps things

| What | Where |
|---|---|
| Settings, window state, and the windows and tabs to reopen | `~/Library/Preferences` (the app's defaults) |
| Command history | `~/Library/Application Support/Codec/history.jsonl`, plus your zsh history file, which Codec reads but never changes |
| Your Intel | `~/.codec/intel` |
| A project's Intel | `.codec/intel` in its git repository |
| The shell integration scripts and your prompt | `~/Library/Application Support/Codec/shell-integration` |
