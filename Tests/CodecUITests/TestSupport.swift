import AppKit
import CodecCore
@testable import CodecUI

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
}

@MainActor
final class FakeHost: PaneHost {
    var inFront = false
    private(set) var splits: [SplitAxis] = []
    private(set) var closeRequests = 0
    private(set) var finished = 0
    func isInFront(_ pane: Pane) -> Bool { inFront }
    func split(_ pane: Pane, axis: SplitAxis) { splits.append(axis) }
    func requestClose(_ pane: Pane) { closeRequests += 1 }
    func paneDidFinish(_ pane: Pane) { finished += 1 }
    private(set) var historyRequests: [(IntegrationEvent.HistoryRequest, String)] = []
    func showHistory(for pane: Pane, request: IntegrationEvent.HistoryRequest, typed: String) {
        historyRequests.append((request, typed))
    }
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
    init(shell: String = "/bin/sh", integration: Bool = false) throws {
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

        let shellIntegration = ShellIntegration(directory: directory.appendingPathComponent("integration"))
        if integration { try shellIntegration.install() }
        environment = AppEnvironment(preferences: preferences, sounds: sounds, notifier: notifier,
                                     systemMonitor: SystemMonitor(sampler: IdleSampler(), interval: 3600),
                                     shellIntegration: integration ? shellIntegration : nil,
                                     history: HistoryStore(logURL: directory.appendingPathComponent("history.jsonl")),
                                     intelFolder: directory.appendingPathComponent("intel"))
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

/// Polls `condition` while letting the main queue run, until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(15), _ condition: () -> Bool) async -> Bool {
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
