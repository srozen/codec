import AppKit
import Testing
import CodecCore
@testable import CodecUI

/// Answers with a fixed release, or an error, and counts how often it was asked.
private final class FakeReleases: ReleaseSource, @unchecked Sendable {
    var result: Result<Release, any Error>
    private(set) var requests = 0

    init(_ result: Result<Release, any Error>) {
        self.result = result
    }

    func latest() async throws -> Release {
        requests += 1
        return try result.get()
    }
}

@MainActor
@Suite("Updater", .serialized)
struct UpdaterTests {
    private static let page = URL(string: "https://github.com/srozen/codec/releases/tag/v0.3.0")!
    private let release = Release(tag: "v0.3.0", notes: "**Faster** splits", page: page,
                                  assets: [.init(name: "Codec-0.3.0.dmg", url: URL(string: "https://example.com/Codec-0.3.0.dmg")!)])

    private func makeUpdater(_ test: TestEnvironment, _ source: FakeReleases, version: String = "0.2.0",
                             homebrew: Bool = false, notarized: Bool = true) -> (Updater, () -> [Updater.Finding]) {
        let updater = Updater(current: AppVersion(version)!, preferences: test.preferences, notifier: test.notifier,
                              source: source, installedWithHomebrew: homebrew, notarized: notarized)
        var found: [Updater.Finding] = []
        updater.present = { found.append($0) }
        return (updater, { found })
    }

    @Test func announcesANewerVersionWithANotificationOnly() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let (updater, found) = makeUpdater(test, FakeReleases(.success(release)))

        await updater.checkIfDue()
        #expect(found().isEmpty)
        #expect(test.notifier.posted.map(\.id) == [Updater.notificationID])
        #expect(test.notifier.posted.first?.title == "Codec 0.3.0 is available")
        #expect(updater.menuTitle == "Update to Codec 0.3.0…")
        #expect(updater.lastChecked != nil)

        updater.showAvailable()
        #expect(found() == [.available(release)])
    }

    @Test func looksOnceADayAndNotWhenTurnedOff() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let source = FakeReleases(.success(release))
        let (updater, _) = makeUpdater(test, source)

        await updater.checkIfDue()
        await updater.checkIfDue()
        #expect(source.requests == 1)
        await updater.checkIfDue(now: Date().addingTimeInterval(UpdatePolicy.interval + 1))
        #expect(source.requests == 2)

        test.preferences.checkForUpdates = false
        updater.lastChecked = nil
        await updater.checkIfDue()
        #expect(source.requests == 2)
    }

    @Test func staysQuietAboutASkippedVersionUntilAsked() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let (updater, found) = makeUpdater(test, FakeReleases(.success(release)))

        updater.skip(release)
        await updater.check(userInitiated: false)
        #expect(test.notifier.posted.isEmpty)

        await updater.check(userInitiated: true)
        #expect(found() == [.available(release)])
        #expect(test.notifier.cleared == [Updater.notificationID])
    }

    @Test func saysWhenUpToDateOrWhenTheCheckFailed() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let source = FakeReleases(.success(release))
        let (updater, found) = makeUpdater(test, source, version: "0.3.0")

        await updater.check(userInitiated: true)
        #expect(found() == [.upToDate])
        #expect(updater.menuTitle == "Check for Updates…")

        source.result = .failure(UpdateCheckError.noReleases)
        await updater.check(userInitiated: true)
        #expect(found().last == .upToDate)

        source.result = .failure(UpdateCheckError.unexpectedResponse(503))
        await updater.check(userInitiated: true)
        #expect(found().last == .failed(UpdateCheckError.unexpectedResponse(503).localizedDescription))
        // Failing in the background says nothing.
        await updater.check(userInitiated: false)
        #expect(test.notifier.posted.isEmpty)
    }

    @Test func offersADownloadOrHomebrewWithTheReleaseNotes() throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let (download, _) = makeUpdater(test, FakeReleases(.success(release)))
        let alert = download.alert(for: .available(release))
        #expect(alert.buttons.map(\.title) == ["Download", "Remind Me Later", "Skip This Version"])
        let notes = try #require((alert.accessoryView as? NSScrollView)?.documentView as? NSTextView)
        #expect(notes.string == "Faster splits")
        #expect(!alert.informativeText.contains("Open Anyway"))

        let (unnotarized, _) = makeUpdater(test, FakeReleases(.success(release)), notarized: false)
        #expect(unnotarized.alert(for: .available(release)).informativeText.contains("Open Anyway"))

        let (homebrew, _) = makeUpdater(test, FakeReleases(.success(release)), homebrew: true)
        #expect(homebrew.alert(for: .available(release)).buttons.first?.title == "Upgrade")
        #expect(homebrew.alert(for: .upToDate).messageText == "You’re up to date")
    }

    @Test func putsCheckForUpdatesInTheAppMenu() {
        _ = NSApplication.shared
        let appMenu = MainMenu.build().items.first?.submenu
        #expect(appMenu?.item(titled: "Check for Updates…")?.action == #selector(AppDelegate.checkForUpdates(_:)))
    }
}
