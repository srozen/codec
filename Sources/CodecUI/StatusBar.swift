import SwiftUI
import AppKit
import CodecCore

/// The bar under the terminal: the focused pane's directory, branch and last command on the left,
/// system meters on the right.
struct StatusBar: View {
    static let height: CGFloat = 30

    @ObservedObject var model: WindowModel
    @ObservedObject var preferences: Preferences
    let monitor: SystemMonitor
    /// What explains failed commands, if anything.
    var explainer: (any FailureExplaining)? = nil
    /// Explains the pane's last command, which failed.
    var explain: (Pane) -> Void = { _ in }

    var body: some View {
        let theme = preferences.theme
        HStack(spacing: 6) {
            if let tab = model.selected {
                TabStatus(tab: tab, theme: theme, explain: canExplain ? explain : nil)
            }
            Spacer(minLength: 12)
            if preferences.showSystemStats {
                SystemMeters(monitor: monitor, theme: theme)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.dividerColor).frame(height: 1)
        }
    }

    /// Only where it would work: a Mac without Apple Intelligence gets no button that can't be used.
    private var canExplain: Bool {
        preferences.explainFailures && explainer?.availability == .available
    }
}

private struct TabStatus: View {
    @ObservedObject var tab: TerminalTab
    let theme: CodecTheme
    var explain: ((Pane) -> Void)?

    var body: some View {
        let pane = tab.focused
        SessionStatus(session: pane.session, theme: theme,
                      onBranchChanged: { [weak pane] in pane?.gitBranchDidChange() },
                      run: { [weak pane] command in pane?.runAtPrompt(command) ?? false },
                      explain: explain.map { explain in { [weak pane] in if let pane { explain(pane) } } })
            .id(ObjectIdentifier(pane))
    }
}

private struct SessionStatus: View {
    @ObservedObject var session: Session
    let theme: CodecTheme
    var onBranchChanged: () -> Void
    /// Runs a command at the pane's prompt; false when the shell is busy.
    var run: (String) -> Bool
    /// Explain, beside a failed command; nil when explaining isn't offered.
    var explain: (() -> Void)?
    @State private var choosingBranch = false

    var body: some View {
        HStack(spacing: 6) {
            Chip(systemImage: "folder", text: session.abbreviatedDirectory.isEmpty ? "~" : session.abbreviatedDirectory)
                .onTapGesture {
                    guard !session.directory.isEmpty else { return }
                    NSWorkspace.shared.open(URL(fileURLWithPath: session.directory))
                }
                .help("Open in Finder")
            if let branch = session.gitBranch {
                Button { choosingBranch.toggle() } label: {
                    Chip(systemImage: "arrow.triangle.branch", text: branch, detail: nil, trailingSymbol: "chevron.up.chevron.down")
                }
                .buttonStyle(.plain)
                .help("Switch branch")
                .accessibilityLabel("Branch \(branch). Switch branch")
                .popover(isPresented: $choosingBranch, arrowEdge: .top) {
                    BranchPicker(repository: GitRepository(directory: URL(fileURLWithPath: session.directory)), theme: theme,
                                 onSwitched: onBranchChanged, onDismiss: { choosingBranch = false })
                }
            }
            ToolchainStatus(session: session, theme: theme, run: run)
            commandStatus
        }
    }

