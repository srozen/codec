# Codec

A native macOS terminal. It looks like a modern macOS app (Liquid Glass toolbar, native tabs, translucent window) and borrows its personality from a certain codec screen.

## Build & run

Requires macOS 26+ and Xcode 26+ (Swift 6).

```bash
scripts/build-app.sh          # release build → build/Codec.app
open build/Codec.app
```

`scripts/build-app.sh debug` makes a debug build. You can also open `Package.swift` in Xcode, but notifications only work from the bundled `.app`.

## Field manual

| | |
|---|---|
| **Channels** | Each window or tab is a channel tuned to its own frequency (`140.85`, `141.12`, …), shown on a seven-segment readout in the toolbar and in the tab title. The shell sees it as `$CODEC_FREQUENCY`. |
| **Signal meters** | The bars on either side of the frequency rise with output throughput. |
| **Tuning sequence** | A new channel scans for its frequency through static, then the screen unfolds from a single line like a CRT powering on. |
| **"!" alert** | When the bell rings, a red **!** pops over the cursor, the frequency flashes red and a synthesized alert plays. |
| **Incoming calls** | A bell in a background channel makes its tab flash `CALL`, badges the Dock icon and posts a notification. Clicking it takes you to that channel. |
| **Signal lost** | If the shell is killed or crashes, the channel shows **SIGNAL LOST** instead of vanishing. Press Return to continue (start a new shell) or Esc to exit. |
| **Themes** | Codec (green phosphor), Shadow Moses (arctic), Outer Heaven (amber), Tanker (light). |

All sounds are synthesized at runtime; no game assets are included.

### Shortcuts

| | |
|---|---|
| ⌘N / ⌘T | New window / new tab (the tab opens in the current directory) |
| ⌘1…⌘9 | Jump to channel |
| ⇧⌘[ / ⇧⌘] | Previous / next tab |
| ⌘+ / ⌘− / ⌘0 | Bigger / smaller / actual size |
| ⌘K | Clear buffer |
| ⌘F, ⌘G, ⇧⌘G | Find |
| ⌘, | Settings |

## Layout

```
Sources/Codec/
  main.swift, AppDelegate.swift, MainMenu.swift   app lifecycle, menus, window/tab management
  ChannelWindowController.swift                    one channel: shell, toolbar, bell, exit handling
  ChannelView.swift                                window content: blur, tint, terminal, scanlines, overlays
  CodecTerminalView.swift                          SwiftTerm subclass, bell relay, process inspection
  CodecViews.swift                                 SwiftUI: toolbar band, tuning, signal lost, "!" alert
  SevenSegment.swift                               seven-segment display and signal meter
  Theme.swift, Preferences.swift, SettingsView.swift
  CodecSound.swift, IncomingCalls.swift, Session.swift
scripts/build-app.sh                               builds and bundles Codec.app
scripts/make-icon.swift                            renders the app icon
```

Terminal emulation is provided by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
