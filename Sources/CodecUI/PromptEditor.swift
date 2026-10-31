import SwiftUI
import AppKit
import CodecCore

// MARK: - Settings tab

/// Settings › Prompt: which prompt is in use, a preview, and the Codec prompt's options.
struct PromptSettings: View {
    @ObservedObject var prefs: Preferences
    @State private var editing = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(prefs.prompt.style == .codec ? "Codec prompt" : "Shell prompt (PS1)")
                            .font(.headline)
                        Text(prefs.prompt.style == .codec
                             ? "Built from the chips you pick, in zsh with shell integration on."
                             : "The prompt from your own zsh configuration, unchanged.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit Prompt…") { editing = true }
                }
                PromptPreview(configuration: prefs.prompt, theme: prefs.theme)
            } footer: {
                Text("Changes show up at the next prompt in every open zsh pane.")
                    .foregroundStyle(.secondary)
            }

            if prefs.prompt.style == .codec {
                Section("Options") {
                    Picker("Directory", selection: $prefs.prompt.directoryStyle) {
                        ForEach(PromptConfiguration.DirectoryStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Mark uncommitted git changes with *", isOn: $prefs.prompt.showsGitChanges)
                    Stepper(value: $prefs.prompt.durationThreshold, in: 0...60, step: 1) {
                        Text("Show durations of commands over \(Int(prefs.prompt.durationThreshold)) s")
                    }
                    Toggle("Blank line between commands", isOn: $prefs.prompt.blankLineBetweenCommands)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editing) {
            PromptEditorSheet(original: prefs.prompt, theme: prefs.theme) { saved in
                if let saved { prefs.prompt = saved }
                editing = false
            }
        }
    }
}

// MARK: - Editor sheet

/// "Edit prompt", modeled on Warp's: pick the Codec prompt or your shell's own, and build the Codec
/// prompt from chips. Nothing applies until Save.
struct PromptEditorSheet: View {
    let original: PromptConfiguration
    let theme: CodecTheme
    /// Called with the edited configuration, or nil when cancelled.
    var onFinish: (PromptConfiguration?) -> Void
    @State private var draft: PromptConfiguration
    private let sample = PromptConfiguration.Sample.current()

    init(original: PromptConfiguration, theme: CodecTheme, onFinish: @escaping (PromptConfiguration?) -> Void) {
        self.original = original
        self.theme = theme
        self.onFinish = onFinish
        _draft = State(initialValue: original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit prompt")
                .font(.title2.weight(.semibold))

            StyleCard(selected: draft.style == .codec, theme: theme, select: { draft.style = .codec }) {
                HStack {
                    Text("Codec prompt").font(.headline)
                    Spacer()
                    Button("Restore default") {
                        let style = draft.style
                        draft = .default
                        draft.style = style
                    }
                    .buttonStyle(.link)
                }
                ChipEditor(configuration: $draft, theme: theme, sample: sample, activate: { draft.style = .codec })
                Divider().opacity(0.5)
                OptionsGrid(configuration: $draft)
            }

            StyleCard(selected: draft.style == .shell, theme: theme, select: { draft.style = .shell }) {
                Text("Shell prompt (PS1)").font(.headline)
                Text("\(sample.user)@\(sample.host) \((sample.directory as NSString).lastPathComponent) %")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(theme.foregroundColor)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.foregroundColor.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.foregroundColor.opacity(0.12)))
                    .accessibilityLabel("Example of your shell prompt")
            }

            HStack(spacing: 12) {
                Button { onFinish(nil) } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                Button { onFinish(draft) } label: { Text("Save changes").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == original)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 700)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .background(theme.backgroundColor.opacity(0.97))
    }
}

/// A selectable card, outlined in the accent color when it's the prompt in use.
private struct StyleCard<Content: View>: View {
    let selected: Bool
    let theme: CodecTheme
    var select: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.foregroundColor.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? theme.accentColor : theme.foregroundColor.opacity(0.1), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: select)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Available chips on top, the prompt's chips in a dashed area below.
