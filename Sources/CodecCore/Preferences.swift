import Foundation
import Combine

/// App settings, persisted to a `UserDefaults` store. Changes publish through `objectWillChange` and
/// post `Preferences.didChange` once the new value is stored.
@MainActor
public final class Preferences: ObservableObject {
    public static let shared = Preferences(defaults: .standard)
    public static let didChange = Notification.Name("CodecPreferencesDidChange")

    private let defaults: UserDefaults
    /// Where state that isn't a setting is kept (the file tree's width, say): the same store, without
    /// change notifications.
    public var stateDefaults: UserDefaults { defaults }

    @Published public var themeID: String { didSet { store(themeID, .themeID) } }
    /// Empty means the system monospaced font (SF Mono).
    @Published public var fontName: String { didSet { store(fontName, .fontName) } }
    @Published public var fontSize: Double { didSet { store(fontSize, .fontSize) } }
    @Published public var opacity: Double { didSet { store(opacity, .opacity) } }
    @Published public var blur: Bool { didSet { store(blur, .blur) } }
    @Published public var scanlines: Bool { didSet { store(scanlines, .scanlines) } }
    @Published public var dimInactivePanes: Bool { didSet { store(dimInactivePanes, .dimInactivePanes) } }
    @Published public var bell: BellBehavior { didSet { store(bell.rawValue, .bell) } }
    @Published public var notifyInBackground: Bool { didSet { store(notifyInBackground, .notifyInBackground) } }
    @Published public var codecSounds: Bool { didSet { store(codecSounds, .codecSounds) } }
    @Published public var paneSounds: Bool { didSet { store(paneSounds, .paneSounds) } }
    @Published public var soundVolume: Double { didSet { store(soundVolume, .soundVolume) } }
    @Published public var optionAsMeta: Bool { didSet { store(optionAsMeta, .optionAsMeta) } }
    @Published public var exitBehavior: ExitBehavior { didSet { store(exitBehavior.rawValue, .exitBehavior) } }
    @Published public var shellIntegration: Bool { didSet { store(shellIntegration, .shellIntegration) } }
    /// Empty means the user's login shell.
    @Published public var shellPath: String { didSet { store(shellPath, .shellPath) } }
    @Published public var showSystemStats: Bool { didSet { store(showSystemStats, .showSystemStats) } }
    @Published public var prompt: PromptConfiguration { didSet { storePrompt() } }
    /// Copies text to the clipboard as soon as it's selected.
    @Published public var copyOnSelect: Bool { didSet { store(copyOnSelect, .copyOnSelect) } }
    /// Shows the rest of a matching earlier command, dimmed, as you type (zsh).
    @Published public var suggestCommands: Bool { didSet { store(suggestCommands, .suggestCommands) } }
    /// ↑ opens the history menu and ⌃R the history search at the prompt (zsh).
    @Published public var historyKeys: Bool { didSet { store(historyKeys, .historyKeys) } }
    /// Tab completion that ignores case, matches inside names and forgives typos (zsh).
    @Published public var friendlyCompletion: Bool { didSet { store(friendlyCompletion, .friendlyCompletion) } }
    /// Colors file listings (`ls`, eza, completion lists) in the theme's palette, unless the
    /// user's own color settings say otherwise.
    @Published public var colorFileListings: Bool { didSet { store(colorFileListings, .colorFileListings) } }
    /// Makes `ls` run eza, with icons and folders first, when it's installed (zsh).
    @Published public var ezaForLs: Bool { didSet { store(ezaForLs, .ezaForLs) } }
    /// Keeps the commands you run, with where and how they ran, for the history.
    @Published public var recordHistory: Bool { didSet { store(recordHistory, .recordHistory) } }
    /// Opens the windows, tabs and splits from last time at launch.
    @Published public var restoreWindows: Bool { didSet { store(restoreWindows, .restoreWindows) } }
    /// With them, what each pane showed and the commands it ran.
    @Published public var restorePaneContents: Bool { didSet { store(restorePaneContents, .restorePaneContents) } }
    /// Shows how far along a running command likely is, from how long it usually takes.
    @Published public var showUsualDuration: Bool { didSet { store(showUsualDuration, .showUsualDuration) } }
    /// Offers to explain a failed command with Apple Intelligence, on this Mac.
    @Published public var explainFailures: Bool { didSet { store(explainFailures, .explainFailures) } }
    /// Asks GitHub once a day whether there's a newer Codec.
    @Published public var checkForUpdates: Bool { didSet { store(checkForUpdates, .checkForUpdates) } }

    /// Commands that run at least this long notify you when they finish in the background.
    public let longCommandThreshold: TimeInterval = 10

    private enum Key: String {
        case themeID, fontName, fontSize, opacity, blur, scanlines, dimInactivePanes, bell, notifyInBackground,
             codecSounds, paneSounds, soundVolume, optionAsMeta, exitBehavior, shellIntegration, shellPath,
             showSystemStats, prompt, copyOnSelect, suggestCommands, historyKeys, friendlyCompletion, colorFileListings,
             ezaForLs, recordHistory, restoreWindows, restorePaneContents, showUsualDuration, explainFailures, checkForUpdates
    }

