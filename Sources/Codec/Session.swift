import Foundation
import Combine

/// Hands out codec frequencies, one per open channel.
@MainActor
final class FrequencyBand {
    static let shared = FrequencyBand()

    /// The first few come from a certain support team's speed dial.
    private let presets = ["140.85", "141.12", "140.96", "141.80", "140.15", "141.52", "140.48", "141.20", "140.07", "141.37"]
    private var inUse: Set<String> = []

    func allocate() -> String {
        if let free = presets.first(where: { !inUse.contains($0) }) {
            inUse.insert(free)
            return free
        }
        while true {
            let candidate = String(format: "%.2f", Double.random(in: 140.00...141.99))
            if !inUse.contains(candidate) {
                inUse.insert(candidate)
                return candidate
            }
        }
    }

    func release(_ frequency: String) {
        inUse.remove(frequency)
    }
}

/// Observable state for one terminal channel, shared by the window chrome and the overlays.
@MainActor
final class Session: ObservableObject {
    enum Connection: Equatable {
        case tuning
        case live
        case lost(exitCode: Int32?)
    }

    let frequency: String

    @Published var connection: Connection = .tuning
    @Published var processName = ""
    @Published var directory = ""
    /// 0...1, how much output is flowing; drives the signal meters.
    @Published var signal: Double = 0
    /// Changes each time the "!" alert should fire.
    @Published var alertToken: UUID?
    @Published var alertAnchor: CGPoint = .zero
    /// A bell rang while this channel was in the background.
    @Published var incoming = false

    init(frequency: String) {
        self.frequency = frequency
    }

    var directoryName: String {
        guard !directory.isEmpty else { return "" }
        if directory == NSHomeDirectory() { return "~" }
        return (directory as NSString).lastPathComponent
    }

    /// Directory shortened with ~ for the band's subtitle.
    var abbreviatedDirectory: String {
        (directory as NSString).abbreviatingWithTildeInPath
    }

    /// What's on the channel right now: the foreground program, or the directory when the shell is idle.
    var label: String {
        if case .lost = connection { return "no signal" }
        if !processName.isEmpty, !isShell(processName) { return processName }
        return directoryName.isEmpty ? processName : directoryName
    }

    func isShell(_ name: String) -> Bool {
        let bare = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return ["zsh", "bash", "fish", "sh", "tcsh", "csh", "ksh", "nu", "elvish", "xonsh", "login"].contains(bare)
    }
}