/// Click or drag a chip to add it; drag to reorder; × or drag back up to remove.
struct ChipEditor: View {
    @Binding var configuration: PromptConfiguration
    let theme: CodecTheme
    let sample: PromptConfiguration.Sample
    var activate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(configuration.availableKinds) { kind in
                    PromptChip(kind: kind, text: configuration.chipText(kind, sample),
                               color: theme.promptColor(configuration.color(of: kind)))
                        .onTapGesture { add(kind, before: nil) }
                        .draggable(kind.rawValue)
                        .help("Add \(kind.label)")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .dropDestination(for: String.self) { items, _ in
                items.compactMap(PromptConfiguration.Kind.init(rawValue:)).forEach { configuration.remove($0) }
                return true
            }

            PromptChipArea(configuration: $configuration, theme: theme, sample: sample, add: { add($0, before: $1) })

            Text("Click or drag a chip to add it. Drag chips to reorder them, and right-click one to change its color.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add(_ kind: PromptConfiguration.Kind, before target: PromptConfiguration.Kind?) {
        activate()
        withAnimation(.snappy(duration: 0.2)) { configuration.place(kind, before: target) }
    }
}

/// The dashed area holding the prompt's chips, in order, followed by the symbol.
struct PromptChipArea: View {
    @Binding var configuration: PromptConfiguration
    let theme: CodecTheme
    let sample: PromptConfiguration.Sample
    /// Adds or moves a chip, before another one or (nil) at the end.
    var add: (PromptConfiguration.Kind, PromptConfiguration.Kind?) -> Void
    @State private var targeted = false

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(configuration.enabledSegments) { segment in
                PromptChip(kind: segment.kind, text: configuration.chipText(segment.kind, sample),
                           color: theme.promptColor(segment.color),
                           onRemove: { configuration.remove(segment.kind) })
                    .draggable(segment.kind.rawValue)
                    .dropDestination(for: String.self) { items, _ in
                        items.compactMap(PromptConfiguration.Kind.init(rawValue:)).forEach { add($0, segment.kind) }
                        return true
                    }
                    .contextMenu { colorMenu(for: segment.kind) }
            }
            SymbolChip(symbol: configuration.symbol, theme: theme)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
        // Keep the natural height: when a parent offers less (a sheet sizing itself does), the area must
        // not shrink below its chips and let wrapped rows spill out.
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.foregroundColor.opacity(targeted ? 0.08 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(theme.foregroundColor.opacity(targeted ? 0.5 : 0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .overlay {
            if configuration.enabledSegments.isEmpty {
                Text("Drag chips here").font(.callout).foregroundStyle(.secondary)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            items.compactMap(PromptConfiguration.Kind.init(rawValue:)).forEach { add($0, nil) }
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Prompt segments")
    }

    @ViewBuilder
    private func colorMenu(for kind: PromptConfiguration.Kind) -> some View {
        Picker("Color", selection: Binding(
            get: { configuration.color(of: kind) },
            set: { configuration.setColor($0, for: kind) })) {
            ForEach(PromptConfiguration.Color.allCases) { Text($0.label).tag($0) }
        }
        Button("Remove") { configuration.remove(kind) }
    }
}

/// Layout, symbol, and what goes between segments.
private struct OptionsGrid: View {
    @Binding var configuration: PromptConfiguration

    /// "Between segments": connecting words, or one of the separators.
    private static let joiners: [(label: String, value: String)] = [
        ("Connecting words (on, via, took)", "words"), ("Space", " "), ("Dot", " · "), ("Bar", " | "), ("Slash", " / "),
    ]

    private var joiner: Binding<String> {
        Binding(
            get: { configuration.connectingWords ? "words" : configuration.separator },
            set: { value in
                if value == "words" {
                    configuration.connectingWords = true
                } else {
                    configuration.connectingWords = false
                    configuration.separator = value
                }
            })
    }

    private var symbols: [String] {
        PromptConfiguration.symbolChoices.contains(configuration.symbol)
            ? PromptConfiguration.symbolChoices
            : PromptConfiguration.symbolChoices + [configuration.symbol]
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Style").gridColumnAlignment(.trailing)
                Picker("Style", selection: $configuration.appearance) {
                    ForEach(PromptConfiguration.Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("Layout")
                Picker("Layout", selection: $configuration.layout) {
                    Text("One line").tag(PromptConfiguration.Layout.singleLine)
                    Text("Two lines").tag(PromptConfiguration.Layout.twoLines)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if configuration.layout == .twoLines {
                GridRow {
                    Text("Command line")
                    Toggle("Leave an empty line above it", isOn: $configuration.spaceAboveCommandLine)
                }
            }
            GridRow {
                Text("Symbol")
                Picker("Symbol", selection: $configuration.symbol) {
                    ForEach(symbols, id: \.self) { symbol in
                        Text(symbol).font(.system(.body, design: .monospaced)).tag(symbol)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if configuration.appearance == .text {
                GridRow {
                    Text("Between segments")
                    Picker("Between segments", selection: joiner) {
                        ForEach(Self.joiners, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .font(.callout)
    }
}

/// One segment as a chip: icon and example value in the segment's color.
struct PromptChip: View {
    let kind: PromptConfiguration.Kind
    let text: String
    let color: Color
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 11, weight: .medium))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove \(kind.label)")
                .accessibilityLabel("Remove \(kind.label)")
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(color.opacity(0.35)))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.label): \(text)")
    }
}

/// The prompt symbol at the end of the prompt. It's always there, so it can't be removed.
private struct SymbolChip: View {
    let symbol: String
    let theme: CodecTheme

    var body: some View {
        Text(symbol.isEmpty ? " " : symbol)
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(theme.promptColor(.green))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .help("Prompt symbol: green after success, red after a failure")
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .infinity
        let rows = arrange(subviews, width: width)
        let used = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width.isFinite ? width : used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Preview

/// The prompt drawn the way zsh will draw it, in the current theme's colors: chips as pills, text as text.
struct PromptPreview: View {
    let configuration: PromptConfiguration
    let theme: CodecTheme
    private let sample = PromptConfiguration.Sample.current()
    private static let font = Font.system(size: 12, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(spacing: 0) {
                    ForEach(Array(line.enumerated()), id: \.offset) { _, run in
                        piece(run)
                    }
                    if line.isEmpty && index < lines.count - 1 {
                        // An empty line still takes a line's height, as in the terminal.
                        Text(" ").font(Self.font)
                    }
                    if index == lines.count - 1 {
                        Text("git push").font(Self.font).foregroundStyle(theme.foregroundColor)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.backgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Prompt preview")
    }

    /// The runs split into the lines zsh would draw.
    private var lines: [[PromptConfiguration.Run]] {
        let runs = configuration.style == .codec
            ? configuration.preview(sample)
            : [.init(text: "\(sample.user)@\(sample.host) \((sample.directory as NSString).lastPathComponent) % ", color: nil)]
        var lines: [[PromptConfiguration.Run]] = [[]]
        for run in runs {
            if run.text == "\n" { lines.append([]) } else { lines[lines.count - 1].append(run) }
        }
        return lines
    }

    @ViewBuilder
    private func piece(_ run: PromptConfiguration.Run) -> some View {
        let color = run.color.map(theme.promptColor) ?? theme.foregroundColor
        let text = Text(run.text)
            .font(Self.font.weight(run.bold ? .bold : .regular))
            .foregroundStyle(color)
        if run.chip, let segment = run.color {
            text
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color(nsColor: NSColor(hexString: theme.promptChipFill(segment)) ?? theme.background)))
        } else {
            text
        }
    }
}

extension NSColor {
    /// `#rrggbb`.
    convenience init?(hexString: String) {
        guard hexString.hasPrefix("#"), hexString.count == 7, let value = UInt32(hexString.dropFirst(), radix: 16) else { return nil }
        self.init(hex: value)
    }
}

extension CodecTheme {
    func promptColor(_ color: PromptConfiguration.Color) -> Color {
        Color(nsColor: ansi[color.ansiIndex])
    }
}

extension PromptConfiguration.Sample {
    /// Example values with this Mac's user, host, time and date.
    static func current(now: Date = Date()) -> Self {
        var sample = Self()
        sample.user = NSUserName()
        sample.home = NSHomeDirectory()
        sample.directory = sample.home + "/code/codec"
        var name = [CChar](repeating: 0, count: 256)
        if gethostname(&name, name.count) == 0 {
            let host = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            sample.host = host.split(separator: ".").first.map(String.init) ?? host
        }
        sample.time = now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        sample.date = now.formatted(.dateTime.month(.abbreviated).day())
        return sample
    }
}
