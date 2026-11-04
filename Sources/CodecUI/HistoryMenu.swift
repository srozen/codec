import SwiftUI
import AppKit
import CodecCore

/// Where ↑ has got to in the history: the commands it walks through, newest first, and the one on
/// the command line now.
@MainActor
final class HistoryMenuModel: ObservableObject {
    /// What was on the line before ↑, to put back on the way out.
    let typed: String
    @Published private(set) var items: [HistoryItem]
    @Published private(set) var selection = 0

    /// Nil when nothing in the history matches what was typed.
    init?(typed: String, items: [HistoryItem]) {
        guard !items.isEmpty else { return nil }
        self.typed = typed
        self.items = items
    }

    var command: String { items[selection].command }

    /// One step back in time. False at the oldest.
    func older() -> Bool {
        guard selection + 1 < items.count else { return false }
        selection += 1
        return true
    }

    /// One step forward. False at the newest: next is what was typed.
    func newer() -> Bool {
        guard selection > 0 else { return false }
        selection -= 1
        return true
    }

    func select(_ index: Int) {
        if items.indices.contains(index) { selection = index }
    }

    /// Takes a command out of the list. False when that leaves nothing.
    func remove(_ command: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.command == command }) else { return true }
        items.remove(at: index)
        if index < selection || selection == items.count { selection = max(selection - 1, 0) }
        return !items.isEmpty
    }
}

/// The ↑ menu, above the prompt with the newest command nearest it. It never takes the keyboard:
/// the window controller moves it with ↑ and ↓, and every other key goes on to the command line,
/// which already holds the highlighted command.
struct HistoryMenuView: View {
    @ObservedObject var model: HistoryMenuModel
    let theme: CodecTheme
    let codeFont: NSFont
    var onPick: (Int) -> Void
    var onForget: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.items.enumerated()).reversed(), id: \.element.id) { index, item in
                            HistoryRow(item: item, compact: true, selected: index == model.selection, theme: theme, codeFont: codeFont)
                                .id(item.id)
                                .onTapGesture { onPick(index) }
                                .contextMenu {
                                    Button("Copy Command") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(item.command, forType: .string)
                                    }
                                    Divider()
                                    Button("Remove from History", role: .destructive) { onForget(item.command) }
                                }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 270)
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.selection) { _, new in
                    if model.items.indices.contains(new) { proxy.scrollTo(model.items[new].id) }
                }
            }
            Divider().opacity(0.5)
            HStack(spacing: 14) {
                KeyHint(key: "↑↓", label: "Browse")
                KeyHint(key: "↩", label: "Run")
                if !model.typed.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Matching “\(model.typed)”")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                KeyHint(key: "esc", label: "Cancel")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.03))
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}
