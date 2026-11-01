import Foundation

/// How long a command usually takes, from the times it ran before: so a running command can show how
/// far along it likely is, and a finished one how it compared.
public enum UsualDuration {
    /// Fewer runs than this don't make a usual time.
    public static let minimumRuns = 3
    /// The most recent runs considered: a build that got faster last month should show it.
    public static let recentRuns = 10
    /// Commands that usually take less than this aren't worth a progress bar.
    public static let minimumDuration: TimeInterval = 3
    /// When the slower runs take this many times as long as the faster ones (`git push`, depending on
    /// the network), there's no usual time to speak of.
    public static let maximumSpread = 2.5

    /// The usual time of `command` in `directory`: the median of its most recent clean runs there,
    /// or anywhere when it hasn't run there enough. Nil when there's no telling: too few runs, too
    /// quick, or too irregular. Failed and interrupted runs don't count; they end early.
    public static func of(_ command: String, in directory: String?, history: [HistoryEntry]) -> TimeInterval? {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        // Newest last in the history.
        let runs = history.filter {
            $0.source == .codec && $0.exitCode == 0 && $0.duration != nil
                && $0.command.trimmingCharacters(in: .whitespacesAndNewlines) == command
        }
        let here = runs.filter { $0.directory == directory }
        let chosen = here.count >= minimumRuns ? here : runs
        guard chosen.count >= minimumRuns else { return nil }
        let durations = chosen.suffix(recentRuns).compactMap(\.duration).sorted()
        let median = durations.count.isMultiple(of: 2)
            ? (durations[durations.count / 2 - 1] + durations[durations.count / 2]) / 2
            : durations[durations.count / 2]
        guard median >= minimumDuration else { return nil }
        // The middle of the runs, without the one that sat on a password prompt.
        let low = durations[durations.count / 4], high = durations[(durations.count * 3) / 4]
        guard low > 0, high / low <= maximumSpread else { return nil }
        return median
    }

    /// How a run compared with the usual time.
    public enum Comparison: Equatable, Sendable {
        case asUsual
        /// Took this many times as long.
        case slower(Double)
        /// Took this fraction of the time.
        case faster(Double)

        /// Within a third either way is as usual: runs vary that much on their own.
        public init(duration: TimeInterval, usual: TimeInterval) {
            let ratio = usual > 0 ? duration / usual : 1
            if ratio >= 1.33 {
                self = .slower(ratio)
            } else if ratio <= 0.67 {
                self = .faster(ratio)
            } else {
                self = .asUsual
            }
        }

        /// "1.6×", "½", for a short badge.
        public var multiplier: String {
            switch self {
            case .asUsual: return "as usual"
            case .slower(let ratio): return Self.format(ratio) + "×"
            case .faster(let ratio): return Self.format(ratio) + "×"
            }
        }

        private static func format(_ ratio: Double) -> String {
            ratio >= 10 ? String(Int(ratio.rounded())) : String(format: "%.1f", ratio)
        }
    }
}

extension Formatting {
    /// A duration to the second, for times that tick: `8 s`, `1m 36s`, `1h 05m`.
    public static func seconds(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }
}
