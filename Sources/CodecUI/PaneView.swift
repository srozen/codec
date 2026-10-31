import AppKit
import SwiftUI
import CodecCore

/// The terminal plus the pane's overlays: bell indicator, exit banner and the inactive-pane dimmer.
final class PaneView: NSView {
    let terminal = CodecTerminalView(frame: .zero)
    let scanlines = ScanlineView()
    let overlay: PassthroughHostingView<PaneOverlay>
    private let dimmer = PassthroughView()
    private let keyCatcher = KeyCatcherView()
    private(set) var isDimmed = false

    var onRestart: (() -> Void)? {
        didSet { keyCatcher.onReturn = onRestart }
    }
    var onDismiss: (() -> Void)? {
        didSet { keyCatcher.onEscape = onDismiss }
    }

    init(session: Session, preferences: Preferences) {
        overlay = PassthroughHostingView(rootView: PaneOverlay(session: session, preferences: preferences))
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        overlay.rootView = PaneOverlay(session: session, preferences: preferences,
                                       onRestart: { [weak self] in self?.onRestart?() },
                                       onClose: { [weak self] in self?.onDismiss?() })
        overlay.capturesMouse = false
        dimmer.wantsLayer = true
        dimmer.alphaValue = 0

        for view in [terminal, scanlines, dimmer, overlay, keyCatcher] as [NSView] {
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
        ] + [scanlines, dimmer, overlay].flatMap { $0.constraintsFilling(self) })
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
