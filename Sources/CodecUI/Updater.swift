import AppKit
import CodecCore

/// Looks for a newer Codec on GitHub: once a day on its own, if Settings allow it, and whenever Check
/// for Updates… is chosen. A check of its own only posts a notification, so nothing pops up over a
/// command being typed; the alert shows when you ask, or click the notification.
@MainActor
final class Updater {
    /// What a check found, for the alert.
    enum Finding: Equatable {
        case available(Release)
        case upToDate
        case failed(String)
    }

    /// The ID of the notification about a new version.
    static let notificationID = "codec.update"
    private static let lastCheckedKey = "UpdateLastChecked"
    private static let skippedKey = "UpdateSkippedVersion"

    let current: AppVersion
    /// Upgrading is then Homebrew's job, not a download.
    let installedWithHomebrew: Bool
    /// Signed with a Developer ID and notarized: macOS opens a downloaded version without asking.
    let notarized: Bool
    /// The newer release the last check found; nil once it's skipped.
    private(set) var available: Release?
    /// Shows what a check you asked for found; the app shows an alert, tests keep it.
    var present: (Finding) -> Void = { _ in }
    private let preferences: Preferences
    private let notifier: any Notifying
    private let source: any ReleaseSource
    private var checking = false
    private var schedule: Task<Void, Never>?

    init(current: AppVersion, preferences: Preferences, notifier: any Notifying,
         source: any ReleaseSource = GitHubReleases.codec, installedWithHomebrew: Bool = Homebrew.installedCodec(),
         notarized: Bool = CodeSigning.runningAppHasTeamIdentifier) {
        self.current = current
        self.notarized = notarized
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
        available?.version.map { "Update to Codec \($0)…" } ?? "Check for Updates…"
    }

    /// Looks a moment after launch, then whenever a day has passed: a terminal can stay open for weeks.
    func start() {
        schedule?.cancel()
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func checkIfDue(now: Date = Date()) async {
        guard preferences.checkForUpdates, UpdatePolicy.isDue(lastChecked: lastChecked, now: now) else { return }
        await check(userInitiated: false)
    }

    /// Check for Updates…
    func checkNow() {
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
        } else if let available, available.tag != skippedTag, let version = available.version {
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

    // MARK: - Alert

    /// The alert for `finding`. For a new version, its first button installs it, its third skips it.
    func alert(for finding: Finding) -> NSAlert {
        let alert = NSAlert()
        switch finding {
        case .available(let release):
            alert.messageText = "Codec \(release.version.map(String.init(describing:)) ?? release.tag) is available"
            alert.informativeText = (installedWithHomebrew
                ? "You have \(current). Codec came from Homebrew, so Homebrew upgrades it: Upgrade puts the command at the prompt for you to run, then reopen Codec."
                : "You have \(current). Download opens the disk image: drag Codec to Applications to replace this one, then reopen it.")
                + (notarized ? "" : " Codec isn’t notarized by Apple, so macOS stops the new version the first time: choose Open Anyway in System Settings › Privacy & Security.")
            if !release.notes.isEmpty { alert.accessoryView = Self.notesView(release.notes) }
            alert.addButton(withTitle: installedWithHomebrew ? "Upgrade" : "Download")
            alert.addButton(withTitle: "Remind Me Later")
            alert.addButton(withTitle: "Skip This Version")
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
        while text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        return text
    }
}
