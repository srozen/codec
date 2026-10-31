import SwiftUI
import CodecCore

struct PaletteCommand: Identifiable {
    /// Stable identifier, also used by tests.
    let id: String
    let title: String
    var shortcut: String?
    var systemImage: String
    var action: () -> Void
}

/// ⇧⌘P: fuzzy-search every command.
struct CommandPalette: View {
    let commands: [PaletteCommand]
    var onDismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var results: [PaletteCommand] {
        FuzzyMatch.rank(commands, by: query, key: \.title)
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($fieldFocused)
                    .onSubmit { run(results) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider().opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                            PaletteRow(command: command, selected: index == selection)
                                .id(command.id)
                                .onTapGesture {
                                    selection = index
                                    run(results)
                                }
                        }
                        if results.isEmpty {
                            Text("No matching commands")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 18)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 340)
                .onChange(of: selection) { _, new in
                    if results.indices.contains(new) { proxy.scrollTo(results[new].id) }
                }
            }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
        .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onExitCommand(perform: onDismiss)
        .onAppear { fieldFocused = true }
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func run(_ results: [PaletteCommand]) {
        guard results.indices.contains(selection) else { return }
        let command = results[selection]
        onDismiss()
        DispatchQueue.main.async { command.action() }
    }
}

private struct PaletteRow: View {
    let command: PaletteCommand
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.systemImage)
                .font(.system(size: 13))
                .frame(width: 20)
                .foregroundStyle(selected ? .primary : .secondary)
            Text(command.title)
                .font(.system(size: 13))
            Spacer()
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }
}
