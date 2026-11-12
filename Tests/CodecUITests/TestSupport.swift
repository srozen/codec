import AppKit
import CodecCore
@testable import CodecUI

let hasGit = FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
    || FileManager.default.fileExists(atPath: "/Applications/Xcode.app")

/// Runs git for test setup, with an identity so commits work anywhere.
func git(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "init.defaultBranch=main"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
}

@MainActor
final class FakeSounds: SoundPlaying {
    private(set) var played: [Sound] = []
    func play(_ sound: Sound) { played.append(sound) }
}

@MainActor
final class FakeNotifier: Notifying {
    private(set) var posted: [(id: String, title: String, body: String)] = []
    private(set) var cleared: [String] = []
    func post(id: String, title: String, body: String) { posted.append((id, title, body)) }
    func clear(id: String) { cleared.append(id) }
}

@MainActor
final class FakeCoordinator: AppCoordinating {
    private(set) var newWindows = 0
    private(set) var settingsShown = 0
    private(set) var attentionChanges = 0
    func newWindow() { newWindows += 1 }
    func showSettings() { settingsShown += 1 }
    func attentionDidChange() { attentionChanges += 1 }
    var terminalWindows: [TerminalWindowController] = []
}

@MainActor
final class FakeHost: PaneHost {
    var inFront = false
    private(set) var splits: [(axis: SplitAxis, before: Bool)] = []
    private(set) var closeRequests = 0
    private(set) var finished = 0
    func isInFront(_ pane: Pane) -> Bool { inFront }
    func split(_ pane: Pane, axis: SplitAxis, before: Bool) { splits.append((axis, before)) }
    func requestClose(_ pane: Pane) { closeRequests += 1 }
    func paneDidFinish(_ pane: Pane) { finished += 1 }
    private(set) var historyRequests: [(IntegrationEvent.HistoryRequest, String)] = []
    func showHistory(for pane: Pane, request: IntegrationEvent.HistoryRequest, typed: String) {
        historyRequests.append((request, typed))
    }
    private(set) var explained: [TimelineEntry] = []
    func explainFailure(of entry: TimelineEntry, in pane: Pane) { explained.append(entry) }
    private(set) var openedFiles: [URL] = []
    func openFile(_ url: URL, from pane: Pane) { openedFiles.append(url) }
    private(set) var findsInAllPanes = 0
    func findInAllPanes(from pane: Pane) { findsInAllPanes += 1 }
}

/// Never reports anything, so tests don't depend on the machine's load.
struct IdleSampler: SystemSampling {
    func sample() -> SystemSample? { nil }
}

/// An `AppEnvironment` with fakes, isolated preferences and a throwaway shell integration directory.
@MainActor
final class TestEnvironment {
    let environment: AppEnvironment
    let preferences: Preferences
    let sounds = FakeSounds()
    let notifier = FakeNotifier()
    let coordinator = FakeCoordinator()
    let directory: URL
    private let suiteName = "codec.ui-tests.\(UUID().uuidString)"

    /// - Parameters:
    ///   - shell: The shell panes run. `/bin/sh` keeps most tests fast and free of user configuration.
    ///   - integration: Whether to install and enable zsh integration.
    ///   - sampler: Where the system meters get their numbers; by default, nowhere.
    ///   - explainer: What explains failed commands; by default, nothing.
    init(shell: String = "/bin/sh", integration: Bool = false, sampler: any SystemSampling = IdleSampler(),
         explainer: (any FailureExplaining)? = nil) throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codec-ui-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: suiteName)!
        preferences = Preferences(defaults: defaults)
        preferences.shellPath = shell
        preferences.shellIntegration = integration
        preferences.codecSounds = false
        // Tests that run zsh set the prompt they look for in .zshrc; those about the Codec prompt pick it.
        preferences.prompt.style = .shell

        let shellIntegration = ShellIntegration(directory: directory.appendingPathComponent("integration"))
        if integration { try shellIntegration.install() }
        environment = AppEnvironment(preferences: preferences, sounds: sounds, notifier: notifier,
                                     systemMonitor: SystemMonitor(sampler: sampler, interval: sampler is IdleSampler ? 3600 : 1),
                                     shellIntegration: integration ? shellIntegration : nil,
                                     history: HistoryStore(logURL: directory.appendingPathComponent("history.jsonl")),
                                     intelFolder: directory.appendingPathComponent("intel"),
                                     savedPanesFolder: directory.appendingPathComponent("saved-panes"),
                                     explainer: explainer)
        environment.coordinator = coordinator
    }

    /// Removes the scratch directory and the preferences domain.
    func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func makePane(directory: String? = nil, host: FakeHost? = nil) -> Pane {
        let pane = Pane(directory: directory ?? self.directory.path, environment: environment)
        pane.host = host
        return pane
    }
}

/// A window for hosting views in tests. `isReleasedWhenClosed` is off: AppKit's default (on) makes
/// `close()` release the window a second time under ARC, which crashes later in an autorelease pool.
@MainActor
func makeTestWindow(size: NSSize = NSSize(width: 700, height: 400)) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}

/// How long `waitUntil` waits by default. CI's runners start zsh far more slowly than a Mac at a desk
/// while the whole suite runs at once: since macOS 26.7 there, a shell has taken more than 15 seconds
/// to show its first prompt. Waits end as soon as their condition holds, so the longer limit only
/// costs time when a test fails.
let defaultWait: Duration = ProcessInfo.processInfo.environment["CI"] == nil ? .seconds(15) : .seconds(60)

/// Polls `condition` while letting the main queue run, until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: Duration = defaultWait, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

extension NSMenu {
    var itemTitles: [String] { items.filter { !$0.isSeparatorItem }.map(\.title) }

    func item(titled title: String) -> NSMenuItem? {
        items.first { $0.title == title }
    }

    /// Fires an item's action the way AppKit does when it's chosen.
    func perform(_ title: String) {
        guard let index = items.firstIndex(where: { $0.title == title }) else { return }
        performActionForItem(at: index)
    }
}
