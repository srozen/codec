import Foundation
import Combine
import CodecCore

/// Observable state of one pane, shared by the tab bar, the status bar and the pane's overlays.
@MainActor
final class Session: ObservableObject {
    struct RunningCommand: Equatable {
        var command: String
        var started: Date
        /// How long it usually takes, when that's known.
        var usual: TimeInterval?
    }

    struct FinishedCommand: Equatable {
        var command: String
        var exitCode: Int32
        var duration: TimeInterval
    }

    struct ExitStatus: Equatable {
        /// Nil when the shell was killed by a signal or failed to start.
        var code: Int32?
    }

    let id = UUID()

    @Published var processName = ""
    @Published var directory = ""
    @Published var gitBranch: String?
    /// Changes each time the "!" bell indicator should fire.
    @Published var alertToken: UUID?
    @Published var alertAnchor: CGPoint = .zero
    /// Something happened while this pane wasn't in front: a bell, or a long command finished.
    @Published var needsAttention = false
    /// Output arrived while this pane wasn't in front.
    @Published var unseenOutput = false
    /// Set when the shell has exited and the pane is being kept open.
    @Published var exitStatus: ExitStatus?
    /// True once shell integration has reported in, so command status is known.
    @Published var integrated = false
    @Published var running: RunningCommand?
    /// Part of the command line is selected (the zsh region).
    @Published var commandLineSelection = false
    /// How many lines the prompt takes, its command line included.
    var promptLines = 1
    @Published var lastCommand: FinishedCommand?
    /// The Python environment and tool versions in effect, as the shell last reported them.
    @Published var toolchain = Toolchain()
    /// A virtual environment found where the shell is, waiting for the user to say whether to activate it.
    @Published var pendingVenv: Toolchain.PythonEnvironment?
    /// The TCP ports the programs started from the pane listen on, lowest first.
    @Published var listeningPorts: [ListeningPort] = []

    var abbreviatedDirectory: String {
        (directory as NSString).abbreviatingWithTildeInPath
    }

    var directoryName: String {
        guard !directory.isEmpty else { return "" }
        if directory == NSHomeDirectory() { return "~" }
        return (directory as NSString).lastPathComponent
    }

    /// Tab title: the running program, or the directory when the shell is idle.
    var title: String {
        if exitStatus != nil { return "Exited" }
        if let running { return CommandNames.program(of: running.command) }
        if !processName.isEmpty, !CommandNames.isShell(processName) { return processName }
        return directoryName.isEmpty ? processName : directoryName
    }

    /// Applies a shell integration report.
    func apply(_ event: IntegrationEvent, at date: Date = Date()) {
        integrated = true
        switch event {
        case .prompt(let lines):
            promptLines = lines
            commandLineSelection = false
        case .commandLineSelection(let active):
            commandLineSelection = active
        case .clipboard, .commandText, .historyFile, .historyRequest:
            break
        case .toolchain(let report):
            let toolchain = report.toolchain()
            if toolchain != self.toolchain { self.toolchain = toolchain }
            let pending = report.pending.map { Toolchain.PythonEnvironment.read(at: $0) ?? .init(path: $0) }
            if pending != pendingVenv { pendingVenv = pending }
        case .commandStarted(let command):
            commandLineSelection = false
            running = RunningCommand(command: command, started: date)
        case .commandFinished(let exitCode, let duration):
            lastCommand = FinishedCommand(command: running?.command ?? "", exitCode: exitCode, duration: duration)
            running = nil
        }
    }
}
