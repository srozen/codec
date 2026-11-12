import Testing
import AppKit
import CodecCore
@testable import CodecUI

@Suite("Pane", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct PaneTests {
    @Test func startsTheShellInTheRequestedDirectory() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane()
        defer { pane.shutDown() }
        #expect(pane.session.directory == env.directory.path)
        #expect(await waitUntil { pane.terminal.process.running })
        #expect(pane.session.processName == "sh")
        #expect(!pane.hasRunningJob)
    }

    @Test func buildsTheShellEnvironment() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane()
        defer { pane.shutDown() }
        let shellEnv = pane.shellEnvironment(shell: "/bin/zsh")
        #expect(shellEnv["TERM"] == "xterm-256color")
        #expect(shellEnv["COLORTERM"] == "truecolor")
        #expect(shellEnv["TERM_PROGRAM"] == "Codec")
        #expect(shellEnv["CODEC_PANE_ID"] == pane.session.id.uuidString)
        #expect(shellEnv["TMUX"] == nil)
        // Integration is off in this environment.
        #expect(shellEnv["CODEC_SHELL_INTEGRATION"] == nil)
    }

    @Test func colorsFileListingsUnlessTurnedOff() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane()
        defer { pane.shutDown() }
        let inherited = ProcessInfo.processInfo.environment
        let colored = pane.shellEnvironment(shell: "/bin/zsh")
        #expect(colored["CLICOLOR"] == inherited["CLICOLOR"] ?? "1")
        #expect(colored["LSCOLORS"] == inherited["LSCOLORS"] ?? FileListingColors.bsd)
        if inherited["LS_COLORS"] == nil {
            #expect(colored["LS_COLORS"]?.contains("*.swift=91") == true)
            // Shell scripts in the theme's accent.
            #expect(colored["LS_COLORS"]?.contains("*.sh=38;2;") == true)
        }
        #expect(colored["CODEC_EZA"] == "0")

        env.preferences.colorFileListings = false
        env.preferences.ezaForLs = true
        let plain = pane.shellEnvironment(shell: "/bin/zsh")
        #expect(plain["CLICOLOR"] == inherited["CLICOLOR"])
        #expect(plain["LS_COLORS"] == inherited["LS_COLORS"])
        #expect(plain["CODEC_EZA"] == "1")
    }

    @Test func addsIntegrationOnlyForZsh() throws {
        let env = try TestEnvironment(integration: true)
        defer { env.tearDown() }
        let pane = env.makePane()
        defer { pane.shutDown() }
        #expect(pane.shellEnvironment(shell: "/bin/zsh")["ZDOTDIR"]?.hasSuffix("integration/zsh") == true)
        #expect(pane.shellEnvironment(shell: "/bin/bash")["CODEC_SHELL_INTEGRATION"] == nil)
        env.preferences.shellIntegration = false
        #expect(pane.shellEnvironment(shell: "/bin/zsh")["CODEC_SHELL_INTEGRATION"] == nil)
    }

    // MARK: Bell

    @Test func bellInFrontShowsTheIndicator() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = FakeHost()
        host.inFront = true
        let pane = env.makePane(host: host)
        defer { pane.shutDown() }
        env.preferences.bell = .codecLock
        pane.handleBell()
        #expect(pane.session.alertToken != nil)
        #expect(env.sounds.played == [.lock])
        #expect(!pane.session.needsAttention)
        #expect(env.notifier.posted.isEmpty)
    }

    @Test func bellInTheBackgroundCallsForAttentionOnce() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = FakeHost()
        let pane = env.makePane(host: host)
        defer { pane.shutDown() }
        pane.handleBell()
        pane.handleBell()
        #expect(pane.session.needsAttention)
        #expect(pane.session.alertToken == nil)
        #expect(env.notifier.posted.count == 1)
        #expect(env.notifier.posted.first?.id == pane.session.id.uuidString)
        #expect(env.sounds.played == [.call])
        #expect(env.coordinator.attentionChanges == 1)
    }

    @Test func comingToFrontClearsAttention() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane(host: FakeHost())
        defer { pane.shutDown() }
        pane.handleBell()
        pane.session.unseenOutput = true
        pane.didComeToFront()
        #expect(!pane.session.needsAttention)
        #expect(!pane.session.unseenOutput)
        #expect(env.notifier.cleared == [pane.session.id.uuidString])
        #expect(env.coordinator.attentionChanges == 2)
    }

    @Test func silentBellDoesNothing() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane(host: FakeHost())
        defer { pane.shutDown() }
        env.preferences.bell = .silent
        pane.handleBell()
        #expect(!pane.session.needsAttention)
        #expect(env.sounds.played.isEmpty)
    }

    // MARK: Integration events

    @Test func longCommandsNotifyWhenInTheBackground() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = FakeHost()
        let pane = env.makePane(host: host)
        defer { pane.shutDown() }
        pane.handle(.commandStarted("cargo build --release"))
        pane.handle(.commandFinished(exitCode: 101, duration: 42))
        #expect(pane.session.lastCommand == .init(command: "cargo build --release", exitCode: 101, duration: 42))
        let notification = try #require(env.notifier.posted.first)
        #expect(notification.title == "“cargo” failed")
        #expect(notification.body.hasPrefix("Exit status 101 after 42.0 s"))
    }

    @Test func shortOrForegroundCommandsDontNotify() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = FakeHost()
        let pane = env.makePane(host: host)
        defer { pane.shutDown() }
        pane.handle(.commandStarted("ls"))
        pane.handle(.commandFinished(exitCode: 0, duration: 0.01))
        host.inFront = true
        pane.handle(.commandStarted("sleep 60"))
        pane.handle(.commandFinished(exitCode: 0, duration: 60))
        #expect(env.notifier.posted.isEmpty)
    }

    // MARK: Exits

    @Test func aCleanExitFinishesThePane() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = FakeHost()
        let pane = env.makePane(host: host)
        defer { pane.shutDown() }
        pane.processTerminated(source: pane.terminal, exitCode: 0)
        #expect(host.finished == 1)
        #expect(pane.session.exitStatus == nil)
    }

    @Test func aCrashKeepsThePaneWithABanner() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = FakeHost()
        let pane = env.makePane(host: host)
        defer { pane.shutDown() }
        pane.processTerminated(source: pane.terminal, exitCode: 137)
        #expect(host.finished == 0)
        #expect(pane.session.exitStatus == .init(code: 137))
        #expect(pane.view.isExitBannerVisible)
        #expect(env.sounds.played == [.exit])
        #expect(pane.session.title == "Exited")
    }

    @Test func keepOpenKeepsEvenCleanExits() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        env.preferences.exitBehavior = .keepOpen
        let host = FakeHost()
        let pane = env.makePane(host: host)
        defer { pane.shutDown() }
        pane.processTerminated(source: pane.terminal, exitCode: 0)
        #expect(host.finished == 0)
        #expect(pane.session.exitStatus == .init(code: 0))
        #expect(env.sounds.played.isEmpty)
    }

    @Test func restartingAfterAnExitStartsANewShell() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane(host: FakeHost())
        defer { pane.shutDown() }
        #expect(await waitUntil { pane.terminal.process.running })
        // Killed by a signal: not a clean exit, so the pane stays with its banner once SwiftTerm reports it.
        pane.terminal.terminate()
        #expect(await waitUntil { pane.session.exitStatus != nil })
        #expect(pane.view.isExitBannerVisible)
        pane.restart()
        #expect(pane.session.exitStatus == nil)
        #expect(!pane.view.isExitBannerVisible)
        #expect(await waitUntil { pane.terminal.process.running })
    }

    @Test func shuttingDownIsFinal() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = FakeHost()
        let pane = env.makePane(host: host)
        pane.shutDown()
        pane.shutDown()
        #expect(pane.isShutDown)
        #expect(await waitUntil { !pane.terminal.process.running })
        pane.processTerminated(source: pane.terminal, exitCode: 0)
        #expect(host.finished == 0)
        #expect(env.notifier.cleared == [pane.session.id.uuidString])
    }

    // MARK: Fonts

    @Test func zoomIsRelativeToTheConfiguredSize() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane()
        defer { pane.shutDown() }
        pane.changeFontSize(by: 2)
        #expect(pane.fontSize == 15)
        env.preferences.fontSize = 16
        pane.applyPreferences()
        #expect(pane.fontSize == 18)
        pane.resetFontSize()
        #expect(pane.fontSize == 16)
        pane.changeFontSize(by: -100)
        #expect(pane.fontSize == 7)
    }

    // MARK: Scrolling

    @Test func aWheelNotchScrollsAsFarAsTheSettingSays() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane()
        defer { pane.shutDown() }
        let window = makeTestWindow()
        defer { window.close() }
        window.contentView = pane.view
        #expect(await waitUntil { pane.terminal.process.running })
        pane.terminal.feed(text: (1...200).map { "line \($0)\r\n" }.joined())
        func top() -> Int? { pane.terminal.terminalContentSnapshot(region: .viewport)?.rows.first?.absoluteRow }
        func notchUp() throws {
            let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
            pane.terminal.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        }
        let bottom = try #require(top())
        #expect(bottom > 10)

        // Twice the system's rate unless set otherwise.
        try notchUp()
        #expect(top() == bottom - 2)
        env.preferences.scrollSpeed = 4
        pane.applyPreferences()
        try notchUp()
        #expect(top() == bottom - 6)
    }
}

