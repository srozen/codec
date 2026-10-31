import AppKit
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
}

/// The services a window and its panes depend on. The app builds one with the real implementations;
/// tests build one with fakes.
@MainActor
final class AppEnvironment {
    let preferences: Preferences
    let sounds: any SoundPlaying
    let notifier: any Notifying
    let systemMonitor: SystemMonitor
    /// Nil when the scripts couldn't be installed; panes then run without integration.
    let shellIntegration: ShellIntegration?
    weak var coordinator: (any AppCoordinating)?

    init(preferences: Preferences, sounds: any SoundPlaying, notifier: any Notifying,
         systemMonitor: SystemMonitor, shellIntegration: ShellIntegration?) {
        self.preferences = preferences
        self.sounds = sounds
        self.notifier = notifier
        self.systemMonitor = systemMonitor
        self.shellIntegration = shellIntegration
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
        return AppEnvironment(
            preferences: preferences,
            sounds: CodecSound(preferences: preferences),
            notifier: Notifier(),
            systemMonitor: SystemMonitor(),
            shellIntegration: integration)
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