    private static let factoryDefaults: [Key: Any] = [
        .themeID: "codec",
        .fontName: "",
        .fontSize: 13.0,
        .opacity: 0.9,
        .blur: true,
        .scanlines: false,
        .dimInactivePanes: true,
        .bell: BellBehavior.visual.rawValue,
        .notifyInBackground: true,
        .codecSounds: true,
        .paneSounds: false,
        .soundVolume: 0.6,
        .optionAsMeta: true,
        .exitBehavior: ExitBehavior.closeIfClean.rawValue,
        .shellIntegration: true,
        .shellPath: "",
        .showSystemStats: true,
        .copyOnSelect: false,
        .suggestCommands: true,
        .historyKeys: true,
        .friendlyCompletion: true,
        .colorFileListings: true,
        .ezaForLs: false,
        .recordHistory: true,
        .restoreWindows: true,
        .restorePaneContents: true,
        .showUsualDuration: true,
        .explainFailures: true,
        .checkForUpdates: true,
    ]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: Self.factoryDefaults.map { ($0.key.rawValue, $0.value) }))
        themeID = defaults.string(forKey: Key.themeID.rawValue) ?? "codec"
        fontName = defaults.string(forKey: Key.fontName.rawValue) ?? ""
        fontSize = Self.clamp(defaults.double(forKey: Key.fontSize.rawValue), 7...72, fallback: 13)
        opacity = Self.clamp(defaults.double(forKey: Key.opacity.rawValue), 0.3...1, fallback: 0.9)
        blur = defaults.bool(forKey: Key.blur.rawValue)
        scanlines = defaults.bool(forKey: Key.scanlines.rawValue)
        dimInactivePanes = defaults.bool(forKey: Key.dimInactivePanes.rawValue)
        bell = defaults.string(forKey: Key.bell.rawValue).flatMap(BellBehavior.init(rawValue:)) ?? .visual
        notifyInBackground = defaults.bool(forKey: Key.notifyInBackground.rawValue)
        codecSounds = defaults.bool(forKey: Key.codecSounds.rawValue)
        paneSounds = defaults.bool(forKey: Key.paneSounds.rawValue)
        soundVolume = Self.clamp(defaults.double(forKey: Key.soundVolume.rawValue), 0...1, fallback: 0.6)
        optionAsMeta = defaults.bool(forKey: Key.optionAsMeta.rawValue)
        exitBehavior = defaults.string(forKey: Key.exitBehavior.rawValue).flatMap(ExitBehavior.init(rawValue:)) ?? .closeIfClean
        shellIntegration = defaults.bool(forKey: Key.shellIntegration.rawValue)
        shellPath = defaults.string(forKey: Key.shellPath.rawValue) ?? ""
        showSystemStats = defaults.bool(forKey: Key.showSystemStats.rawValue)
        copyOnSelect = defaults.bool(forKey: Key.copyOnSelect.rawValue)
        suggestCommands = defaults.bool(forKey: Key.suggestCommands.rawValue)
        historyKeys = defaults.bool(forKey: Key.historyKeys.rawValue)
        friendlyCompletion = defaults.bool(forKey: Key.friendlyCompletion.rawValue)
        colorFileListings = defaults.bool(forKey: Key.colorFileListings.rawValue)
        ezaForLs = defaults.bool(forKey: Key.ezaForLs.rawValue)
        recordHistory = defaults.bool(forKey: Key.recordHistory.rawValue)
        restoreWindows = defaults.bool(forKey: Key.restoreWindows.rawValue)
        restorePaneContents = defaults.bool(forKey: Key.restorePaneContents.rawValue)
        showUsualDuration = defaults.bool(forKey: Key.showUsualDuration.rawValue)
        explainFailures = defaults.bool(forKey: Key.explainFailures.rawValue)
        checkForUpdates = defaults.bool(forKey: Key.checkForUpdates.rawValue)
        prompt = defaults.data(forKey: Key.prompt.rawValue)
            .flatMap { try? JSONDecoder().decode(PromptConfiguration.self, from: $0) } ?? .default
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        range.contains(value) ? value : fallback
    }

    private func storePrompt() {
        guard let data = try? JSONEncoder().encode(prompt) else { return }
        store(data, .prompt)
    }

    private func store(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public var attentionPolicy: AttentionPolicy {
        AttentionPolicy(bell: bell, notifyInBackground: notifyInBackground, longCommandThreshold: longCommandThreshold)
    }

    /// The shell to launch: the configured one if it's executable, else the account's login shell.
    public func resolvedShell(fileManager: FileManager = .default) -> String {
        if !shellPath.isEmpty, fileManager.isExecutableFile(atPath: shellPath) {
            return shellPath
        }
        return Self.loginShell
    }

    public nonisolated static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}
