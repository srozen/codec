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

/// The pane's Python environment and tool versions in the status bar, a chip each; a click opens
/// where each comes from.
struct ToolchainStatus: View {
    @ObservedObject var session: Session
    let theme: CodecTheme
    /// Runs a command at the pane's prompt; false when the shell is busy.
    var run: (String) -> Bool
    @State private var showingDetails = false
    /// Tools past this many are counted in one chip, so the status bar keeps room for the command.
    static let chipLimit = 3

    var body: some View {
        let toolchain = session.toolchain
        if !toolchain.isEmpty {
            Button { showingDetails.toggle() } label: {
                HStack(spacing: 4) {
                    if let python = toolchain.python {
                        ToolChip(symbol: ToolSymbol.name(for: "python"),
                                 text: [python.version, python.label].compactMap { $0 }.joined(separator: " · "),
                                 tint: theme.accentColor)
                    }
                    let tools = shownTools(toolchain)
                    ForEach(tools.prefix(Self.chipLimit)) { tool in
                        ToolChip(symbol: tool.installed ? ToolSymbol.name(for: tool.name) : "exclamationmark.triangle.fill",
                                 text: "\(tool.name) \(tool.installed ? tool.version : tool.requested ?? tool.version)",
                                 tint: tool.installed ? nil : theme.warningColor)
                    }
                    if tools.count > Self.chipLimit {
                        // The rest are in the popover; a missing one still shows as a warning here.
                        let rest = tools.dropFirst(Self.chipLimit)
                        ToolChip(symbol: rest.allSatisfy(\.installed) ? "ellipsis" : "exclamationmark.triangle.fill",
                                 text: "+\(rest.count)", tint: rest.allSatisfy(\.installed) ? nil : theme.warningColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(toolchain.summary)
            .accessibilityLabel("Environment: \(toolchain.summary). Show details")
            .popover(isPresented: $showingDetails, arrowEdge: .top) {
                ToolchainDetails(toolchain: toolchain, theme: theme, directory: session.directory) { command in
                    if run(command) { showingDetails = false }
                }
            }
        }
    }

    /// mise's Python is hidden while a virtual environment is active: the environment's comes first on the PATH.
    private func shownTools(_ toolchain: Toolchain) -> [Toolchain.Tool] {
        toolchain.tools.filter { toolchain.python == nil || $0.name != "python" }
    }
}

private struct ToolChip: View {
    let symbol: String
    let text: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint ?? .secondary)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        // Versions are short and lose their meaning cut: the command's chip gives way instead.
        .fixedSize()
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
                section("Python environment") {
                    row(symbol: ToolSymbol.name(for: "python"), title: python.label, version: python.version,
                        detail: abbreviated(python.path),
                        note: python.activatedByCodec ? "Activated by Codec, while you’re in this project"
                                                      : "Activated outside Codec")
                }
            }
            if !toolchain.tools.isEmpty {
                section("mise") {
                    ForEach(toolchain.tools) { tool in
                        let shadowed = toolchain.python != nil && tool.name == "python"
                        row(symbol: tool.installed ? ToolSymbol.name(for: tool.name) : "exclamationmark.triangle.fill",
                            title: tool.name, version: tool.installed ? tool.version : tool.requested ?? tool.version,
                            detail: tool.source.map { abbreviated($0) + (tool.isGlobal() ? " · global" : "") },
                            note: note(for: tool, shadowed: shadowed),
                            warning: !tool.installed)
                    }
                }
                if !toolchain.missing.isEmpty {
                    Button("Install with mise", systemImage: "arrow.down.circle") { run("mise install") }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Runs “mise install” in this pane")
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private func note(for tool: Toolchain.Tool, shadowed: Bool) -> String? {
        if !tool.installed { return "Not installed: another version, or none, runs instead" }
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

/// Asks, at the top of a pane, whether to activate the virtual environment found where its shell is.
struct VenvBanner: View {
    @ObservedObject var session: Session
    @ObservedObject var preferences: Preferences
    /// The user's answer: allow, deny, or nil to put off deciding.
    var decide: (Toolchain.PythonEnvironment, VenvDecisions.Decision?) -> Void

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
                    Button("Never") { decide(venv, .deny) }
                        .buttonStyle(.glass)
                        .help("Don’t activate it, and don’t ask again")
                    Button("Activate") { decide(venv, .allow) }
                        .buttonStyle(.glassProminent)
                        .tint(theme.accentColor.opacity(0.8))
                        .help("Activate it now, and whenever you’re in this project")
                    Button { decide(venv, nil) } label: {
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
                .frame(maxWidth: 520)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .padding(10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: session.pendingVenv)
    }
}
