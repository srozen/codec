import Testing
import AppKit
import CodecCore
@testable import CodecUI

@Suite("Themes")
struct ThemeTests {
    @Test(arguments: CodecTheme.all)
    func everyThemeHasAFullPalette(theme: CodecTheme) {
        #expect(theme.ansi.count == 16)
        #expect(theme.terminalPalette.count == 16)
    }

    @Test func idsAreUnique() {
        #expect(Set(CodecTheme.all.map(\.id)).count == CodecTheme.all.count)
    }

    @Test func unknownIDsFallBackToCodec() {
        #expect(CodecTheme.named("shadow-moses") == .codec)
        #expect(CodecTheme.named("amber") == .amber)
    }

    @Test func darkAndLightAppearances() {
        #expect(CodecTheme.codec.appearance?.name == .darkAqua)
        #expect(CodecTheme.daylight.appearance?.name == .aqua)
    }

    @Test func convertsColorsToSixteenBitChannels() {
        let white = NSColor(hex: 0xFFFFFF).terminalColor
        let red = NSColor(hex: 0xFF0000).terminalColor
        #expect(white.red == 65535 && white.green == 65535 && white.blue == 65535)
        #expect(red.red == 65535 && red.green == 0 && red.blue == 0)
    }
}

@Suite("SevenSegment")
struct SevenSegmentTests {
    @Test func foldsDecimalPointsIntoThePreviousDigit() {
        let glyphs = SevenSegment.glyphs("140.85")
        #expect(glyphs.count == 5)
        #expect(glyphs.map(\.dot) == [false, false, true, false, false])
        #expect(glyphs[0].segments == ["b", "c"])
        #expect(glyphs[3].segments == SevenSegment.all)
    }

    @Test func handlesLeadingAndRepeatedDots() {
        #expect(SevenSegment.glyphs(".5").map(\.dot) == [true, false])
        #expect(SevenSegment.glyphs("1..").map(\.dot) == [true, true])
    }

    @Test func unknownCharactersAreBlank() {
        #expect(SevenSegment.glyphs("?").first?.segments.isEmpty == true)
    }

    @Test func aspectRatioGrowsWithDigits() {
        #expect(SevenSegment.aspectRatio(for: "1") < SevenSegment.aspectRatio(for: "100"))
        #expect(SevenSegment.aspectRatio(for: "1.0") == SevenSegment.aspectRatio(for: "10"))
    }

    @Test(arguments: [("7", 3, "  7"), ("42", 3, " 42"), ("100", 3, "100"), ("1.2", 3, " 1.2"), ("1234", 3, "1234")])
    func padsReadouts(value: String, width: Int, expected: String) {
        #expect(value.leftPadded(to: width) == expected)
    }
}

@Suite("Synthesized sounds")
struct SynthTests {
    @Test(arguments: CodecSound.Cue.allCases)
    func rendersValidWav(cue: CodecSound.Cue) {
        let wav = Synth.wav(for: cue)
        #expect(wav.count > 44)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
    }
}

@Suite("Session")
@MainActor
struct SessionTests {
    @Test func titleFollowsWhatsRunning() {
        let session = Session()
        session.directory = "/Users/me/code/codec"
        session.processName = "-zsh"
        #expect(session.title == "codec")
        session.processName = "vim"
        #expect(session.title == "vim")
        session.apply(.commandStarted("sudo npm run build"))
        #expect(session.title == "npm")
        session.exitStatus = .init(code: 1)
        #expect(session.title == "Exited")
    }

    @Test func homeIsShownAsTilde() {
        let session = Session()
        session.directory = NSHomeDirectory()
        session.processName = "zsh"
        #expect(session.title == "~")
        #expect(session.abbreviatedDirectory == "~")
    }

    @Test func tracksCommandsFromIntegrationEvents() {
        let session = Session()
        #expect(!session.integrated)
        let start = Date(timeIntervalSince1970: 100)
        session.apply(.commandStarted("make test"), at: start)
        #expect(session.integrated)
        #expect(session.running == .init(command: "make test", started: start))
        session.apply(.commandFinished(exitCode: 2, duration: 1.5))
        #expect(session.running == nil)
        #expect(session.lastCommand == .init(command: "make test", exitCode: 2, duration: 1.5))
    }

