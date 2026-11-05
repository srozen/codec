import AppKit
import SwiftUI
import CodecCore

/// The terminal plus the pane's overlays: find bar and highlights, the file ⌘-click would open, bell
/// indicator, exit banner, the question whether to activate a Python environment and the
/// inactive-pane dimmer.
final class PaneView: NSView {
    let terminal = CodecTerminalView(frame: .zero)
    let scanlines = ScanlineView()
    /// Marks a command the user went back to.
    let commandMark = CommandMarkView()
    /// Underlines the file name under the pointer while ⌘ is held.
    let fileLink = FileLinkView()
    /// Find in the terminal: its bar and its highlights.
    private(set) lazy var finder = TerminalFinder(terminal: terminal)
    let overlay: PassthroughHostingView<PaneOverlay>
    /// Asks whether to activate a virtual environment; only as big as the question, so the rest of
    /// the pane takes clicks.
    let venvBanner: PassthroughHostingView<VenvBanner>
    private let dimmer = PassthroughView()
    private let keyCatcher = KeyCatcherView()
    private(set) var isDimmed = false

    var onRestart: (() -> Void)? {
        didSet { keyCatcher.onReturn = onRestart }
    }
    /// The terminal scrolled, by the user or as output came in.
    var onScroll: (() -> Void)?
    var onDismiss: (() -> Void)? {
        didSet { keyCatcher.onEscape = onDismiss }
    }
    /// The answer to the virtual environment question.
    var onVenvDecision: ((Toolchain.PythonEnvironment, VenvAnswer) -> Void)?

    init(session: Session, preferences: Preferences) {
        overlay = PassthroughHostingView(rootView: PaneOverlay(session: session, preferences: preferences))
        venvBanner = PassthroughHostingView(rootView: VenvBanner(session: session, preferences: preferences) { _, _ in })
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        venvBanner.rootView = VenvBanner(session: session, preferences: preferences) { [weak self] venv, decision in
            self?.onVenvDecision?(venv, decision)
        }
        venvBanner.sizingOptions = [.intrinsicContentSize]
        overlay.rootView = PaneOverlay(session: session, preferences: preferences,
                                       onRestart: { [weak self] in self?.onRestart?() },
                                       onClose: { [weak self] in self?.onDismiss?() })
        overlay.capturesMouse = false
        dimmer.wantsLayer = true
        dimmer.alphaValue = 0

        // The bar gives way in a narrow pane, running off its left edge, rather than widen it.
        let barRoom = finder.bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14)
        barRoom.priority = .defaultLow
        terminal.onFind = { [weak self] action in self?.finder.perform(action) }
        terminal.onScroll = { [weak self] in
            self?.finder.refreshHighlights()
            self?.onScroll?()
        }

        for view in [terminal, finder.highlights, fileLink, scanlines, commandMark, finder.bar, dimmer, venvBanner, overlay,
                     keyCatcher] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            keyCatcher.widthAnchor.constraint(equalToConstant: 0),
            keyCatcher.heightAnchor.constraint(equalToConstant: 0),
            keyCatcher.topAnchor.constraint(equalTo: topAnchor),
            keyCatcher.leadingAnchor.constraint(equalTo: leadingAnchor),
            venvBanner.topAnchor.constraint(equalTo: topAnchor),
            venvBanner.centerXAnchor.constraint(equalTo: centerXAnchor),
            venvBanner.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            finder.bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            finder.bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            barRoom,
        ] + [finder.highlights, fileLink, scanlines, commandMark, dimmer, overlay].flatMap { $0.constraintsFilling(self) })
    }

    override func layout() {
        super.layout()
        if finder.isOpen { finder.refreshHighlights() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Clicking the pane's padding focuses the terminal.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(preferredResponder)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        terminal.menu(for: event)
    }

    func apply(theme: CodecTheme, scanlines enabled: Bool) {
        finder.apply(theme: theme)
        fileLink.theme = theme
        scanlines.isHidden = !enabled
        scanlines.lineColor = theme.isDark ? .black : NSColor(white: 0, alpha: 0.5)
        scanlines.needsDisplay = true
        dimmer.layer?.backgroundColor = (theme.isDark ? NSColor.black.withAlphaComponent(0.32)
                                                      : NSColor.white.withAlphaComponent(0.4)).cgColor
    }

    func setDimmed(_ dim: Bool) {
        guard dim != isDimmed else { return }
        isDimmed = dim
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            dimmer.animator().alphaValue = dim ? 1 : 0
        }
    }

    /// Briefly marks a command: a bar in the gutter beside its rows, and a tint over one line of it.
    /// Both in this view's coordinates.
    func mark(block: NSRect, line: NSRect, color: NSColor) {
        commandMark.show(bar: NSRect(x: max(terminal.frame.minX - 9, 2), y: block.minY, width: 3, height: block.height),
                         line: line.insetBy(dx: -4, dy: 0), color: color)
    }

    var isExitBannerVisible: Bool { overlay.capturesMouse }

    func setExitBannerVisible(_ visible: Bool) {
        overlay.capturesMouse = visible
        if visible { window?.makeFirstResponder(keyCatcher) }
    }

    /// Where keyboard focus goes when this pane is focused.
    var preferredResponder: NSView {
        overlay.capturesMouse ? keyCatcher : terminal
    }
}

