import AppKit
import CodecCore

/// Looks for a newer Codec on GitHub: once a day on its own, if Settings allow it, and whenever Check
/// for Updates… is chosen. A check of its own only posts a notification, so nothing pops up over a
/// command being typed; the alert shows when you ask, or click the notification.
///
/// Installing downloads the new version and gets it ready beside this one; quitting puts it in place,
/// and Install and Relaunch quits for that and reopens Codec.
@MainActor
final class Updater {
    /// What a check found, for the alert.
    enum Finding: Equatable {
        case available(Release)
        case upToDate
        case failed(String)
        /// Downloaded and checked: quitting installs it.
        case readyToInstall(Release)
        /// Getting it ready or putting it in place didn't work; `download` gets it by hand instead.
        case installFailed(version: String, reason: String, download: URL)
    }

    /// Getting a release ready, for the progress window.
    struct Installation: Equatable {
        var release: Release
        var step: UpdatePreparation
    }

    /// The ID of the notification about a new version.
    static let notificationID = "codec.update"
    private static let lastCheckedKey = "UpdateLastChecked"
    private static let skippedKey = "UpdateSkippedVersion"
    private static let installFailureKey = "UpdateInstallFailure"

    let current: AppVersion
    /// Upgrading is then Homebrew's job, not a download.
    let installedWithHomebrew: Bool
    /// Signed with a Developer ID and notarized: macOS opens a downloaded version without asking.
    let notarized: Bool
    /// Puts a new version in place of this one; nil when Codec can't replace itself, and Homebrew or a
    /// download does it.
    let installer: (any UpdateInstalling)?
    /// The newer release the last check found; nil once it's skipped.
    private(set) var available: Release?
    /// Shows what a check you asked for found; the app shows an alert, tests keep it.
    var present: (Finding) -> Void = { _ in }
    /// The release being got ready, and how far along; nil when none is.
    private(set) var installation: Installation? {
        didSet { if installation != oldValue { installationChanged(installation) } }
    }
    /// Shows `installation`; the app shows a progress window.
    var installationChanged: (Installation?) -> Void = { _ in }
    /// Downloaded and checked, waiting for Codec to quit.
    private(set) var ready: (release: Release, app: URL)?
    /// Quitting reopens Codec once the new version is in place.
    var relaunchesAfterInstalling = false
    private var installTask: Task<Void, Never>?
    private let preferences: Preferences
    private let notifier: any Notifying
    private let source: any ReleaseSource
    private var checking = false
    private var schedule: Task<Void, Never>?

    init(current: AppVersion, preferences: Preferences, notifier: any Notifying,
         source: any ReleaseSource = GitHubReleases.codec, installedWithHomebrew: Bool = Homebrew.installedCodec(),
         notarized: Bool = CodeSigning.runningAppHasTeamIdentifier, installer: (any UpdateInstalling)? = SelfUpdate.forRunningApp()) {
        self.current = current
        self.notarized = notarized
        self.installer = installedWithHomebrew ? nil : installer
        self.preferences = preferences
        self.notifier = notifier
        self.source = source
        self.installedWithHomebrew = installedWithHomebrew
    }

    var lastChecked: Date? {
        get { preferences.stateDefaults.object(forKey: Self.lastCheckedKey) as? Date }
        set { preferences.stateDefaults.set(newValue, forKey: Self.lastCheckedKey) }
    }

    /// The tag of the release you chose to skip: Codec doesn't announce it again.
    var skippedTag: String? {
        get { preferences.stateDefaults.string(forKey: Self.skippedKey) }
        set { preferences.stateDefaults.set(newValue, forKey: Self.skippedKey) }
    }

    var menuTitle: String {
        if let version = ready?.release.version { return "Install Codec \(version) and Relaunch…" }
        return available?.version.map { "Update to Codec \($0)…" } ?? "Check for Updates…"
    }