    @Test func aFinishWithoutAStartHasNoCommandText() {
        let session = Session()
        session.apply(.commandFinished(exitCode: 0, duration: 0.1))
        #expect(session.lastCommand?.command == "")
    }
}

@Suite("Settings window")
@MainActor
struct SettingsWindowTests {
    /// Regression: the window sized itself to its full content and ran off the screen instead of scrolling.
    @Test func fitsOnScreenAndCanBeResized() throws {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: "codec.settings-tests.\(UUID())"))
        let window = SettingsView.makeWindow(preferences: Preferences(defaults: defaults), sounds: FakeSounds())
        defer { window.close() }
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        #expect(window.styleMask.contains(.resizable))
        #expect(window.frame.height <= screen)
        #expect(window.frame.height <= 720)
    }
}

@Suite("Prompt sample")
@MainActor
struct PromptSampleTests {
    @Test func usesThisMacsDetails() {
        let sample = PromptConfiguration.Sample.current(now: Date(timeIntervalSince1970: 0))
        #expect(sample.user == NSUserName())
        #expect(sample.directory.hasPrefix(NSHomeDirectory()))
        #expect(!sample.host.isEmpty && !sample.host.contains("."))
        #expect(!sample.time.isEmpty && !sample.date.isEmpty)
    }
}

@Suite("Main menu")
@MainActor
struct MainMenuTests {
    private func item(_ menu: NSMenu, path: [String]) -> NSMenuItem? {
        var current: NSMenu? = menu
        var found: NSMenuItem?
        for title in path {
            found = current?.items.first { $0.title == title }
            current = found?.submenu
        }
        return found
    }

    @Test func offersCommandLineEditingShortcuts() throws {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let cut = try #require(item(menu, path: ["Edit", "Cut"]))
        #expect(cut.keyEquivalent == "x" && cut.keyEquivalentModifierMask == .command)
        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        let expected: [(String, String, NSEvent.ModifierFlags)] = [
            ("Move to Start", left, .command), ("Move to End", right, .command),
            ("Select to Start", left, [.command, .shift]), ("Select to End", right, [.command, .shift]),
            ("Delete to Start", "\u{8}", .command),
        ]
        for (title, key, modifiers) in expected {
            let entry = try #require(item(menu, path: ["Edit", "Command Line", title]), "\(title)")
            #expect(entry.keyEquivalent == key && entry.keyEquivalentModifierMask == modifiers, "\(title)")
        }
    }

    @Test func findsInAllPanesWithShiftCommandF() throws {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let find = try #require(item(menu, path: ["Edit", "Find", "Find in All Panes…"]))
        #expect(find.keyEquivalent == "f" && find.keyEquivalentModifierMask == [.command, .shift])
        #expect(find.action == #selector(TerminalWindowController.findInAllPanes(_:)))
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        #expect(all(menu).filter { $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask == [.command, .shift] }.count == 1)
    }

    @Test func splitsTowardAnArrowWithControlCommand() throws {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let shell = try #require(menu.items.first { $0.title == "Shell" }?.submenu)
        func key(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }
        let expected: [(String, String, NSEvent.ModifierFlags)] = [
            ("Split Left", key(NSLeftArrowFunctionKey), [.command, .control]),
            ("Split Right", "d", .command),
            ("Split Up", key(NSUpArrowFunctionKey), [.command, .control]),
            ("Split Down", "d", [.command, .shift]),
        ]
        for (title, key, modifiers) in expected {
            let entry = try #require(shell.items.first { $0.title == title && !$0.isHidden }, "\(title)")
            #expect(entry.keyEquivalent == key && entry.keyEquivalentModifierMask == modifiers, "\(title)")
        }
        let hidden = shell.items.filter(\.isHidden)
        #expect(hidden.map(\.title) == ["Split Right", "Split Down"])
        #expect(hidden.map(\.keyEquivalent) == [key(NSRightArrowFunctionKey), key(NSDownArrowFunctionKey)])
        #expect(hidden.allSatisfy { $0.keyEquivalentModifierMask == [.command, .control] && $0.allowsKeyEquivalentWhenHidden })
    }
}
