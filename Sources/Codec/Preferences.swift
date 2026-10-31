import AppKit
import Combine

enum BellSound: String, CaseIterable, Identifiable {
    case codec, system, silent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .codec: "Codec alert"
        case .system: "System alert"
        case .silent: "Silent"
        }
    }
}

enum ExitBehavior: String, CaseIterable, Identifiable {
    case closeIfClean, alwaysClose, keepOpen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .closeIfClean: "Close unless the signal is lost"
        case .alwaysClose: "Always close the channel"
        case .keepOpen: "Keep the channel open"
        }
    }
}

/// App-wide settings, persisted to UserDefaults. Any change posts `Preferences.didChange`.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    static let didChange = Notification.Name("CodecPreferencesDidChange")

    private let defaults = UserDefaults.standard

    @Published var themeID: String { didSet { store(themeID, "themeID") } }
    /// Empty means the system monospaced font (SF Mono).
    @Published var fontName: String { didSet { store(fontName, "fontName") } }
    @Published var fontSize: Double { didSet { store(fontSize, "fontSize") } }
    @Published var opacity: Double { didSet { store(opacity, "opacity") } }
    @Published var blur: Bool { didSet { store(blur, "blur") } }
    @Published var scanlines: Bool { didSet { store(scanlines, "scanlines") } }
    @Published var tuningSequence: Bool { didSet { store(tuningSequence, "tuningSequence") } }
    @Published var bellSound: BellSound { didSet { store(bellSound.rawValue, "bellSound") } }
    @Published var visualAlert: Bool { didSet { store(visualAlert, "visualAlert") } }
    @Published var incomingCalls: Bool { didSet { store(incomingCalls, "incomingCalls") } }
    @Published var optionAsMeta: Bool { didSet { store(optionAsMeta, "optionAsMeta") } }
    @Published var exitBehavior: ExitBehavior { didSet { store(exitBehavior.rawValue, "exitBehavior") } }
    /// Empty means the user's login shell.
    @Published var shellPath: String { didSet { store(shellPath, "shellPath") } }

    private init() {
        defaults.register(defaults: [
            "themeID": CodecTheme.codec.id,
            "fontName": "",
            "fontSize": 13.0,
            "opacity": 0.88,
            "blur": true,
            "scanlines": true,
            "tuningSequence": true,
            "bellSound": BellSound.codec.rawValue,
            "visualAlert": true,
            "incomingCalls": true,
            "optionAsMeta": true,
            "exitBehavior": ExitBehavior.closeIfClean.rawValue,
            "shellPath": "",
        ])
        themeID = defaults.string(forKey: "themeID")!
        fontName = defaults.string(forKey: "fontName")!
        fontSize = defaults.double(forKey: "fontSize")
        opacity = defaults.double(forKey: "opacity")
        blur = defaults.bool(forKey: "blur")
        scanlines = defaults.bool(forKey: "scanlines")
        tuningSequence = defaults.bool(forKey: "tuningSequence")
        bellSound = BellSound(rawValue: defaults.string(forKey: "bellSound")!) ?? .codec
        visualAlert = defaults.bool(forKey: "visualAlert")
        incomingCalls = defaults.bool(forKey: "incomingCalls")
        optionAsMeta = defaults.bool(forKey: "optionAsMeta")
        exitBehavior = ExitBehavior(rawValue: defaults.string(forKey: "exitBehavior")!) ?? .closeIfClean
        shellPath = defaults.string(forKey: "shellPath")!
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    var theme: CodecTheme { .named(themeID) }

    func font(size: CGFloat? = nil) -> NSFont {
        let size = size ?? CGFloat(fontSize)
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The shell to launch: the explicit setting, else the account's login shell.
    var resolvedShell: String {
        if !shellPath.isEmpty, FileManager.default.isExecutableFile(atPath: shellPath) {
            return shellPath
        }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}