@Suite("Pane context menu", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct PaneContextMenuTests {
    @Test func offersTheExpectedItems() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane(host: FakeHost())
        defer { pane.shutDown() }
        #expect(pane.contextMenu().itemTitles == [
            "Cut", "Copy", "Paste", "Select All", "Copy Output", "Select Output", "Split Left", "Split Right", "Split Up", "Split Down",
            "Find…", "Clear Buffer",
            "Restart Shell", "Open in Finder", "Copy Path", "Switch Branch…", "Close Pane",
        ])
    }

    @Test func copyNeedsASelection() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane(host: FakeHost())
        defer { pane.shutDown() }
        #expect(pane.contextMenu().item(titled: "Copy")?.isEnabled == false)
    }

    @Test func splitsAndClosesThroughTheHost() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = FakeHost()
        let pane = env.makePane(host: host)
        defer { pane.shutDown() }
        let menu = pane.contextMenu()
        for title in ["Split Left", "Split Right", "Split Up", "Split Down"] { menu.perform(title) }
        menu.perform("Close Pane")
        #expect(host.splits.map(\.axis) == [.horizontal, .horizontal, .vertical, .vertical])
        #expect(host.splits.map(\.before) == [true, false, true, false])
        #expect(host.closeRequests == 1)
    }

    @Test func copiesTheWorkingDirectory() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane(host: FakeHost())
        defer { pane.shutDown() }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pane.contextMenu().perform("Copy Path")
        #expect(pasteboard.string(forType: .string) == env.directory.path)
    }

    @Test func isWhatTheTerminalShowsOnRightClick() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane(host: FakeHost())
        defer { pane.shutDown() }
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(pane.terminal.menu(for: event)?.itemTitles.contains("Split Right") == true)
        #expect(pane.view.menu(for: event)?.itemTitles.contains("Close Pane") == true)
    }
}

@Suite("Running programs", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RunningProgramsPaneTests {
    @Test func countsBackgroundJobsAndForegroundPrograms() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane(host: FakeHost())
        defer { pane.shutDown() }
        #expect(await waitUntil { pane.terminal.process.running })
        try await Task.sleep(for: .milliseconds(300))
        #expect(pane.runningPrograms.isEmpty)
        #expect(!pane.hasRunningJob)

        // In the background: the shell is at its prompt, but closing would still kill it.
        pane.terminal.send(txt: "sleep 30 &\n")
        #expect(await waitUntil { pane.runningPrograms == ["sleep"] })
        #expect(pane.hasRunningJob)
        pane.terminal.send(txt: "kill %1\n")
        #expect(await waitUntil { pane.runningPrograms.isEmpty })

        // In the foreground.
        pane.terminal.send(txt: "sleep 30\n")
        #expect(await waitUntil { pane.runningPrograms == ["sleep"] })
    }
}
