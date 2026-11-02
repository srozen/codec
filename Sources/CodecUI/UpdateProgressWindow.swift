import AppKit
import CodecCore

/// How far along getting a new version ready is, with a button to stop.
@MainActor
final class UpdateProgressWindow: NSWindowController {
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
                             styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "Updating Codec"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)

        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        cancel.trailingAnchor.constraint(equalTo: bar.trailingAnchor).isActive = true
        window.contentView = stack
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ installation: Updater.Installation) {
        let version = installation.release.version.map(String.init(describing:)) ?? installation.release.tag
        switch installation.step {
        case .downloading(let fraction):
            label.stringValue = "Downloading Codec \(version)…"
            bar.isIndeterminate = fraction == nil
            if let fraction { bar.doubleValue = fraction }
        case .checking:
            label.stringValue = "Checking Codec \(version)…"
            bar.isIndeterminate = true
        }
        if bar.isIndeterminate { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
        showWindow(nil)
    }

    @objc private func cancel(_ sender: Any?) {
        onCancel()
    }
}
