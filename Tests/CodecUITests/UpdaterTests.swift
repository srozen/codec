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

/// Gets a release "ready" at once, or fails, and records what it was asked to do.
private final class FakeInstaller: UpdateInstalling, @unchecked Sendable {
    var failure: (any Error)?
    var replaceFailure: (any Error)?
    /// Holds `prepare` until it's let go, to look at the progress in between.
    var gate: CheckedContinuation<Void, Never>?
    var waits = false
    private(set) var replaced: [URL] = []
    private(set) var relaunched = 0
    let staged = URL(fileURLWithPath: "/tmp/staged/Codec.app")

    func prepare(_ release: Release, progress: @escaping @Sendable (UpdatePreparation) -> Void) async throws -> URL {
        progress(.downloading(0.5))
        if waits { await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        progress(.checking)
        if let failure { throw failure }
        return staged
    }

    func replace(with staged: URL) throws {
        if let replaceFailure { throw replaceFailure }
        replaced.append(staged)
    }

    func relaunch() { relaunched += 1 }
}

@MainActor
@Suite("Updater", .serialized)
struct UpdaterTests {
    private static let page = URL(string: "https://github.com/srozen/codec/releases/tag/v0.3.0")!
    private let release = Release(tag: "v0.3.0", notes: "**Faster** splits", page: page,
                                  assets: [.init(name: "Codec-0.3.0.dmg", url: URL(string: "https://example.com/Codec-0.3.0.dmg")!)])

    private func makeUpdater(_ test: TestEnvironment, _ source: FakeReleases, version: String = "0.2.0",
                             homebrew: Bool = false, notarized: Bool = true,
                             installer: FakeInstaller? = nil) -> (Updater, () -> [Updater.Finding]) {
        let updater = Updater(current: AppVersion(version)!, preferences: test.preferences, notifier: test.notifier,
                              source: source, installedWithHomebrew: homebrew, notarized: notarized, installer: installer)
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

        let (homebrew, _) = makeUpdater(test, FakeReleases(.success(release)), homebrew: true, installer: FakeInstaller())
        #expect(homebrew.installer == nil)
        #expect(homebrew.alert(for: .available(release)).buttons.first?.title == "Upgrade")
        #expect(homebrew.alert(for: .upToDate).messageText == "You’re up to date")

        // A copy that can replace itself installs; macOS doesn't stop what Codec downloaded itself.
        let (inPlace, _) = makeUpdater(test, FakeReleases(.success(release)), notarized: false, installer: FakeInstaller())
        let installAlert = inPlace.alert(for: .available(release))
        #expect(installAlert.buttons.map(\.title) == ["Install", "Remind Me Later", "Skip This Version"])
        #expect(!installAlert.informativeText.contains("Open Anyway"))
    }

    @Test func installsOnQuitOrRelaunchesIntoTheNewVersion() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let installer = FakeInstaller()
        installer.waits = true
        let (updater, found) = makeUpdater(test, FakeReleases(.success(release)), installer: installer)
        var shown: [Updater.Installation?] = []
        updater.installationChanged = { shown.append($0) }

        updater.install(release)
        #expect(await waitUntil { shown.last == Updater.Installation(release: release, step: .downloading(0.5)) })
        #expect(updater.menuTitle == "Check for Updates…")
        installer.gate?.resume()
        #expect(await waitUntil { found().last == .readyToInstall(release) })
        #expect(shown.contains(Updater.Installation(release: release, step: .checking)))
        #expect(shown.last == .some(nil))
        #expect(updater.menuTitle == "Install Codec 0.3.0 and Relaunch…")
        // Asking again shows it's ready rather than downloading it again.
        updater.checkNow()
        #expect(found().last == .readyToInstall(release))
        let alert = updater.alert(for: .readyToInstall(release))
        #expect(alert.buttons.map(\.title) == ["Install and Relaunch", "Install on Quit"])

        // Install on Quit: put in place, not reopened.
        updater.finishInstalling()
        #expect(installer.replaced == [installer.staged])
        #expect(installer.relaunched == 0)
        // Once only.
        updater.finishInstalling()
        #expect(installer.replaced.count == 1)

        installer.waits = false
        updater.install(release)
        #expect(await waitUntil { found().last == .readyToInstall(release) && found().count == 3 })
        updater.relaunchesAfterInstalling = true
        updater.finishInstalling()
        #expect(installer.replaced.count == 2)
        #expect(installer.relaunched == 1)
    }

    @Test func cancellingStopsTheDownloadQuietly() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let installer = FakeInstaller()
        installer.waits = true
        let (updater, found) = makeUpdater(test, FakeReleases(.success(release)), installer: installer)
        updater.install(release)
        #expect(await waitUntil { installer.gate != nil })
        updater.cancelInstalling()
        installer.gate?.resume()
        #expect(await waitUntil { updater.installation == nil })
        #expect(found().isEmpty)
        updater.finishInstalling()
        #expect(installer.replaced.isEmpty)
    }

    @Test func offersTheDownloadWhenInstallingFails() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let installer = FakeInstaller()
        installer.failure = SelfUpdateError.damaged
        let (updater, found) = makeUpdater(test, FakeReleases(.success(release)), installer: installer)
        updater.install(release)
        let failed = Updater.Finding.installFailed(version: "0.3.0", reason: SelfUpdateError.damaged.localizedDescription,
                                                   download: release.diskImage!)
        #expect(await waitUntil { found().last == failed })
        let alert = updater.alert(for: failed)
        #expect(alert.buttons.map(\.title) == ["Download", "Cancel"])
        #expect(alert.informativeText.hasPrefix(SelfUpdateError.damaged.localizedDescription))
    }

    /// Putting it in place happens as Codec quits, so it's the next launch that says it didn't work.
    @Test func saysAtTheNextLaunchWhenPuttingItInPlaceFailed() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let installer = FakeInstaller()
        installer.replaceFailure = SelfUpdateError.failed("Permission denied.")
        let (updater, found) = makeUpdater(test, FakeReleases(.success(release)), installer: installer)
        updater.install(release)
        #expect(await waitUntil { found().last == .readyToInstall(release) })
        updater.relaunchesAfterInstalling = true
        updater.finishInstalling()
        // Reopened all the same, on the version that's still there.
        #expect(installer.relaunched == 1)

        let (next, nextFound) = makeUpdater(test, FakeReleases(.success(release)), installer: installer)
        next.start()
        defer { next.stop() }
        #expect(await waitUntil { !nextFound().isEmpty })
        #expect(nextFound() == [.installFailed(version: "0.3.0", reason: "Permission denied.", download: release.diskImage!)])
        // Said once.
        let (later, laterFound) = makeUpdater(test, FakeReleases(.success(release)), installer: installer)
        later.start()
        defer { later.stop() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(laterFound().isEmpty)
    }

    /// Each item keeps the bullet written into its text, and no list a text view would draw a second one for.
    @Test func listsInTheReleaseNotesHaveOneBullet() {
        let notes = Updater.notes("Fixes:\n\n- **Splits** keep their size\n- Tabs reopen")
        #expect(notes.string == "Fixes:\n\t•\tSplits keep their size\n\t•\tTabs reopen")
        notes.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: notes.length)) { value, _, _ in
            #expect((value as? NSParagraphStyle)?.textLists.isEmpty ?? true)
        }
    }

    @Test func putsCheckForUpdatesInTheAppMenu() {
        _ = NSApplication.shared
        let appMenu = MainMenu.build().items.first?.submenu
        #expect(appMenu?.item(titled: "Check for Updates…")?.action == #selector(AppDelegate.checkForUpdates(_:)))
    }
}
