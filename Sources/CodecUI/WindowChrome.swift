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
    /// The tab whose name is being edited in the tab bar.
    @Published var renamingTabID: UUID?
    @Published var fileTreeVisible = false
    @Published var timelineVisible = false

    var selected: TerminalTab? { tabs.first { $0.id == selectedID } }
}

// MARK: - Tab bar

/// What the tab bar asks its window to do.
struct TabBarActions {
    var select: (TerminalTab) -> Void
    var close: (TerminalTab) -> Void
    var newTab: () -> Void
    var showPalette: () -> Void
    var toggleFileTree: () -> Void = {}
    var toggleTimeline: () -> Void = {}
    var beginRenaming: (TerminalTab) -> Void
    /// Ends an edit: a new name (blank resets it), or nil to cancel.
    var finishRenaming: (TerminalTab, String?) -> Void
}

struct TabBar: View {
    static let height: CGFloat = 40

    @ObservedObject var model: WindowModel
    @ObservedObject var preferences: Preferences
    let actions: TabBarActions

    var body: some View {
        HStack(spacing: 6) {
            BarIconButton(systemImage: "sidebar.left", help: model.fileTreeVisible ? "Hide File Tree (⇧⌘E)" : "Show File Tree (⇧⌘E)",
                          active: model.fileTreeVisible, action: actions.toggleFileTree)
            HStack(spacing: 4) {
                ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabButton(tab: tab, index: index, selected: tab.id == model.selectedID,
                              renaming: tab.id == model.renamingTabID, theme: preferences.theme, actions: actions)
                }
            }
            .layoutPriority(1)

            BarIconButton(systemImage: "plus", help: "New Tab (⌘T)", action: actions.newTab)
            Spacer(minLength: 24)
            BarIconButton(systemImage: "command", help: "Command Palette (⇧⌘P)", action: actions.showPalette)
            BarIconButton(systemImage: "sidebar.right", help: model.timelineVisible ? "Hide Commands (⇧⌘L)" : "Show Commands (⇧⌘L)",
                          active: model.timelineVisible, action: actions.toggleTimeline)
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

/// Answers the middle mouse button only; every other click goes through to the views below.
struct MiddleClickCatcher: NSViewRepresentable {
    var action: () -> Void

    final class CatcherView: NSView {
        var action: () -> Void = {}
        private var pressed = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged: super.hitTest(point)
            default: nil
            }
        }

        override func otherMouseDown(with event: NSEvent) {
            pressed = event.buttonNumber == 2
            if !pressed { super.otherMouseDown(with: event) }
        }

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
            // Like a button: it counts if the release is still over the tab.
            if pressed, bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
            pressed = false
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
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
    let renaming: Bool
    let theme: CodecTheme
    let actions: TabBarActions
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

            if renaming {
                TabNameEditor(initialName: tab.customTitle ?? "", placeholder: tab.automaticTitle,
                              onFinish: { actions.finishRenaming(tab, $0) })
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(tab.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ZStack {
                if hovering || selected {
                    Button(action: { actions.close(tab) }) {
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
        // A middle click closes the tab, as in browsers.
        .overlay(MiddleClickCatcher { actions.close(tab) })
        .onTapGesture { actions.select(tab) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { actions.beginRenaming(tab) })
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename Tab…") { actions.beginRenaming(tab) }
            if tab.customTitle != nil {
                Button("Reset Tab Name") { actions.finishRenaming(tab, "") }
            }
            Divider()
            Button("Close Tab") { actions.close(tab) }
        }
        .help(tab.customTitle == nil ? session.abbreviatedDirectory : "\(tab.automaticTitle) — \(session.abbreviatedDirectory)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Inline editor for a tab's name. Return saves, Escape cancels, clicking elsewhere saves.
/// A blank name goes back to the automatic title, shown as the placeholder.
private struct TabNameEditor: View {
    let placeholder: String
    var onFinish: (String?) -> Void
    @State private var text: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(initialName: String, placeholder: String, onFinish: @escaping (String?) -> Void) {
        self.placeholder = placeholder
        self.onFinish = onFinish
        _text = State(initialValue: initialName)
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .focused($focused)
            .onSubmit { finish(text) }
            .onExitCommand { finish(nil) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(text) }
            }
            .task { focused = true }
            .accessibilityLabel("Tab name")
    }

    private func finish(_ name: String?) {
        guard !finished else { return }
        finished = true
        onFinish(name)
    }
}

private struct BarIconButton: View {
    let systemImage: String
    let help: String
    var active = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(active ? 0.1 : hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .primary : .secondary)
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
