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

    var body: some View {
        let theme = preferences.theme
        HStack(spacing: 6) {
            if let tab = model.selected {
                TabStatus(tab: tab, theme: theme)
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
}

private struct TabStatus: View {
    @ObservedObject var tab: TerminalTab
    let theme: CodecTheme

    var body: some View {
        SessionStatus(session: tab.focused.session, theme: theme)
            .id(ObjectIdentifier(tab.focused))
    }
}

private struct SessionStatus: View {
    @ObservedObject var session: Session
    let theme: CodecTheme

    var body: some View {
        HStack(spacing: 6) {
            Chip(systemImage: "folder", text: session.abbreviatedDirectory.isEmpty ? "~" : session.abbreviatedDirectory)
                .onTapGesture {
                    guard !session.directory.isEmpty else { return }
                    NSWorkspace.shared.open(URL(fileURLWithPath: session.directory))
                }
                .help("Open in Finder")
            if let branch = session.gitBranch {
                Chip(systemImage: "arrow.triangle.branch", text: branch)
                    .help("Git branch")
            }
            commandStatus
        }
    }

    @ViewBuilder
    private var commandStatus: some View {
        if let running = session.running {
            TimelineView(.periodic(from: running.started, by: 1)) { context in
                Chip(systemImage: "circle.dotted", text: running.command,
                     detail: Formatting.duration(context.date.timeIntervalSince(running.started).rounded(.down)),
                     tint: theme.accentColor, spinning: true)
            }
        } else if let last = session.lastCommand, !last.command.isEmpty {
            let failed = last.exitCode != 0
            Chip(systemImage: failed ? "xmark.circle.fill" : "checkmark.circle.fill",
                 text: last.command,
                 detail: failed ? "exit \(last.exitCode) · \(Formatting.duration(last.duration))" : Formatting.duration(last.duration),
                 tint: failed ? theme.alertColor : theme.accentColor)
        }
    }
}

private struct Chip: View {
    let systemImage: String
    let text: String
    var detail: String?
    var tint: Color?
    var spinning = false

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
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .frame(maxWidth: 320)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
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
        let reading = monitor.reading
        HStack(spacing: 14) {
            Meter(label: "CPU", level: reading.cpu, value: percent(reading.cpu), unit: "%", theme: theme)
                .help("CPU: \(percent(reading.cpu))% in use across all cores")
            Meter(label: "MEM", level: reading.memory, value: percent(reading.memory), unit: "%", theme: theme)
                .help("Memory: \(Formatting.bytes(reading.memoryUsed)) of \(Formatting.bytes(reading.memoryTotal)) in use")
            NetworkMeter(reading: reading, theme: theme)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: Self.openActivityMonitor)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("System load")
    }

    private func percent(_ fraction: Double) -> String {
        String(Int((fraction * 100).rounded()))
    }

    private static func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
            SevenSegmentDisplay(text: value.leftPadded(to: 3), color: color.opacity(0.9), ghost: 0.1, glow: 0.2)
                .frame(height: 10)
            Text(unit)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
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
            SevenSegmentDisplay(text: value.leftPadded(to: 3), color: theme.accentColor.opacity(0.9), ghost: 0.1, glow: 0.2)
                .frame(height: 10)
            Text(unit)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
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
