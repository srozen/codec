import Foundation

/// A report from Codec's shell integration, carried in OSC 6973.
public enum IntegrationEvent: Equatable, Sendable {
    /// The OSC code the integration scripts use.
    public static let oscCode = 6973

    /// A command line was submitted.
    case commandStarted(String)
    /// The command finished.
    case commandFinished(exitCode: Int32, duration: TimeInterval)

    /// Parses the payload after `ESC ] 6973 ;`, e.g. `exec;make test` or `done;1;2.5`.
    public init?(payload: String) {
        let parts = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let rest = String(parts[1])
        switch parts[0] {
        case "exec":
            self = .commandStarted(rest)
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

    /// A rate in bytes per second, scaled to fit a short readout: (`"1.2"`, `"MB/s"`).
    public static func byteRate(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(0, bytesPerSecond)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let text = value < 10 && unit > 0 ? String(format: "%.1f", value) : String(Int(value.rounded()))
        return (text, units[unit])
    }

    /// Bytes as a short size: `512 MB`, `12.4 GB`.
    public static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .memory)
    }
}
