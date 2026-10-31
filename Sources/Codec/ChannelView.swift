import AppKit
import SwiftUI

/// Content view of a Codec window: blurred backdrop, theme tint, the terminal, scanlines and SwiftUI overlays.
final class ChannelView: NSView {
    let backdrop = NSVisualEffectView()
    let tint = NSView()
    /// Holds the terminal and scanlines so the "screen powering on" animation can transform them together.
    let screen = NSView()
    let terminal = CodecTerminalView(frame: .zero)
    let scanlines = ScanlineView()
    let overlay: OverlayHostingView
    let keyCatcher = KeyCatcherView()

    init(session: Session, onContinue: @escaping () -> Void, onExit: @escaping () -> Void) {
        overlay = OverlayHostingView(rootView: ChannelOverlay(session: session, onContinue: onContinue, onExit: onExit))
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))

        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        tint.wantsLayer = true
        screen.wantsLayer = true
        keyCatcher.onReturn = onContinue
        keyCatcher.onEscape = onExit

        for view in [backdrop, tint, screen, overlay, keyCatcher] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [terminal, scanlines] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            screen.addSubview(view)
        }

        NSLayoutConstraint.activate(
            fill(backdrop, in: self) + fill(tint, in: self) + fill(scanlines, in: terminal) + [
                terminal.topAnchor.constraint(equalTo: screen.topAnchor),
                terminal.bottomAnchor.constraint(equalTo: screen.bottomAnchor, constant: -8),
                terminal.leadingAnchor.constraint(equalTo: screen.leadingAnchor, constant: 10),
                terminal.trailingAnchor.constraint(equalTo: screen.trailingAnchor, constant: -4),
                screen.leadingAnchor.constraint(equalTo: leadingAnchor),
                screen.trailingAnchor.constraint(equalTo: trailingAnchor),
                screen.bottomAnchor.constraint(equalTo: bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
                overlay.topAnchor.constraint(equalTo: screen.topAnchor),
                keyCatcher.widthAnchor.constraint(equalToConstant: 0),
                keyCatcher.heightAnchor.constraint(equalToConstant: 0),
                keyCatcher.topAnchor.constraint(equalTo: topAnchor),
                keyCatcher.leadingAnchor.constraint(equalTo: leadingAnchor),
            ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Pins the top of the terminal below the toolbar and tab bar once the view is in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let guide = window.contentLayoutGuide as? NSLayoutGuide else { return }
        screen.topAnchor.constraint(equalTo: guide.topAnchor, constant: 4).isActive = true
    }

    func apply(theme: CodecTheme, opacity: Double, blur: Bool, scanlinesOn: Bool) {
        backdrop.isHidden = !blur
        backdrop.appearance = theme.appearance
        let alpha = blur ? opacity : 1
        tint.layer?.backgroundColor = theme.background.withAlphaComponent(alpha).cgColor
        scanlines.isHidden = !scanlinesOn
        scanlines.lineColor = theme.isDark ? .black : NSColor(white: 0, alpha: 0.5)
        scanlines.needsDisplay = true
    }

    /// The codec screen opening: a bright line that unfolds vertically into the picture.
    func playPowerOn() {
        guard let layer = screen.layer else { return }
        let h = layer.bounds.height
        func squash(_ s: CGFloat, _ w: CGFloat = 1) -> NSValue {
            var t = CATransform3DMakeTranslation(layer.bounds.width / 2, h / 2, 0)
            t = CATransform3DScale(t, w, s, 1)
            t = CATransform3DTranslate(t, -layer.bounds.width / 2, -h / 2, 0)
            return NSValue(caTransform3D: t)
        }
        let unfold = CAKeyframeAnimation(keyPath: "transform")
        unfold.values = [squash(0.004, 0.6), squash(0.004, 1), squash(1.015), squash(1)]
        unfold.keyTimes = [0, 0.25, 0.8, 1]
        unfold.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        unfold.duration = 0.34
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.4
        fade.toValue = 1
        fade.duration = 0.34
        layer.add(unfold, forKey: "powerOn")
        layer.add(fade, forKey: "powerOnFade")
    }

    private func fill(_ view: NSView, in container: NSView) -> [NSLayoutConstraint] {
        [
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ]
    }
}

/// Hosts the SwiftUI overlays, letting clicks through to the terminal unless a screen is up.
final class OverlayHostingView: NSHostingView<ChannelOverlay> {
    var capturesMouse = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        capturesMouse ? super.hitTest(point) : nil
    }
}

/// Faint CRT scanlines over the terminal.
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

/// Takes keyboard focus while the signal-lost screen is showing.
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