extension NSView {
    func constraintsFilling(_ container: NSView) -> [NSLayoutConstraint] {
        [
            topAnchor.constraint(equalTo: container.topAnchor),
            bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leadingAnchor.constraint(equalTo: container.leadingAnchor),
            trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ]
    }
}

/// Hosts SwiftUI chrome. Ignores the window's safe area (otherwise content under a full-size title bar
/// gets pushed down by its height), and can let the mouse through to the views underneath.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var capturesMouse = true
    /// Off for chrome in the title bar whose drags mean something else (moving a tab): AppKit would
    /// otherwise move the window. Its empty space still does, through `WindowDragGesture`.
    var movesWindow = true

    override var mouseDownCanMoveWindow: Bool { movesWindow && super.mouseDownCanMoveWindow }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        capturesMouse ? super.hitTest(point) : nil
    }
}

/// Faint CRT scanlines over the terminal (off by default).
/// A view the mouse goes through, for overlays like the inactive-pane dimmer.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What ⌘ would open. Every name a click would open is washed in the accent, like a prompt chip; the
/// one under the pointer more, and underlined, with a tag beside it showing the file's icon and, when
/// the name doesn't say it all, the path that opens. The tag goes under the name when there's no room
/// beside it.
final class FileLinkView: NSView {
    struct Tag: Equatable {
        var icon: NSImage
        var path: String?
    }

    var theme: CodecTheme = .codec {
        didSet { needsDisplay = true }
    }
    /// The terminal's font; the tag's path is set in it, a little smaller.
    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    /// The other names' cells, a rect per row each spans, in this view's coordinates.
    private(set) var marks: [NSRect] = []
    /// The cells of the name under the pointer.
    private(set) var frames: [NSRect] = []
    private(set) var fileTag: Tag?
    /// Where the tag is, in this view's coordinates.
    private(set) var tagFrame: NSRect = .zero
    /// A ⌘-press is on the name: its wash deepens until the press ends.
    var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isShowing: Bool { !marks.isEmpty || !frames.isEmpty }

    func show(marks: [NSRect], frames: [NSRect], tag: Tag?) {
        guard marks != self.marks || frames != self.frames || tag != fileTag else { return }
        let appearing = !isShowing && (!marks.isEmpty || !frames.isEmpty)
        self.marks = marks
        self.frames = frames
        fileTag = frames.isEmpty ? nil : tag
        if frames.isEmpty { isPressed = false }
        layOutTag()
        needsDisplay = true
        // It comes in quickly when ⌘ goes down, and goes at once when ⌘ comes up.
        if appearing, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                animator().alphaValue = 1
            }
        } else if !isShowing {
            alphaValue = 1
        }
    }

    override func layout() {
        super.layout()
        layOutTag()
    }

    private var tagFont: NSFont {
        NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * 0.85).rounded()) ?? font
    }

    /// The path, its folders bright since they're what the name didn't say, and its last part, which
    /// the name already shows, quieter.
    private var tagText: NSAttributedString? {
        guard let path = fileTag?.path else { return nil }
        let paragraph = NSMutableParagraphStyle()
        // A long path loses its start, never the file's name.
        paragraph.lineBreakMode = .byTruncatingHead
        let split = path.range(of: "/", options: .backwards).map(\.upperBound) ?? path.startIndex
        let text = NSMutableAttributedString()
        for (part, alpha) in [(path[..<split], 0.92), (path[split...], split == path.startIndex ? 0.86 : 0.5)] where !part.isEmpty {
            text.append(NSAttributedString(string: String(part), attributes: [
                .font: tagFont, .foregroundColor: theme.foreground.withAlphaComponent(alpha), .paragraphStyle: paragraph,
            ]))
        }
        return text
    }

    private func iconSide(_ height: CGFloat) -> CGFloat { min(FileIcons.size.height, height - 4) }

    private func layOutTag() {
        guard fileTag != nil, let first = frames.first, let last = frames.last else {
            tagFrame = .zero
            return
        }
        let height = last.height - 1
        let text = tagText.map { ceil($0.size().width) }
        let width = min(5 + iconSide(height) + (text.map { 5 + $0 + 7 } ?? 5), bounds.width - 8)
        var frame = NSRect(x: last.maxX + 6, y: last.midY - height / 2, width: width, height: height)
        if frame.maxX > bounds.maxX - 4 {
            frame.origin.x = max(4, min(first.minX - 2, bounds.maxX - 4 - width))
            frame.origin.y = last.minY - height - 3
            if frame.minY < bounds.minY { frame.origin.y = first.maxY + 3 }
        }
        tagFrame = frame
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = theme.accent
        accent.withAlphaComponent(0.13).setFill()
        for mark in marks {
            NSBezierPath(roundedRect: mark.insetBy(dx: -2, dy: 0.5), xRadius: 3, yRadius: 3).fill()
        }
        for frame in frames {
            accent.withAlphaComponent(isPressed ? 0.4 : 0.26).setFill()
            NSBezierPath(roundedRect: frame.insetBy(dx: -2, dy: 0.5), xRadius: 3, yRadius: 3).fill()
            accent.setFill()
            NSRect(x: frame.minX, y: frame.minY + 1.5, width: frame.width, height: 1.5).fill()
        }
        guard let fileTag, !tagFrame.isEmpty else { return }
        let chip = NSBezierPath(roundedRect: tagFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        (theme.background.blended(withFraction: 0.12, of: accent) ?? theme.background).setFill()
        chip.fill()
        accent.withAlphaComponent(0.28).setStroke()
        chip.lineWidth = 1
        chip.stroke()
        let side = iconSide(tagFrame.height)
        let icon = NSRect(x: tagFrame.minX + 5, y: (tagFrame.midY - side / 2).rounded(), width: side, height: side)
        fileTag.icon.draw(in: icon)
        guard let text = tagText else { return }
        let lineHeight = ceil(tagFont.ascender - tagFont.descender)
        text.draw(with: NSRect(x: icon.maxX + 5, y: (tagFrame.midY - lineHeight / 2).rounded(),
                               width: tagFrame.maxX - 7 - (icon.maxX + 5), height: lineHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// The mark over a command the user went back to; it fades after a moment.
final class CommandMarkView: NSView {
    private let bar = PassthroughView()
    private let line = PassthroughView()
    private var token = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [line, bar] {
            view.wantsLayer = true
            view.layer?.cornerRadius = 1.5
            view.alphaValue = 0
            addSubview(view)
        }
        line.layer?.cornerRadius = 4
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isShowing: Bool { bar.alphaValue > 0 }

    func show(bar barFrame: NSRect, line lineFrame: NSRect, color: NSColor) {
        token += 1
        let token = token
        bar.frame = barFrame
        line.frame = lineFrame
        bar.layer?.backgroundColor = color.cgColor
        line.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        bar.alphaValue = 1
        line.alphaValue = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == token else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.5
                    self.bar.animator().alphaValue = 0
                    self.line.animator().alphaValue = 0
                }
            }
        }
    }
}

final class ScanlineView: NSView {
    var lineColor: NSColor = .black

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        lineColor.withAlphaComponent(0.07).setFill()
        var y = floor(dirtyRect.minY / 3) * 3
        while y < dirtyRect.maxY {
            NSRect(x: dirtyRect.minX, y: y, width: dirtyRect.width, height: 1).fill()
            y += 3
        }
    }
}

