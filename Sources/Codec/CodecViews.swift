import SwiftUI

extension CodecTheme {
    var accentColor: Color { Color(nsColor: accent) }
    var alertColor: Color { Color(nsColor: alert) }
    var backgroundColor: Color { Color(nsColor: background) }
    var foregroundColor: Color { Color(nsColor: foreground) }
}

// MARK: - Toolbar band

/// The capsule in the toolbar: signal meters flanking the channel's frequency, then what's on the channel.
struct CodecBand: View {
    @ObservedObject var session: Session
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        let theme = prefs.theme
        let alerting = session.alertToken != nil
        let digits = alerting ? theme.alertColor : theme.accentColor
        let signal = session.connection == .live ? session.signal : 0

        HStack(spacing: 7) {
            SignalMeter(level: signal, color: theme.accentColor, mirrored: true)
                .frame(width: 22, height: 10)
            SevenSegmentDisplay(text: session.frequency, color: digits, ghost: 0.13, glow: 0.3)
                .frame(height: 13)
            SignalMeter(level: signal, color: theme.accentColor)
                .frame(width: 22, height: 10)

            if !session.label.isEmpty {
                Text(session.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.foregroundColor.opacity(0.9))
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .fixedSize()
        .animation(.easeOut(duration: 0.08), value: signal)
        .animation(.snappy, value: alerting)
        .help(session.abbreviatedDirectory.isEmpty
              ? "Channel \(session.frequency)"
              : "Channel \(session.frequency) — \(session.abbreviatedDirectory)")
    }
}

// MARK: - Overlays

/// Everything drawn on top of the terminal: the tuning sequence, the "!" alert and the signal-lost screen.
struct ChannelOverlay: View {
    @ObservedObject var session: Session
    @ObservedObject var prefs = Preferences.shared
    var onContinue: () -> Void
    var onExit: () -> Void