    @ViewBuilder
    private var commandStatus: some View {
        if let running = session.running {
            TimelineView(.periodic(from: running.started, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(running.started)
                if let usual = running.usual {
                    // How far along it likely is, from how long it usually takes.
                    let over = elapsed > usual
                    Chip(systemImage: "circle.dotted", text: running.command,
                         detail: over ? "\(Formatting.seconds(elapsed)) · \(Formatting.seconds(elapsed - usual)) over"
                                      : "\(Formatting.seconds(elapsed)) / usually \(Formatting.seconds(usual))",
                         tint: over ? theme.warningColor : theme.accentColor, spinning: true, progress: elapsed / usual)
                        .help(over ? "Running \(Formatting.seconds(elapsed - usual)) longer than its usual \(Formatting.seconds(usual))"
                                   : "About \(Formatting.seconds(usual - elapsed)) left: it usually takes \(Formatting.seconds(usual))")
                } else {
                    Chip(systemImage: "circle.dotted", text: running.command,
                         detail: Formatting.duration(elapsed.rounded(.down)),
                         tint: theme.accentColor, spinning: true)
                }
            }
        } else if let last = session.lastCommand, !last.command.isEmpty {
            let failed = last.exitCode != 0
            Chip(systemImage: failed ? "xmark.circle.fill" : "checkmark.circle.fill",
                 text: last.command,
                 detail: failed ? "exit \(last.exitCode) · \(Formatting.duration(last.duration))" : Formatting.duration(last.duration),
                 tint: failed ? theme.alertColor : theme.accentColor)
            if failed, last.exitCode > 0, let explain {
                Button(action: explain) {
                    Label("Explain", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(theme.accentColor.opacity(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentColor)
                .help("Ask Apple Intelligence, on this Mac, why it failed")
            }
        }
    }
}

private struct Chip: View {
    let systemImage: String
    let text: String
    var detail: String?
    var tint: Color?
    var spinning = false
    var trailingSymbol: String?
    /// Fills a line along the bottom, in `tint`.
    var progress: Double?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint ?? .secondary)
                .symbolEffect(.rotate, isActive: spinning)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .frame(maxWidth: 320)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(alignment: .bottom) {
            if let progress {
                UsualProgressBar(fraction: progress, tint: tint ?? .accentColor)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - System meters

/// CPU, memory and network as codec-style readouts: rising signal bars and seven-segment digits.
/// Clicking opens Activity Monitor.
struct SystemMeters: View {
    @ObservedObject var monitor: SystemMonitor
    let theme: CodecTheme

    var body: some View {
        SystemMeterReadout(reading: monitor.reading, theme: theme)
            .contentShape(Rectangle())
            .onTapGesture(perform: Self.openActivityMonitor)
            .onAppear { monitor.start() }
            .onDisappear { monitor.stop() }
    }

    private static func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The meters for one reading. Every part has a fixed width, so changing values never shift the
/// status bar's layout.
struct SystemMeterReadout: View {
    let reading: SystemReading
    let theme: CodecTheme

    var body: some View {
        HStack(spacing: 14) {
            Meter(label: "CPU", level: reading.cpu, value: percent(reading.cpu), unit: "%", theme: theme)
                .help("CPU: \(percent(reading.cpu))% in use across all cores")
            Meter(label: "MEM", level: reading.memory, value: percent(reading.memory), unit: "%", theme: theme)
                .help("Memory: \(Formatting.bytes(reading.memoryUsed)) of \(Formatting.bytes(reading.memoryTotal)) in use")
            NetworkMeter(reading: reading, theme: theme)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("System load")
    }

    private func percent(_ fraction: Double) -> String {
        String(Int((min(max(fraction, 0), 1) * 100).rounded()))
    }
}

/// A three-digit seven-segment readout in a fixed frame.
private struct Readout: View {
    static let height: CGFloat = 10
    static let width = height * SevenSegment.aspectRatio(for: "888")

    let value: String
    let color: Color

    var body: some View {
        SevenSegmentDisplay(text: value.leftPadded(to: 3), color: color, ghost: 0.1, glow: 0.2)
            .frame(width: Self.width, height: Self.height, alignment: .trailing)
    }
}

/// A unit label in a fixed frame wide enough for the longest unit ("MB/s").
private struct UnitLabel: View {
    let text: String
    var width: CGFloat = 24

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }
}

private struct Meter: View {
    let label: String
    let level: Double
    let value: String
    let unit: String
    let theme: CodecTheme

    var body: some View {
        let color = level >= 0.85 ? theme.alertColor : theme.accentColor
        HStack(spacing: 5) {
            MeterLabel(text: label)
            SignalMeter(level: level, color: color, bars: 6)
                .frame(width: 20, height: 10)
            Readout(value: value, color: color.opacity(0.9))
            UnitLabel(text: unit, width: 8)
        }
        .animation(.easeOut(duration: 0.3), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value) \(unit)")
    }
}

private struct NetworkMeter: View {
    let reading: SystemReading
    let theme: CodecTheme

    var body: some View {
        let down = Formatting.byteRate(reading.downloadRate)
        let up = Formatting.byteRate(reading.uploadRate)
        HStack(spacing: 5) {
            MeterLabel(text: "NET")
            rate(symbol: "arrow.down", value: down.value, unit: down.unit)
            rate(symbol: "arrow.up", value: up.value, unit: up.unit)
        }
        .help("Network: \(down.value) \(down.unit) down, \(up.value) \(up.unit) up")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network \(down.value) \(down.unit) down, \(up.value) \(up.unit) up")
    }

    private func rate(symbol: String, value: String, unit: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(theme.accentColor.opacity(0.8))
                .frame(width: 8)
            Readout(value: value, color: theme.accentColor.opacity(0.9))
            UnitLabel(text: unit)
        }
    }
}

private struct MeterLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

extension String {
    /// Pads with spaces on the left so seven-segment readouts keep a steady width.
    func leftPadded(to width: Int) -> String {
        let digits = filter { $0 != "." }.count
        return digits >= width ? self : String(repeating: " ", count: width - digits) + self
    }
}