/// Takes keyboard focus while the exit banner is showing: Return restarts, Esc closes.
final class KeyCatcherView: NSView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Overlay content

struct PaneOverlay: View {
    @ObservedObject var session: Session
    @ObservedObject var preferences: Preferences
    var onRestart: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        let theme = preferences.theme
        ZStack(alignment: .bottom) {
            Color.clear
            if let token = session.alertToken {
                BellIndicator(color: theme.alertColor)
                    .id(token)
                    .position(session.alertAnchor)
            }
            if let exit = session.exitStatus {
                ExitBanner(exit: exit, theme: theme, onRestart: onRestart, onClose: onClose)
                    .padding(14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: session.exitStatus)
    }
}

/// Shown at the bottom of a pane whose shell has exited.
private struct ExitBanner: View {
    let exit: Session.ExitStatus
    let theme: CodecTheme
    var onRestart: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failed ? theme.alertColor : theme.accentColor)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.system(size: 13, weight: .semibold))
                Text("Return to restart · Esc to close")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button("Restart", action: onRestart)
                .buttonStyle(.glassProminent)
                .tint(theme.accentColor.opacity(0.8))
            Button("Close", action: onClose)
                .buttonStyle(.glass)
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var failed: Bool { exit.code != 0 }

    private var headline: String {
        switch exit.code {
        case .none: "The shell was terminated"
        case .some(0): "The shell exited"
        case .some(let code): "The shell exited with status \(code)"
        }
    }
}

/// The bell: a small "!" that pops over the cursor.
private struct BellIndicator: View {
    let color: Color

    private struct Frame {
        var scale: CGFloat = 0.3
        var lift: CGFloat = 0
        var opacity: Double = 0
    }

    var body: some View {
        Text("!")
            .font(.system(size: 26, weight: .black, design: .rounded))
            .foregroundStyle(color)
            .shadow(color: color.opacity(0.6), radius: 6)
            .keyframeAnimator(initialValue: Frame(), repeating: false) { content, frame in
                content
                    .scaleEffect(frame.scale, anchor: .bottom)
                    .offset(y: frame.lift)
                    .opacity(frame.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.15, duration: 0.1, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.16, spring: .bouncy)
                }
                KeyframeTrack(\.lift) {
                    SpringKeyframe(-10, duration: 0.14, spring: .snappy)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.04)
                    LinearKeyframe(1, duration: 0.56)
                    LinearKeyframe(0, duration: 0.2)
                }
            }
            .allowsHitTesting(false)
    }
}
