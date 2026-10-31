import Foundation

/// What the bell does in the pane you're looking at.
public enum BellBehavior: String, CaseIterable, Identifiable, Sendable {
    case visual, codecLock, system, silent
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .visual: "Visual only"
        case .codecLock: "Visual + codec lock-on"
        case .system: "Visual + system alert"
        case .silent: "Nothing"
        }
    }
}

/// What happens to a pane when its shell exits.
public enum ExitBehavior: String, CaseIterable, Identifiable, Sendable {
    case closeIfClean, alwaysClose, keepOpen
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .closeIfClean: "Close the pane, unless the shell crashed"
        case .alwaysClose: "Always close the pane"
        case .keepOpen: "Keep the pane open"
        }
    }

    /// Whether to close the pane for this exit. `exitCode` is nil when the shell was killed by a signal;
    /// statuses of 128 and up also mean a signal.
    public func closesPane(exitCode: Int32?) -> Bool {
        switch self {
        case .alwaysClose: true
        case .keepOpen: false
        case .closeIfClean: exitCode.map { $0 < 128 } ?? false
        }
    }
}

public enum Sound: Sendable, Equatable {
    case call, lock, exit, system
}

/// Decides how Codec reacts to bells and finished commands.
public struct AttentionPolicy: Sendable, Equatable {
    public var bell: BellBehavior
    public var notifyInBackground: Bool
    public var longCommandThreshold: TimeInterval

    public init(bell: BellBehavior, notifyInBackground: Bool, longCommandThreshold: TimeInterval = 10) {
        self.bell = bell
        self.notifyInBackground = notifyInBackground
        self.longCommandThreshold = longCommandThreshold
    }

    public struct Reaction: Equatable, Sendable {
        /// Show the "!" at the cursor.
        public var indicator = false
        /// Mark the pane as needing attention (tab dot, Dock badge).
        public var markForAttention = false
        /// Post a notification.
        public var notify = false
        public var sound: Sound?

        public static let none = Reaction()
    }

    public func reactionToBell(paneInFront: Bool) -> Reaction {
        if bell == .silent { return .none }
        if paneInFront {
            switch bell {
            case .visual: return Reaction(indicator: true)
            case .codecLock: return Reaction(indicator: true, sound: .lock)
            case .system: return Reaction(indicator: true, sound: .system)
            case .silent: return .none
            }
        }
        return backgroundAttention
    }

    public func reactionToFinishedCommand(duration: TimeInterval, paneInFront: Bool) -> Reaction {
        guard !paneInFront, duration >= longCommandThreshold else { return .none }
        return backgroundAttention
    }

    private var backgroundAttention: Reaction {
        notifyInBackground
            ? Reaction(markForAttention: true, notify: true, sound: .call)
            : Reaction(markForAttention: true)
    }
}
