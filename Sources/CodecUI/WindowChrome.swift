import SwiftUI
import AppKit
import CodecCore

/// State shared by a window's tab bar, status bar and command palette.
@MainActor
final class WindowModel: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var selectedID: UUID?
    @Published var paletteOpen = false
    @Published var fullScreen = false

    var selected: TerminalTab? { tabs.first { $0.id == selectedID } }
}

// MARK: - Tab bar

struct TabBar: View {
    static let height: CGFloat = 40

    @ObservedObject var model: WindowModel
    @ObservedObject var preferences: Preferences
    var onSelect: (TerminalTab) -> Void
    var onClose: (TerminalTab) -> Void
    var onNewTab: () -> Void
    var onPalette: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabButton(tab: tab, index: index, selected: tab.id == model.selectedID, theme: preferences.theme,
                              onSelect: { onSelect(tab) }, onClose: { onClose(tab) })
                }
            }
            .layoutPriority(1)

            BarIconButton(systemImage: "plus", help: "New Tab (⌘T)", action: onNewTab)
            Spacer(minLength: 24)
            BarIconButton(systemImage: "command", help: "Command Palette (⇧⌘P)", action: onPalette)
        }
        .padding(.leading, model.fullScreen ? 10 : 84)
        .padding(.trailing, 10)
        .frame(height: Self.height)
        .background {
            // Empty space behaves like a title bar: drag to move, double-click to zoom.
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .simultaneousGesture(TapGesture(count: 2).onEnded { titleBarDoubleClicked() })
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(preferences.theme.dividerColor).frame(height: 1)
        }
        .animation(.snappy(duration: 0.2), value: model.tabs.map(\.id))
    }
}

@MainActor
private func titleBarDoubleClicked() {
    guard let window = NSApp.keyWindow else { return }
    if UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") == "Minimize" {
        window.performMiniaturize(nil)
    } else {
        window.performZoom(nil)
    }
}

private struct TabButton: View {
    @ObservedObject var tab: TerminalTab
    let index: Int
    let selected: Bool
    let theme: CodecTheme
    var onSelect: () -> Void
    var onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        let session = tab.focused.session
        let attention = tab.panes.contains { $0.session.needsAttention }
        let unseen = !selected && tab.panes.contains { $0.session.unseenOutput }

        HStack(spacing: 6) {
            ZStack {
                if attention {
                    Circle().fill(theme.alertColor).frame(width: 6, height: 6)
                } else if unseen {
                    Circle().fill(theme.accentColor).frame(width: 6, height: 6)
                } else if tab.panes.count > 1 {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 12)

            Text(session.title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                if hovering || selected {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close Tab")
                } else if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 20)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(minWidth: 110, idealWidth: 190, maxWidth: 220)
        .frame(height: 28)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.clear)
                    .glassEffect(.regular.tint(theme.accentColor.opacity(0.08)), in: .rect(cornerRadius: 9))
            } else if hovering {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(session.abbreviatedDirectory)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct BarIconButton: View {
    let systemImage: String
    let help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

extension CodecTheme {
    var accentColor: Color { Color(nsColor: accent) }
    var alertColor: Color { Color(nsColor: alert) }
    var backgroundColor: Color { Color(nsColor: background) }
    var foregroundColor: Color { Color(nsColor: foreground) }
    var dividerColor: Color { Color(nsColor: divider) }
}
