import SwiftUI
import CodecCore

/// Loads a repository's branches and switches between them.
@MainActor
final class BranchSwitcher: ObservableObject {
    enum State: Equatable {
        case loading
        case ready
        case working(String)
        case failed(String)
    }

    @Published private(set) var branches: [GitBranch] = []
    @Published private(set) var state: State = .loading
    let repository: GitRepository

    init(repository: GitRepository) {
        self.repository = repository
    }

    func load() async {
        state = .loading
        do {
            branches = try await repository.branches()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Switches to `branch`. True when it worked; otherwise `state` holds git's explanation.
    func switchTo(_ branch: GitBranch) async -> Bool {
        await perform("Switching to \(branch.localName)…") { try await self.repository.switchTo(branch) }
    }

    func createBranch(_ name: String) async -> Bool {
        await perform("Creating \(name)…") { try await self.repository.createBranch(name) }
    }

    private func perform(_ message: String, _ work: @escaping () async throws -> Void) async -> Bool {
        state = .working(message)
        do {
            try await work()
            state = .ready
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    /// Branches matching `query`, local ones first; the order git gave (most recent first) is kept.
    func matches(_ query: String) -> [GitBranch] {
        FuzzyMatch.rank(branches, by: query, key: \.name)
    }
}

/// The popover behind the status bar's branch chip.
struct BranchPicker: View {
    @StateObject private var switcher: BranchSwitcher
    let theme: CodecTheme
    /// Called after the branch changed.
    var onSwitched: () -> Void
    var onDismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    init(repository: GitRepository, theme: CodecTheme, onSwitched: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        _switcher = StateObject(wrappedValue: BranchSwitcher(repository: repository))
        self.theme = theme
        self.onSwitched = onSwitched
        self.onDismiss = onDismiss
    }

    private enum Row: Identifiable {
        case branch(GitBranch)
        case create(String)
        var id: String {
            switch self {
            case .branch(let branch): branch.id
            case .create(let name): "create:\(name)"
            }
        }
    }

    private var rows: [Row] {
        var rows = switcher.matches(query).map(Row.branch)
        let name = query.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !switcher.branches.contains(where: { $0.localName == name }) {
            rows.append(.create(name))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                TextField("Switch to branch, or type a new name", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { choose(rows) }
            }
            .padding(12)

            Divider()

            content(rows)
                .frame(height: 260)

            if case .failed(let message) = switcher.state {
                Divider()
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(theme.alertColor)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(width: 380)
        .task { await switcher.load() }
        .onAppear { searchFocused = true }
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.upArrow) { move(-1, count: rows.count); return .handled }
        .onKeyPress(.downArrow) { move(1, count: rows.count); return .handled }
        .onExitCommand(perform: onDismiss)
    }

    @ViewBuilder
    private func content(_ rows: [Row]) -> some View {
        switch switcher.state {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .working(let message):
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .failed:
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, selected: index == selection)
                            .id(row.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = index
                                choose(rows)
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: selection) { _, new in
                    if rows.indices.contains(new) { proxy.scrollTo(rows[new].id) }
                }
                .overlay {
                    if rows.isEmpty {
                        Text(switcher.branches.isEmpty ? "No branches" : "No matching branches")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row, selected: Bool) -> some View {
        HStack(spacing: 8) {
            switch row {
            case .branch(let branch):
                Image(systemName: branch.isCurrent ? "checkmark" : branch.isRemote ? "cloud" : "arrow.triangle.branch")
                    .frame(width: 16)
                    .foregroundStyle(branch.isCurrent ? theme.accentColor : .secondary)
                Text(branch.name)
                    .font(.system(size: 13, design: .monospaced))
                    .fontWeight(branch.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(branch.lastCommit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .create(let name):
                Image(systemName: "plus").frame(width: 16).foregroundStyle(theme.accentColor)
                Text("Create branch “\(name)”").lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.22) : .clear))
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func choose(_ rows: [Row]) {
        guard rows.indices.contains(selection) else { return }
        let row = rows[selection]
        Task {
            let switched: Bool
            switch row {
            case .branch(let branch):
                if branch.isCurrent {
                    onDismiss()
                    return
                }
                switched = await switcher.switchTo(branch)
            case .create(let name):
                switched = await switcher.createBranch(name)
            }
            if switched {
                onSwitched()
                onDismiss()
            }
        }
    }
}
