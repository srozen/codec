import SwiftUI
import AppKit
import CodecCore

/// SF Symbols for the tools people use most; anything else gets a cube.
enum ToolSymbol {
    static func name(for tool: String) -> String {
        switch tool {
        case "python", "uv": "shippingbox"
        case "ruby": "diamond"
        case "node", "bun", "deno": "hexagon"
        case "go": "chevron.forward.2"
        case "rust": "gearshape"
        case "java": "cup.and.saucer"
        default: "cube"
        }
    }
}

/// The pane's Python environment and tool versions in the status bar: one chip saying how many there
/// are, so a project with many tools doesn't crowd out the folder and the command. A click lists them,
/// with where each comes from.
struct ToolchainStatus: View {
    @ObservedObject var session: Session
    let theme: CodecTheme
    /// Runs a command at the pane's prompt; false when the shell is busy.
    var run: (String) -> Bool
    @State private var showingDetails = false

    var body: some View {
        let toolchain = session.toolchain
        if !toolchain.isEmpty {
            let attention = !toolchain.needingAttention.isEmpty
            Button { showingDetails.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: attention ? "exclamationmark.triangle.fill" : "square.stack.3d.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(attention ? theme.warningColor : .secondary)
                    Text(Self.label(for: toolchain))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(attention ? theme.warningColor : .primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .fixedSize()
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(toolchain.summary)
            .accessibilityLabel("\(Self.label(for: toolchain)): \(toolchain.summary). Show details")
            .popover(isPresented: $showingDetails, arrowEdge: .top) {
                ToolchainDetails(toolchain: toolchain, theme: theme, directory: session.directory) { command in
                    if run(command) { showingDetails = false }
                }
            }
        }
    }

    /// `1 environment`, `8 environments`: the Python environment and each tool the popover lists.
    static func label(for toolchain: Toolchain) -> String {
        let count = toolchain.tools.count + (toolchain.python == nil ? 0 : 1)
        return count == 1 ? "1 environment" : "\(count) environments"
    }
}

/// Where the environment and each tool's version come from, and what's missing.
struct ToolchainDetails: View {
    let toolchain: Toolchain
    let theme: CodecTheme
    let directory: String
    var run: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let python = toolchain.python {
                section(python.kind == .conda ? "Conda environment" : "Python environment") {
                    row(symbol: ToolSymbol.name(for: "python"), title: python.label, version: python.version,
                        detail: abbreviated(python.path),
                        note: python.kind == .conda ? nil
                            : python.activatedByCodec ? "Activated by Codec, while you’re in this project" : "Activated outside Codec")
                }
            }
            ForEach(managers, id: \.self) { manager in
                section(manager) {
                    ForEach(toolchain.tools.filter { $0.manager == manager }) { tool in
                        let shadowed = toolchain.python != nil && tool.name == "python"
                        row(symbol: tool.needsAttention ? "exclamationmark.triangle.fill" : ToolSymbol.name(for: tool.name),
                            title: tool.name, version: tool.installed ? tool.version : tool.requested ?? tool.version,
                            detail: tool.source.map { abbreviated($0) + (tool.isGlobal() ? " · global" : "") },
                            note: note(for: tool, shadowed: shadowed),
                            warning: tool.needsAttention)
                    }
                }
            }
            if !commands.isEmpty {
                HStack(spacing: 6) {
                    ForEach(commands, id: \.command) { item in
                        Button(item.title, systemImage: item.symbol) { run(item.command) }
                            .help("Runs “\(item.command)” in this pane")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    /// The managers that picked a tool here, in the order their tools come.
    private var managers: [String] {
        toolchain.tools.map(\.manager).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// What can be run to get the versions asked for: install what's missing, switch to what's asked for.
    private var commands: [(title: String, symbol: String, command: String)] {
        var commands: [(title: String, symbol: String, command: String)] = []
        for tool in toolchain.tools where tool.needsAttention {
            let fix = tool.installed
                ? tool.switchCommand.map { (title: "Switch", symbol: "arrow.left.arrow.right", command: $0) }
                : tool.installCommand.map { (title: "Install", symbol: "arrow.down.circle", command: $0) }
            guard let fix, !commands.contains(where: { $0.command == fix.command }) else { continue }
            commands.append((title: "\(fix.title) with \(tool.manager)", symbol: fix.symbol, command: fix.command))
        }
        return commands
    }

    private func note(for tool: Toolchain.Tool, shadowed: Bool) -> String? {
        if !tool.installed { return "Not installed: another version, or none, runs instead" }
        if !tool.matchesRequest, let requested = tool.requested { return "In use, but \(requested) is asked for" }
        if shadowed { return "The Python environment’s comes first" }
        if let requested = tool.requested, requested != tool.version { return "Asked for \(requested)" }
        return nil
    }

    private func abbreviated(_ path: String) -> String {
        let base = URL(fileURLWithPath: directory).standardizedFileURL.path
        if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(symbol: String, title: String, version: String?, detail: String?, note: String?,
                     warning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warning ? theme.warningColor : theme.accentColor)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    if let version {
                        Text(version)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(warning ? theme.warningColor : .primary)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                if let note {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(warning ? theme.warningColor : .secondary)
                }
            }
        }
    }
}

/// The answers to whether to activate a virtual environment.
enum VenvAnswer: Equatable {
    /// Activate it now and whenever you're in the project, in every pane: remembered.
    case always
    /// Activate it now, in this pane, until you leave the project: nothing is remembered.
    case once
    /// Don't, and don't ask again: remembered.
    case never
    /// Don't for now; this pane won't ask about it again, others still do.
    case notNow
}

/// Asks, at the top of a pane, whether to activate the virtual environment found where its shell is.
struct VenvBanner: View {
    @ObservedObject var session: Session
    @ObservedObject var preferences: Preferences
    var decide: (Toolchain.PythonEnvironment, VenvAnswer) -> Void

    var body: some View {
        let theme = preferences.theme
        ZStack {
            if let venv = session.pendingVenv {
                HStack(spacing: 10) {
                    Image(systemName: ToolSymbol.name(for: "python"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Activate \(venv.label)’s Python environment?")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text([(venv.path as NSString).abbreviatingWithTildeInPath, venv.version.map { "Python \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    Button("Never") { decide(venv, .never) }
                        .buttonStyle(.glass)
                        .help("Don’t activate it, and don’t ask again")
                    Button("This Time") { decide(venv, .once) }
                        .buttonStyle(.glass)
                        .help("Activate it in this pane until you leave the project, and ask again next time")
                    Button("Always") { decide(venv, .always) }
                        .buttonStyle(.glassProminent)
                        .tint(theme.accentColor.opacity(0.8))
                        .help("Activate it now, and whenever you’re in this project, in every pane")
                    Button { decide(venv, .notNow) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Not now: ask again next time")
                    .accessibilityLabel("Not now")
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 600)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .padding(10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: session.pendingVenv)
    }
}

/// The answers about which virtual environments to activate, for Settings: each can be changed or
/// forgotten, and those that can't be found anymore are flagged. Follows answers given in panes.
@MainActor
final class VenvDecisionsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        var entry: VenvDecisions.Entry
        /// The project's name, as its environment records it, or its folder's.
        var name: String
        var status: VenvDecisions.Entry.Status
        var id: String { entry.id }
    }

    @Published private(set) var rows: [Row] = []
    let decisions: VenvDecisions?
    private var observer: NSObjectProtocol?

    init(decisions: VenvDecisions?) {
        self.decisions = decisions
        reload()
        observer = NotificationCenter.default.addObserver(forName: Pane.venvDecided, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Reads the answers again, and looks again for each environment on disk.
    func reload() {
        let rows = (decisions?.entries ?? []).map { entry in
            Row(entry: entry,
                name: Toolchain.PythonEnvironment.read(at: entry.path)?.label ?? (entry.project as NSString).lastPathComponent,
                status: entry.status())
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if rows != self.rows { self.rows = rows }
    }

    var missingCount: Int { rows.filter { $0.status != .present }.count }

    /// Changes an answer; panes in the project take it at their next prompt.
    func set(_ decision: VenvDecisions.Decision, for path: String) {
        change(path) { try $0.set(decision, for: path) }
    }

    /// Forgets an answer: Codec asks again next time.
    func forget(_ path: String) {
        change(path) { try $0.remove(path) }
    }

    func removeMissing() {
        let missing = rows.filter { $0.status != .present }.map(\.entry.path)
        guard let decisions, (try? decisions.removeMissing()) != nil else { return }
        reload()
        missing.forEach { NotificationCenter.default.post(name: Pane.venvDecided, object: $0) }
    }

    func forgetAll() {
        let paths = rows.map(\.entry.path)
        guard let decisions, (try? decisions.clear()) != nil else { return }
        reload()
        paths.forEach { NotificationCenter.default.post(name: Pane.venvDecided, object: $0) }
    }

    private func change(_ path: String, _ body: (VenvDecisions) throws -> Void) {
        guard let decisions else { return }
        do {
            try body(decisions)
        } catch {
            Log.app.error("Couldn't change the answer about \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return NSSound.beep()
        }
        // Reloads this too.
        NotificationCenter.default.post(name: Pane.venvDecided, object: path)
    }
}

/// The remembered answers in Settings › Shell, one row per project.
struct VenvDecisionsList: View {
    @ObservedObject var model: VenvDecisionsModel

    var body: some View {
        if model.rows.isEmpty {
            Text("No answers yet. Codec asks when you go into a project with a .venv.")
                .foregroundStyle(.secondary)
        }
        ForEach(model.rows) { row in
            HStack(spacing: 10) {
                Image(systemName: row.status == .present ? ToolSymbol.name(for: "python") : "exclamationmark.triangle.fill")
                    .foregroundStyle(row.status == .present ? Color.secondary : Color.orange)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).fontWeight(.medium)
                    Text((row.entry.project as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                    if let problem = Self.problem(row.status) {
                        Text(problem).font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                Picker("Answer for \(row.name)", selection: Binding(
                    get: { row.entry.decision },
                    set: { model.set($0, for: row.entry.path) })) {
                    Text("Activate").tag(VenvDecisions.Decision.allow)
                    Text("Never").tag(VenvDecisions.Decision.deny)
                }
                .labelsHidden()
                .fixedSize()
                Button { model.forget(row.entry.path) } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Forget this answer: Codec asks again next time")
                .accessibilityLabel("Forget the answer for \(row.name)")
            }
        }
        if !model.rows.isEmpty {
            HStack {
                Button(model.missingCount == 0 ? "Remove Missing" : "Remove Missing (\(model.missingCount))") { model.removeMissing() }
                    .disabled(model.missingCount == 0)
                    .help("Forget the answers about projects or environments that can’t be found")
                Spacer()
                Button("Forget All", role: .destructive) { model.forgetAll() }
            }
        }
    }

    static func problem(_ status: VenvDecisions.Entry.Status) -> String? {
        switch status {
        case .present: nil
        case .environmentMissing: "Its .venv isn’t there anymore"
        case .projectMissing: "Not found: moved, deleted, or on a disk that isn’t connected"
        }
    }
}
