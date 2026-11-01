import SwiftUI
import AppKit
import CodecCore

/// A script, ready to run: its variables to fill in, and the command they make. Return puts the command
/// on the command line, ⌘Return runs it.
struct IntelRunView: View {
    let item: IntelItem
    let theme: CodecTheme
    let codeFont: NSFont
    /// Whether there's a command line to put it on; otherwise it can only be copied.
    let canInsert: Bool
    var insert: (String) -> Void
    var run: (String) -> Void
    var edit: () -> Void
    var dismiss: () -> Void

    @State private var values: [String: String]
    @FocusState private var focused: String?

    init(item: IntelItem, theme: CodecTheme, codeFont: NSFont, canInsert: Bool, insert: @escaping (String) -> Void,
         run: @escaping (String) -> Void, edit: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.item = item
        self.theme = theme
        self.codeFont = codeFont
        self.canInsert = canInsert
        self.insert = insert
        self.run = run
        self.edit = edit
        self.dismiss = dismiss
        var values: [String: String] = [:]
        for variable in item.allVariables {
            values[variable.name] = variable.choices.isEmpty || variable.choices.contains(variable.defaultValue)
                ? variable.defaultValue : variable.choices[0]
        }
        _values = State(initialValue: values)
    }

    private var command: String { item.resolvedCommand(values) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "apple.terminal").foregroundStyle(theme.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 15, weight: .semibold))
                    if !item.description.isEmpty {
                        Text(item.description).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Edit…", action: edit).buttonStyle(.borderless).controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            let variables = item.allVariables
            if !variables.isEmpty {
                Divider().opacity(0.5)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    ForEach(variables) { variable in
                        GridRow {
                            Text(variable.name)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(theme.accentColor)
                                .gridColumnAlignment(.trailing)
                            VStack(alignment: .leading, spacing: 3) {
                                field(for: variable)
                                if !variable.description.isEmpty {
                                    Text(variable.description).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Divider().opacity(0.5)
            ScrollView {
                Text(AttributedString(ShellHighlighting.attributed(command, theme: theme, font: codeFont, size: 12.5, singleLine: false)))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 40, maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.backgroundColor.opacity(0.6)))
            .padding(12)
            .accessibilityLabel("Command: \(command)")

            HStack(spacing: 8) {
                if !canInsert {
                    Text("The shell is busy: copy the command, or wait for the prompt.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    dismiss()
                }
                Button("Insert") { insert(command) }
                    .disabled(!canInsert)
                    .keyboardShortcut(.defaultAction)
                Button("Run") { run(command) }
                    .disabled(!canInsert)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.glassProminent)
                    .tint(theme.accentColor.opacity(0.8))
            }
            .controlSize(.regular)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(width: 600)
        .onExitCommand(perform: dismiss)
        .onAppear { focused = item.allVariables.first?.name }
    }

    @ViewBuilder
    private func field(for variable: IntelVariable) -> some View {
        let binding = Binding { values[variable.name] ?? "" } set: { values[variable.name] = $0 }
        if variable.choices.isEmpty {
            TextField(variable.defaultValue.isEmpty ? variable.name : variable.defaultValue, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused, equals: variable.name)
                .onSubmit { if canInsert { insert(command) } }
        } else {
            Picker(variable.name, selection: binding) {
                ForEach(variable.choices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Saving a command to Intel, starting a new item or editing one: title, description and, for scripts,
/// the command and its variables. Parts of the command that look like they change between runs are
/// offered as variables; click one to make it a `{{blank}}`.
struct IntelEditView: View {
    let theme: CodecTheme
    let projectName: String?
    /// The branch the command ran on, to recognise it in the command.
    let branch: String?
    let isNew: Bool
    /// Each library's folders, to save in.
    let folders: [IntelLibrary.Source: [String]]
    var save: (IntelItem, IntelLibrary.Source, String) -> String?
    var cancel: () -> Void

    @State private var item: IntelItem
    @State private var command: String
    @State private var details: [String: IntelVariable]
    @State private var choices: [String: String]
    @State private var source: IntelLibrary.Source
    @State private var folder: String
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    init(item: IntelItem, source: IntelLibrary.Source, folder: String = "", isNew: Bool, theme: CodecTheme, projectName: String?,
         folders: [IntelLibrary.Source: [String]] = [:], branch: String?,
         save: @escaping (IntelItem, IntelLibrary.Source, String) -> String?, cancel: @escaping () -> Void) {
        self.theme = theme
        self.projectName = projectName
        self.folders = folders
        self.branch = branch
        self.isNew = isNew
        self.save = save
        self.cancel = cancel
        _item = State(initialValue: item)
        _command = State(initialValue: item.kind == .script ? item.command : "")
        _details = State(initialValue: Dictionary(item.variables.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }))
        _choices = State(initialValue: Dictionary(item.variables.map { ($0.name, $0.choices.joined(separator: ", ")) },
                                                  uniquingKeysWith: { first, _ in first }))
        let source = projectName == nil ? IntelLibrary.Source.personal : source
        _source = State(initialValue: source)
        _folder = State(initialValue: (folders[source] ?? []).contains(folder) ? folder : "")
    }

    private var folderChoices: [String] { folders[source] ?? [] }

    private var isScript: Bool { item.kind == .script }
    private var names: [String] { IntelPlaceholders.names(in: command) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.system(size: 15, weight: .semibold))

            labeled("Title") {
                TextField(isScript ? "What it does" : "Document title", text: $item.title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
            }
            labeled("Description") {
                TextField("Optional", text: $item.description).textFieldStyle(.roundedBorder)
            }

            if isScript {
                labeled("Command") {
                    TextEditor(text: $command)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 76)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.backgroundColor.opacity(0.6)))
                        .accessibilityLabel("Command")
                }
                suggestions
                if !names.isEmpty { variables }
            }

            HStack {
                Picker("Save to", selection: $source) {
                    Text("Personal").tag(IntelLibrary.Source.personal)
                    Text(projectName.map { "Project · \($0)" } ?? "Project").tag(IntelLibrary.Source.project)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(projectName == nil)
                .help(projectName == nil ? "Not in a git repository: there's no project to save to." : "Project Intel is kept in .codec/intel, to commit and share.")
                .onChange(of: source) { if !folderChoices.contains(folder) { folder = "" } }
                if !folderChoices.isEmpty {
                    Picker("Folder", selection: $folder) {
                        Label("Top Level", systemImage: "tray").tag("")
                        Divider()
                        ForEach(folderChoices, id: \.self) { path in
                            Label(path.split(separator: "/").joined(separator: " › "), systemImage: "folder").tag(path)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 190)
                    .help("The folder to keep it in")
                    .accessibilityLabel("Folder")
                }
                Spacer()
                if let error {
                    Text(error).font(.system(size: 11)).foregroundStyle(theme.alertColor).lineLimit(2)
                }
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).fixedSize()
                Button("Save", action: submit)
                    .fixedSize()
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.glassProminent)
                    .tint(theme.accentColor.opacity(0.8))
                    .disabled(item.title.trimmingCharacters(in: .whitespaces).isEmpty
                              || (isScript && command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(16)
        .frame(width: 620)
        .onExitCommand(perform: cancel)
        .onAppear { titleFocused = true }
    }

    private var heading: String {
        if isNew { return isScript ? (command.isEmpty ? "New Script" : "Save to Intel") : "New Document" }
        return isScript ? "Edit Script" : "Edit Document"
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Variables

    @ViewBuilder
    private var suggestions: some View {
        let candidates = IntelSuggestions.candidates(in: command, branch: branch)
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Make a variable").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                FlowRow(spacing: 6) {
                    ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                        Button { makeVariable(candidate) } label: {
                            HStack(spacing: 4) {
                                Text(candidate.name).foregroundStyle(theme.accentColor)
                                Text(candidate.value).lineLimit(1).truncationMode(.middle)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                            .frame(maxWidth: 260)
                        }
                        .buttonStyle(.plain)
                        .help("Replace “\(candidate.value)” with {{\(candidate.name)}}, defaulting to it")
                    }
                }
            }
        }
    }

    private var variables: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Variables").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(names, id: \.self) { name in
                    GridRow {
                        Text(IntelPlaceholders.placeholder(name))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.accentColor)
                        TextField("Description", text: detail(name, \.description)).textFieldStyle(.roundedBorder)
                        TextField("Default", text: detail(name, \.defaultValue)).textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        TextField("Choices: a, b, c", text: Binding { choices[name] ?? "" } set: { choices[name] = $0 })
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
        }
    }

    private func detail(_ name: String, _ key: WritableKeyPath<IntelVariable, String>) -> Binding<String> {
        Binding {
            details[name]?[keyPath: key] ?? ""
        } set: { value in
            var variable = details[name] ?? IntelVariable(name: name)
            variable[keyPath: key] = value
            details[name] = variable
        }
    }

    private func makeVariable(_ candidate: IntelSuggestions.Candidate) {
        var characters = Array(command)
        guard candidate.range.upperBound <= characters.count else { return }
        var name = candidate.name
        var number = 2
        while names.contains(name) {
            name = candidate.name + "_\(number)"
            number += 1
        }
        characters.replaceSubrange(candidate.range, with: IntelPlaceholders.placeholder(name))
        command = String(characters)
        details[name] = IntelVariable(name: name, defaultValue: candidate.value)
    }

    private func submit() {
        var item = item
        item.title = item.title.trimmingCharacters(in: .whitespaces)
        item.description = item.description.trimmingCharacters(in: .whitespaces)
        if isScript {
            item.command = command.trimmingCharacters(in: .newlines)
            item.variables = names.map { name in
                var variable = details[name] ?? IntelVariable(name: name)
                variable.choices = (choices[name] ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return variable
            }
        } else if item.body.isEmpty {
            item.body = "# \(item.title)\n\n"
        }
        error = save(item, source, folder)
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
