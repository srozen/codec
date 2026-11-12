import AppKit
import Combine
import CodecCore

/// Plays Codec's sound cues.
@MainActor
protocol SoundPlaying: AnyObject {
    func play(_ sound: Sound)
}

/// Posts and withdraws user notifications for panes.
@MainActor
protocol Notifying: AnyObject {
    func post(id: String, title: String, body: String)
    func clear(id: String)
}

/// App-level actions that windows and panes ask for.
@MainActor
protocol AppCoordinating: AnyObject {
    func newWindow()
    func showSettings()
    /// A pane's needs-attention state changed; refresh the Dock badge.
    func attentionDidChange()
    /// Every window, oldest first, for searching every pane's commands.
    var terminalWindows: [TerminalWindowController] { get }
}

/// The services a window and its panes depend on. The app builds one with the real implementations;
/// tests build one with fakes.
@MainActor
final class AppEnvironment {
    let preferences: Preferences
    let sounds: any SoundPlaying
    let notifier: any Notifying
    let systemMonitor: SystemMonitor
    /// The commands run in every window, for suggestions and search.
    let history: HistoryStore
    /// Nil when the scripts couldn't be installed; panes then run without integration.
    let shellIntegration: ShellIntegration?
    /// Where the user's own Intel is kept; projects keep theirs in `.codec/intel`.
    let intelFolder: URL
    /// What panes showed, kept between launches.
    let paneArchive: PaneArchive
    /// Tabs closed lately, for ⇧⌘T, from any window.
    let closedTabs = ClosedTabs()
    /// Explains failed commands; nil where there's nothing to do it with.
    let explainer: (any FailureExplaining)?
    weak var coordinator: (any AppCoordinating)?
    /// Sends once the prompt file has been rewritten, so panes waiting at a prompt can redraw it.
    let promptWritten = PassthroughSubject<Void, Never>()
    private var promptSync: AnyCancellable?

    init(preferences: Preferences, sounds: any SoundPlaying, notifier: any Notifying,
         systemMonitor: SystemMonitor, shellIntegration: ShellIntegration?, history: HistoryStore = HistoryStore(logURL: nil),
         intelFolder: URL = IntelLibrary.standardPersonalFolder, savedPanesFolder: URL = PaneArchive.standardFolder,
         explainer: (any FailureExplaining)? = nil) {
        self.intelFolder = intelFolder
        self.explainer = explainer
        paneArchive = PaneArchive(folder: savedPanesFolder)
        self.preferences = preferences
        self.sounds = sounds
        self.notifier = notifier
        self.systemMonitor = systemMonitor
        self.history = history
        self.shellIntegration = shellIntegration
        // Keep the prompt file in step with Settings; open zsh sessions read it at their next prompt.
        if let shellIntegration {
            // Chip colors come from the theme, so a theme change rewrites the prompt too.
            promptSync = preferences.$prompt.combineLatest(preferences.$themeID)
                .removeDuplicates { $0 == $1 }
                .sink { [weak self] configuration, themeID in
                    do {
                        let theme = CodecTheme.named(themeID)
                        try shellIntegration.writePrompt(configuration, chipFills: theme.promptChipFills,
                                                         tagColors: theme.promptTagColors, frameColor: theme.promptFrameColor)
                        MainActor.assumeIsolated { self?.promptWritten.send() }
                    } catch {
                        Log.app.error("Couldn't write the prompt: \(error.localizedDescription, privacy: .public)")
                    }
                }
        }
    }

    /// The environment of the running app.
    static func live() -> AppEnvironment {
        let preferences = Preferences.shared
        var integration = ShellIntegration.standard()
        do {
            try integration?.install()
        } catch {
            Log.app.error("Couldn't install shell integration: \(error.localizedDescription, privacy: .public)")
            integration = nil
        }
        let history = HistoryStore.standard()
        history.load()
        return AppEnvironment(
            preferences: preferences,
            sounds: CodecSound(preferences: preferences),
            notifier: Notifier(),
            systemMonitor: SystemMonitor(),
            shellIntegration: integration,
            history: history,
            explainer: OnDeviceExplainer())
    }
}

extension Preferences {
    func font(size: CGFloat? = nil) -> NSFont {
        let size = size ?? CGFloat(fontSize)
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var theme: CodecTheme { .named(themeID) }
}