    /// Looks a moment after launch, then whenever a day has passed: a terminal can stay open for weeks.
    /// First says if installing failed as Codec quit last time.
    func start() {
        if let failure = takeInstallFailure() {
            Task { [weak self] in self?.present(failure) }
        }
        schedule?.cancel()
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func stop() {
        schedule?.cancel()
        schedule = nil
    }

    func checkIfDue(now: Date = Date()) async {
        guard preferences.checkForUpdates, UpdatePolicy.isDue(lastChecked: lastChecked, now: now) else { return }
        await check(userInitiated: false)
    }

    /// Check for Updates…; once a version is being got ready, shows how far along that is instead.
    func checkNow() {
        if let ready { return present(.readyToInstall(ready.release)) }
        if let installation { return installationChanged(installation) }
        Task { await check(userInitiated: true) }
    }

    /// Asks for the latest release. When you asked, `present` gets what was found, skipped or not;
    /// otherwise a newer version you haven't skipped is announced with a notification.
    func check(userInitiated: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let finding: Finding
        do {
            let release = try await source.latest()
            lastChecked = Date()
            available = UpdatePolicy.isNewer(release, than: current) ? release : nil
            finding = available.map(Finding.available) ?? .upToDate
        } catch UpdateCheckError.noReleases {
            lastChecked = Date()
            available = nil
            finding = .upToDate
        } catch {
            Log.app.error("Couldn't check for updates: \(error.localizedDescription, privacy: .public)")
            finding = .failed(error.localizedDescription)
        }
        if userInitiated {
            notifier.clear(id: Self.notificationID)
            present(finding)
        } else if let available, available.tag != skippedTag, available != ready?.release, let version = available.version {
            notifier.post(id: Self.notificationID, title: "Codec \(version) is available",
                          body: "You have \(current). Click to see what’s new.")
        }
    }

    /// The notification was clicked.
    func showAvailable() {
        if let available { present(.available(available)) } else { checkNow() }
    }

    func skip(_ release: Release) {
        skippedTag = release.tag
        if available == release { available = nil }
    }

    // MARK: - Installing

    /// Downloads `release` and gets it ready to put in place of this copy, then says it's ready.
    func install(_ release: Release) {
        guard let installer, installTask == nil else { return }
        if let ready, ready.release == release { return present(.readyToInstall(release)) }
        installation = Installation(release: release, step: .downloading(nil))
        let report: @Sendable (UpdatePreparation) -> Void = { [weak self] step in
            Task { @MainActor in self?.progressed(release, step) }
        }
        installTask = Task { [weak self] in
            let finding: Finding?
            do {
                let app = try await installer.prepare(release, progress: report)
                self?.ready = (release, app)
                finding = .readyToInstall(release)
            } catch is CancellationError {
                finding = nil
            } catch let error as URLError where error.code == .cancelled {
                finding = nil
            } catch {
                Log.app.error("Couldn't get the update ready: \(error.localizedDescription, privacy: .public)")
                finding = .installFailed(version: release.version.map(String.init(describing:)) ?? release.tag,
                                         reason: error.localizedDescription, download: release.diskImage ?? release.page)
            }
            guard let self else { return }
            installTask = nil
            installation = nil
            if let finding { present(finding) }
        }
    }

    private func progressed(_ release: Release, _ step: UpdatePreparation) {
        guard installTask != nil, installation?.release == release else { return }
        installation = Installation(release: release, step: step)
    }

    func cancelInstalling() {
        installTask?.cancel()
    }

    /// Codec is quitting: puts the new version in place, then reopens Codec if that was asked for. When
    /// that fails, Codec says so as it opens next.
    func finishInstalling() {
        guard let ready, let installer else { return }
        self.ready = nil
        do {
            try installer.replace(with: ready.app)
        } catch {
            Log.app.error("Couldn't install the update: \(error.localizedDescription, privacy: .public)")
            preferences.stateDefaults.set([
                "version": ready.release.version.map(String.init(describing:)) ?? ready.release.tag,
                "reason": error.localizedDescription,
                "download": (ready.release.diskImage ?? ready.release.page).absoluteString,
            ], forKey: Self.installFailureKey)
        }
        if relaunchesAfterInstalling { installer.relaunch() }
    }

    private func takeInstallFailure() -> Finding? {
        guard let failure = preferences.stateDefaults.dictionary(forKey: Self.installFailureKey) as? [String: String] else { return nil }
        preferences.stateDefaults.removeObject(forKey: Self.installFailureKey)
        guard let version = failure["version"], let reason = failure["reason"],
              let download = failure["download"].flatMap(URL.init(string:)) else { return nil }
        return .installFailed(version: version, reason: reason, download: download)
    }

    // MARK: - Alert

    /// The alert for `finding`. For a new version, its first button installs it, its third skips it.
    func alert(for finding: Finding) -> NSAlert {
        let alert = NSAlert()
        switch finding {
        case .available(let release):
            alert.messageText = "Codec \(release.version.map(String.init(describing:)) ?? release.tag) is available"
            if installedWithHomebrew {
                alert.informativeText = "You have \(current). Codec came from Homebrew, so Homebrew upgrades it: Upgrade puts the command at the prompt for you to run, then reopen Codec."
            } else if installer != nil {
                alert.informativeText = "You have \(current). Install downloads the new version and puts it in place of this one when Codec relaunches."
            } else {
                alert.informativeText = "You have \(current). Download opens the disk image: drag Codec to Applications to replace this one, then reopen it."
                    + downloadWarning
            }
            if !release.notes.isEmpty { alert.accessoryView = Self.notesView(release.notes) }
            alert.addButton(withTitle: installedWithHomebrew ? "Upgrade" : installer != nil ? "Install" : "Download")
            alert.addButton(withTitle: "Remind Me Later")
            alert.addButton(withTitle: "Skip This Version")
        case .readyToInstall(let release):
            alert.messageText = "Codec \(release.version.map(String.init(describing:)) ?? release.tag) is ready to install"
            alert.informativeText = "Codec relaunches to finish, with your windows, tabs and splits. Or it installs the next time you quit."
            alert.addButton(withTitle: "Install and Relaunch")
            alert.addButton(withTitle: "Install on Quit")
        case .installFailed(let version, let reason, _):
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t install Codec \(version)"
            alert.informativeText = reason + " Download opens the disk image instead: drag Codec to Applications to replace this one."
                + downloadWarning
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
        case .upToDate:
            alert.messageText = "You’re up to date"
            alert.informativeText = "Codec \(current) is the newest version."
        case .failed(let reason):
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = reason
        }
        return alert
    }

    private var downloadWarning: String {
        notarized ? "" : " Codec isn’t notarized by Apple, so macOS stops the new version the first time: choose Open Anyway in System Settings › Privacy & Security."
    }

    /// Release notes, rendered from their Markdown, in a box that scrolls.
    static func notesView(_ markdown: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        scroll.borderType = .bezelBorder
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.textStorage?.setAttributedString(notes(markdown))
        return scroll
    }

    static func notes(_ markdown: String) -> NSAttributedString {
        let html = "<style>body { font-family: -apple-system; font-size: 12px; }</style>" + MarkdownRenderer().html(from: markdown)
        guard let data = html.data(using: .utf8),
              let text = try? NSMutableAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil) else {
            return NSAttributedString(string: markdown, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        }
        // HTML comes in black; follow the appearance instead.
        text.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: text.length))
        // A list item's text already starts with its bullet; a text view that draws the list's markers
        // too would show two.
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle, !style.textLists.isEmpty,
                  let plain = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            plain.textLists = []
            text.addAttribute(.paragraphStyle, value: plain, range: range)
        }
        while text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        return text
    }
}
