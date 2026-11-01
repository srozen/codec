import AppKit
import SwiftUI
import CodecCore

/// One command's output, in a popover from the Commands sidebar: the command and how it ended, then
/// everything it printed, selectable and searchable (⌘F), whether or not it's still in the scrollback.
final class CommandOutputViewer: NSViewController {
    struct Actions {
        var goTo: () -> Void
        var insert: () -> Void
        var run: () -> Void
        var close: () -> Void
        var saveToIntel: () -> Void = {}
        /// Puts a command on the command line.
        var insertCommand: (String) -> Void = { _ in }
    }

    let entry: TimelineEntry
    let output: String?
    private let inScrollback: Bool
    private let query: String
    private let theme: CodecTheme
    private let codeFont: NSFont
    let actions: Actions
    private let canInsert: Bool
    let explanation: FailureExplanationModel
    let textView = OutputTextView()

    init(entry: TimelineEntry, output: String?, inScrollback: Bool, query: String, theme: CodecTheme, codeFont: NSFont,
         actions: Actions, canInsert: Bool, explanation: FailureExplanationModel) {
        self.entry = entry
        self.output = output
        self.inScrollback = inScrollback
        self.query = query
        self.theme = theme
        self.codeFont = codeFont
        self.actions = actions
        self.canInsert = canInsert
        self.explanation = explanation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let header = NSHostingView(rootView: OutputHeader(
            entry: entry, theme: theme, codeFont: codeFont, inScrollback: inScrollback, canInsert: canInsert,
            hasOutput: output != nil, note: note, actions: actions, explanation: explanation,
            copy: { [weak self] in
                guard let output = self?.output else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
            }))
        header.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = theme.background
        textView.textColor = theme.foreground
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]
        textView.textContainerInset = NSSize(width: 10, height: 8)
        // Lines don't wrap, as in the terminal; scroll sideways for long ones.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.onClose = actions.close
        textView.setAccessibilityLabel("Output")
        let font = NSFont(descriptor: codeFont.fontDescriptor, size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let text = NSMutableAttributedString(
            string: output ?? placeholder,
            attributes: [.font: font, .foregroundColor: output == nil ? NSColor.secondaryLabelColor : theme.foreground])
        if let output, !query.isEmpty {
            let string = output as NSString
            var range = NSRange(location: 0, length: string.length)
            while true {
                let found = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                guard found.location != NSNotFound else { break }
                text.addAttribute(.backgroundColor, value: theme.accent.withAlphaComponent(0.35), range: found)
                range = NSRange(location: found.upperBound, length: string.length - found.upperBound)
            }
        }
        textView.textStorage?.setAttributedString(text)
        scrollView.documentView = textView

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 460))
        container.addSubview(header)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 680),
            container.heightAnchor.constraint(equalToConstant: 460),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        scrollToFirstMatch()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        explanation.cancel()
    }

    /// Puts the keyboard in the output, so ⌘F, ⌘A and ⌘C work on it straight away.
    func focusText() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.view.window else { return }
                window.makeFirstResponder(self.textView)
            }
        }
    }

    private func scrollToFirstMatch() {
        guard let output, !query.isEmpty else { return }
        let found = (output as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        guard found.location != NSNotFound else { return }
        textView.scrollRangeToVisible(found)
        textView.showFindIndicator(for: found)
    }

    private var placeholder: String {
        if entry.isRunning { return "Nothing printed yet." }
        if entry.fullScreen { return "This program used the full screen, so it left nothing in the scrollback." }
        return "No output."
    }

    /// What to know about where this output comes from.
    private var note: String? {
        var parts: [String] = []
        if !inScrollback, output != nil { parts.append("No longer in the terminal; this is the output Codec kept.") }
        if let captured = entry.output, !inScrollback {
            if captured.omitted > 0 { parts.append("\(captured.omitted) lines in the middle weren’t kept.") }
            if captured.lostEarlier { parts.append("Its first lines had already left the scrollback.") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// The output text: Esc and Space close the popover, as in Quick Look.
final class OutputTextView: NSTextView {
    var onClose: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty) {
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The command, how it ended, where and when, and what can be done with it.
private struct OutputHeader: View {
    let entry: TimelineEntry
    let theme: CodecTheme
    let codeFont: NSFont
    let inScrollback: Bool
    let canInsert: Bool
    let hasOutput: Bool
    let note: String?
    let actions: CommandOutputViewer.Actions
    @ObservedObject var explanation: FailureExplanationModel
    var copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .font(.system(size: 12, weight: .semibold))
                Text(AttributedString(ShellHighlighting.attributed(entry.command, theme: theme, font: codeFont, size: 13,
                                                                   singleLine: false)))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(metadata)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            HStack(spacing: 8) {
                Button("Go to Command", systemImage: "arrow.up.left.and.arrow.down.right", action: actions.goTo)
                    .disabled(!inScrollback)
                Button("Copy Output", systemImage: "doc.on.doc", action: copy)
                    .disabled(!hasOutput)
                Button("Save to Intel", systemImage: "bookmark", action: actions.saveToIntel)
                if explanation.isOffered {
                    Button("Explain", systemImage: "sparkles", action: explanation.explain)
                        .disabled(explanation.availability != .available || explanation.isWorking)
                        .help(explainHelp)
                }
                Spacer(minLength: 8)
                Button("Insert", systemImage: "text.insert", action: actions.insert)
                    .disabled(!canInsert)
                    .help("Put the command on the command line")
                Button("Run Again", systemImage: "arrow.clockwise", action: actions.run)
                    .disabled(!canInsert)
            }
            .controlSize(.small)
            .buttonStyle(.glass)
            FailureExplanationView(model: explanation, theme: theme, codeFont: codeFont, canInsert: canInsert,
                                   insert: actions.insertCommand)
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var explainHelp: String {
        if case .unavailable(let reason) = explanation.availability { return reason }
        return "Ask Apple Intelligence, on this Mac, why this command failed"
    }

    private var statusSymbol: String {
        switch entry.status {
        case .running: "circle.dotted"
        case .succeeded: "checkmark.circle.fill"
        case .failed(let code): code < 0 ? "questionmark.circle" : "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .running: theme.accentColor
        case .succeeded: Color(nsColor: theme.ansi[2])
        case .failed(let code): code < 0 ? .secondary : theme.alertColor
        }
    }

    private var metadata: String {
        var parts = [(entry.directory as NSString).abbreviatingWithTildeInPath,
                     entry.started.formatted(date: Calendar.current.isDateInToday(entry.started) ? .omitted : .abbreviated,
                                             time: .standard)]
        switch entry.status {
        case .running: parts.append("running for \(Formatting.duration(Date().timeIntervalSince(entry.started)))")
        case .succeeded: parts.append(Formatting.duration(entry.duration ?? 0))
        case .failed(let code):
            parts.append(Formatting.duration(entry.duration ?? 0))
            parts.append(code < 0 ? "no exit status" : "exit \(code)")
        }
        if let lines = entry.output?.lineCount, lines > 0 { parts.append(lines == 1 ? "1 line" : "\(lines) lines") }
        return parts.joined(separator: " · ")
    }
}