    var body: some View {
        let theme = prefs.theme
        ZStack {
            if session.connection == .tuning {
                TuningView(frequency: session.frequency, theme: theme)
                    .transition(.opacity)
            }
            if case .lost(let code) = session.connection {
                SignalLostView(frequency: session.frequency, exitCode: code, theme: theme,
                               onContinue: onContinue, onExit: onExit)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
            if let token = session.alertToken {
                AlertBang(color: theme.alertColor)
                    .id(token)
                    .position(x: session.alertAnchor.x, y: session.alertAnchor.y)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Horizontal static, like a codec searching for a carrier.
struct StaticNoise: View {
    var color: Color
    var intensity: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            Canvas { context, size in
                var rng = SplitMix(seed: UInt64(timeline.date.timeIntervalSinceReferenceDate * 30))
                let rows = Int(size.height / 3)
                for _ in 0..<(rows / 2) {
                    let y = CGFloat(rng.next() % UInt64(max(rows, 1))) * 3
                    let x = CGFloat(rng.unit()) * size.width * 0.6
                    let w = size.width * CGFloat(0.15 + rng.unit() * 0.6)
                    let alpha = rng.unit() * 0.12 * intensity
                    context.fill(Path(CGRect(x: x, y: y, width: w, height: 1)), with: .color(color.opacity(alpha)))
                }
                // Rolling bright band.
                let t = timeline.date.timeIntervalSinceReferenceDate
                let bandY = CGFloat(t.truncatingRemainder(dividingBy: 1.6) / 1.6) * size.height
                let band = Path(CGRect(x: 0, y: bandY, width: size.width, height: size.height * 0.08))
                context.fill(band, with: .linearGradient(
                    Gradient(colors: [color.opacity(0), color.opacity(0.06 * intensity), color.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: bandY),
                    endPoint: CGPoint(x: 0, y: bandY + size.height * 0.08)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Small deterministic RNG so each frame of static is cheap and repeatable.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// Shown while a new channel opens: digits scan until they lock onto the frequency.
struct TuningView: View {
    let frequency: String
    let theme: CodecTheme
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            let locked = elapsed > 0.42
            VStack(spacing: 14) {
                Text(locked ? "CONNECTED" : "TUNING")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(5)
                    .foregroundStyle(theme.accentColor.opacity(0.75))
                HStack(spacing: 18) {
                    SignalMeter(level: min(1, elapsed / 0.45), color: theme.accentColor, mirrored: true)
                        .frame(width: 44, height: 22)
                    SevenSegmentDisplay(text: scanned(elapsed), color: theme.accentColor, ghost: 0.08, glow: 0.4)
                        .frame(height: 46)
                    SignalMeter(level: min(1, elapsed / 0.45), color: theme.accentColor)
                        .frame(width: 44, height: 22)
                }
            }
            .opacity(locked && Int(elapsed * 20) % 2 == 0 && elapsed < 0.55 ? 0.6 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                theme.backgroundColor.opacity(0.97)
                StaticNoise(color: theme.accentColor)
            }
        }
    }

    /// Each digit spins randomly, then settles left to right.
    private func scanned(_ elapsed: TimeInterval) -> String {
        var index = 0
        var rng = SplitMix(seed: UInt64(elapsed * 40))
        return String(frequency.map { ch -> Character in
            guard ch.isNumber else { return ch }
            defer { index += 1 }
            let settlesAt = 0.12 + Double(index) * 0.065
            if elapsed >= settlesAt { return ch }
            return Character(String(rng.next() % 10))
        })
    }
}

/// When the shell dies unexpectedly.
struct SignalLostView: View {
    let frequency: String
    let exitCode: Int32?
    let theme: CodecTheme
    var onContinue: () -> Void
    var onExit: () -> Void
    @State private var flicker = false

    var body: some View {
        VStack(spacing: 18) {
            SevenSegmentDisplay(text: frequency, color: theme.accentColor, ghost: 0.08, glow: 0.25)
                .frame(height: 30)
                .opacity(flicker ? 0.35 : 0.85)

            VStack(spacing: 6) {
                Text("SIGNAL LOST")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .tracking(6)
                    .foregroundStyle(theme.alertColor)
                    .shadow(color: theme.alertColor.opacity(0.6), radius: 12)
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.foregroundColor.opacity(0.6))
                Text("Snake? Snake?! SNAAAAKE!")
                    .font(.system(size: 12, weight: .regular).italic())
                    .foregroundStyle(theme.foregroundColor.opacity(0.4))
                    .padding(.top, 2)
            }

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: onContinue) {
                        Label("Continue", systemImage: "arrow.clockwise")
                            .frame(minWidth: 96)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(theme.accentColor.opacity(0.85))

                    Button(action: onExit) {
                        Text("Exit").frame(minWidth: 72)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            }

            Text("return to continue  ·  esc to close")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.foregroundColor.opacity(0.35))
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                theme.backgroundColor.opacity(0.9)
                StaticNoise(color: theme.foregroundColor, intensity: 0.6)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { flicker = true }
        }
    }

    private var detail: String {
        if let exitCode { return "shell exited with status \(exitCode)" }
        return "shell was terminated by a signal"
    }
}

/// The "!" that pops over the caret when the bell rings.
struct AlertBang: View {
    let color: Color

    private struct Frame {
        var scale: CGFloat = 0.2
        var lift: CGFloat = 0
        var opacity: Double = 0
    }

    var body: some View {
        Text("!")
            .font(.system(size: 40, weight: .black, design: .rounded))
            .foregroundStyle(color)
            .shadow(color: color.opacity(0.85), radius: 10)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            .keyframeAnimator(initialValue: Frame(), repeating: false) { content, frame in
                content
                    .scaleEffect(frame.scale, anchor: .bottom)
                    .offset(y: frame.lift)
                    .opacity(frame.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.3, duration: 0.12, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.18, spring: .bouncy)
                    LinearKeyframe(1.0, duration: 0.5)
                    LinearKeyframe(0.85, duration: 0.2)
                }
                KeyframeTrack(\.lift) {
                    SpringKeyframe(-16, duration: 0.16, spring: .snappy)
                    LinearKeyframe(-16, duration: 0.64)
                    LinearKeyframe(-24, duration: 0.2)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.04)
                    LinearKeyframe(1, duration: 0.76)
                    LinearKeyframe(0, duration: 0.2)
                }
            }
    }
}
