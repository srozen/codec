import SwiftUI
import AppKit
import CodecCore

/// What the user picked from the history.
enum HistoryChoice: Equatable {
    /// Put the command on the command line.
    case insert(String)
    /// Put it there and run it.
    case run(String)
    case copy(String)
}

/// The command history, searchable, with filters: ⌃R at the prompt, or ⌘Y. (↑ has its own menu,
/// `HistoryMenuView`.)
struct HistoryView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case all, here, failed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .here: "This Folder"
            case .failed: "Failed"
            }
        }
    }

    @ObservedObject var store: HistoryStore
    let theme: CodecTheme
    let codeFont: NSFont
    /// The focused pane's directory, to prefer and filter by.
    let directory: String?
    /// Whether there's a command line to put commands on; otherwise Return copies.
    let canInsert: Bool
    var onChoose: (HistoryChoice) -> Void
    var onDismiss: () -> Void

    @State private var query: String
    @State private var scope: Scope = .all
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    init(store: HistoryStore, theme: CodecTheme, codeFont: NSFont, directory: String?, canInsert: Bool,
         query: String, onChoose: @escaping (HistoryChoice) -> Void, onDismiss: @escaping () -> Void) {
        self.store = store
        self.theme = theme
        self.codeFont = codeFont
        self.directory = directory
        self.canInsert = canInsert
        self.onChoose = onChoose
        self.onDismiss = onDismiss
        _query = State(initialValue: query)
    }

    private var items: [HistoryItem] {
        let filter: HistoryFilter = switch scope {
        case .all: .all
        case .here: directory.map(HistoryFilter.directory) ?? .all
        case .failed: .failed
        }
        return store.history.items(matching: query, filter: filter, directory: directory, limit: 400)
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.5)
            scopePicker
            list(items)
            footer
        }
        .frame(width: 720)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: query) { selection = 0 }
        .onChange(of: scope) { selection = 0 }
        .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
        .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
        .onKeyPress(keys: [.return], phases: .down) { press in
            choose(items, run: press.modifiers.contains(.command))
            return .handled
        }
        .onKeyPress(.tab) { choose(items, run: false); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onKeyPress(keys: [.delete], phases: .down) { press in
            guard press.modifiers.contains(.command), items.indices.contains(selection) else { return .ignored }
            store.forget(items[selection].command)
            return .handled
        }
        .onExitCommand(perform: onDismiss)
        .onAppear { fieldFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search command history", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($fieldFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var scopePicker: some View {
        HStack {
            Picker("Show", selection: $scope) {
                ForEach(Scope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var countLabel: String {
        let count = items.count
        return count == 1 ? "1 command" : "\(count)\(count == 400 ? "+" : "") commands"
    }

    @ViewBuilder
    private func list(_ items: [HistoryItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if query.isEmpty, let header = dayHeader(at: index, in: items) {
                            Text(header)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? 4 : 10)
                                .padding(.bottom, 2)
                        }
                        HistoryRow(item: item, compact: false, selected: index == selection, theme: theme, codeFont: codeFont)
                            .id(item.id)
                            .onTapGesture { selection = index; choose(items, run: false) }
                            .contextMenu { rowMenu(item) }
                    }
                    if items.isEmpty {
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 440)
            .defaultScrollAnchor(.top)
            .onChange(of: selection) { _, new in
                if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
            }
        }
    }

    private var emptyMessage: String {
        if store.history.entries.isEmpty { return "Commands you run will show up here." }
        return query.isEmpty ? "Nothing here yet." : "No commands match “\(query)”."
    }

    /// "Today", "Yesterday"…, above the first command of each day.
    private func dayHeader(at index: Int, in items: [HistoryItem]) -> String? {
        let calendar = Calendar.current
        let date = items[index].latest.date
        if index > 0, calendar.isDate(items[index - 1].latest.date, inSameDayAs: date) { return nil }
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if date == .distantPast { return "Earlier" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    @ViewBuilder
    private func rowMenu(_ item: HistoryItem) -> some View {
        if canInsert {
            Button("Insert") { onChoose(.insert(item.command)) }
            Button("Run") { onChoose(.run(item.command)) }
            Divider()
        }
        Button("Copy Command") { onChoose(.copy(item.command)) }
        if let directory = item.latest.directory {
            Button("Copy Folder Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(directory, forType: .string)
            }
        }
        Divider()
        Button("Remove from History", role: .destructive) { store.forget(item.command) }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 14) {
            KeyHint(key: "↩", label: canInsert ? "Insert" : "Copy")
            if canInsert { KeyHint(key: "⌘↩", label: "Run") }
            KeyHint(key: "⌘⌫", label: "Remove")
            Spacer()
            KeyHint(key: "esc", label: "Close")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    private func choose(_ items: [HistoryItem], run: Bool) {
        guard items.indices.contains(selection) else { return }
        let command = items[selection].command
        onChoose(canInsert ? (run ? .run(command) : .insert(command)) : .copy(command))
    }
}

/// A key and what it does, for a footer.
struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(label)
        }
    }
}

/// One command: highlighted like the shell would color it, with where and how it last ran.
/// Compact, it leaves out how often, where and how long, and sits a little tighter.
struct HistoryRow: View {
    let item: HistoryItem
    let compact: Bool
    let selected: Bool
    let theme: CodecTheme
    let codeFont: NSFont

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(item.failed ? theme.alertColor : Color.clear)
                .frame(width: 6, height: 6)
                .help(item.failed ? "Exited with status \(item.latest.exitCode ?? 0)" : "")
            Text(command)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.count > 1, !compact {
                Text("×\(item.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
            }
            if !compact, let directory = item.latest.directory {
                Text((directory as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 190, alignment: .trailing)
            }
            if !compact, let duration = item.latest.duration, duration >= 1 {
                Text(Formatting.duration(duration)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            if item.latest.date != .distantPast {
                Text(Formatting.relativeTime(item.latest.date))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: compact ? 28 : 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.command + (item.failed ? ", failed" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The command colored as shell code, with the matched part marked, on one line.
    private var command: AttributedString {
        let text = item.command.replacingOccurrences(of: "\n", with: " ⏎ ")
        var attributed = AttributedString(text)
        attributed.font = .init(NSFont(descriptor: codeFont.fontDescriptor, size: 12.5) ?? codeFont)
        attributed.foregroundColor = theme.foregroundColor
        let utf16 = text.utf16
        for span in SyntaxHighlighter.spans(in: text, language: .shell) {
            guard let lower = utf16.index(utf16.startIndex, offsetBy: span.location, limitedBy: utf16.endIndex),
                  let upper = utf16.index(lower, offsetBy: span.length, limitedBy: utf16.endIndex),
                  let start = AttributedString.Index(lower, within: attributed),
                  let end = AttributedString.Index(upper, within: attributed) else { continue }
            attributed[start..<end].foregroundColor = Color(nsColor: theme.color(for: span.token))
        }
        if let match = item.match, !item.command.contains("\n"),
           match.upperBound <= attributed.characters.count {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: match.lowerBound)
            let end = attributed.index(attributed.startIndex, offsetByCharacters: match.upperBound)
            attributed[start..<end].underlineStyle = .single
            attributed[start..<end].font = .init(NSFont(descriptor: codeFont.fontDescriptor.withSymbolicTraits(.bold), size: 12.5) ?? codeFont)
        }
        return attributed
    }
}
