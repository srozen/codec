import Foundation

/// A report from Codec's shell integration, carried in OSC 6973.
public enum IntegrationEvent: Equatable, Sendable {
    /// The OSC code the integration scripts use.
    public static let oscCode = 6973

    /// A prompt is showing: the shell is waiting at its command line, with the integration loaded.
    /// `lines` is how many lines the prompt takes, its command line included.
    case prompt(lines: Int)
    /// The command-line selection (the zsh region) appeared or went away.
    case commandLineSelection(Bool)
    /// The shell asks to put this text on the clipboard: what was copied or cut from the command line.
    case clipboard(String)
    /// A command line was submitted.
    case commandStarted(String)
    /// The command finished.
    case commandFinished(exitCode: Int32, duration: TimeInterval)
    /// The full text of the command that just started, all its lines, for the history.
    case commandText(String)
    /// Where the shell keeps its history (`$HISTFILE`).
    case historyFile(String)
    /// The user asked for history at the prompt: ↑ for the menu, ⌃R for the search, with what's typed.
    case historyRequest(HistoryRequest, typed: String)
    /// The Python environment and tool versions in effect changed (or a virtual environment was found
    /// that the user hasn't decided about).
    case toolchain(ToolchainReport)

    public enum HistoryRequest: String, Sendable {
        case menu, search
    }

    /// Parses the payload after `ESC ] 6973 ;`, e.g. `prompt`, `exec;make test` or `done;1;2.5`.
    public init?(payload: String) {
        if payload == "prompt" {
            self = .prompt(lines: 1)
            return
        }
        let parts = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let rest = String(parts[1])
        switch parts[0] {
        case "prompt":
            guard let lines = Int(rest), lines >= 1 else { return nil }
            self = .prompt(lines: lines)
        case "region":
            guard rest == "0" || rest == "1" else { return nil }
            self = .commandLineSelection(rest == "1")
        case "clipboard":
            // Base64, so any text survives the trip through an OSC string.
            guard let data = Data(base64Encoded: rest) else { return nil }
            self = .clipboard(String(decoding: data, as: UTF8.self))
        case "exec":
            self = .commandStarted(rest)
        case "command":
            guard let data = Data(base64Encoded: rest) else { return nil }
            self = .commandText(String(decoding: data, as: UTF8.self))
        case "histfile":
            guard !rest.isEmpty else { return nil }
            self = .historyFile(rest)
        case "history":
            let fields = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let request = HistoryRequest(rawValue: String(fields[0])),
                  let data = Data(base64Encoded: String(fields[1])) else { return nil }
            self = .historyRequest(request, typed: String(decoding: data, as: UTF8.self))
        case "toolchain":
            // `<venv>;<0|1 activated by Codec>;<pending venv>;<mise json>`, the text fields base64.
            let fields = rest.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, fields[1] == "0" || fields[1] == "1" else { return nil }
            var text: [String] = []
            for index in [0, 2, 3] {
                guard let data = Data(base64Encoded: fields[index]) else { return nil }
                text.append(String(decoding: data, as: UTF8.self))
            }
            self = .toolchain(ToolchainReport(virtualEnv: text[0].isEmpty ? nil : text[0], activatedByCodec: fields[1] == "1",
                                              pending: text[1].isEmpty ? nil : text[1], mise: text[2]))
        case "done":
            let fields = rest.split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let code = Int32(fields[0]),
                  let duration = TimeInterval(fields[1]), duration >= 0 else { return nil }
            self = .commandFinished(exitCode: code, duration: duration)
        default:
            return nil
        }
    }
}

/// Naming helpers for commands and processes.
public enum CommandNames {
    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "tcsh", "csh", "ksh", "nu", "elvish", "xonsh", "login"]
    private static let prefixes: Set<String> = ["sudo", "time", "exec", "nohup", "env", "command", "builtin", "nice"]

    /// The program a command line runs: `sudo FOO=1 /usr/bin/make test` → `make`.
    public static func program(of commandLine: String) -> String {
        let words = commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
        let program = words.first { word in
            !prefixes.contains(word) && !word.hasPrefix("-") && !isAssignment(word)
        }
        guard let program else { return commandLine.trimmingCharacters(in: .whitespaces) }
        return (program as NSString).lastPathComponent
    }

    /// Whether a process name is a shell. Login shells are reported with a leading "-".
    public static func isShell(_ processName: String) -> Bool {
        let bare = processName.hasPrefix("-") ? String(processName.dropFirst()) : processName
        return shells.contains(bare)
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

public enum Formatting {
    /// A compact human duration: `340 ms`, `2.5 s`, `3m 07s`, `1h 05m`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let total = Int(seconds)
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }

    /// A rate in bytes per second, scaled to fit a three-digit readout: (`"1.2"`, `"MB/s"`).
    /// The value never needs more than three digits, so readouts keep a fixed width.
    public static func byteRate(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        var unit = 0
        // Scale before rounding would reach 1000, so "999.7 B/s" becomes "1.0 KB/s", not "1000 B/s".
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let text = unit > 0 && value < 9.95 ? String(format: "%.1f", value) : String(Int(min(value, 999).rounded()))
        return (text, units[unit])
    }

    /// Bytes as a short size: `512 MB`, `12.4 GB`.
    public static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .memory)
    }
}
