import AVFoundation

/// Small synthesized cues. Everything is generated at runtime; no sampled audio ships with the app.
@MainActor
final class CodecSound {
    enum Cue: CaseIterable {
        /// Bell in the focused channel: a sharp two-voice stab.
        case alert
        /// Bell in a background channel: a trilling incoming call.
        case call
        /// Shell died: three falling blips.
        case lost
    }

    static let shared = CodecSound()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    private var ready = false

    func play(_ cue: Cue) {
        if !ready {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            player.volume = 0.35
            ready = true
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        guard let buffer = buffer(for: cue) else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }

    private func buffer(for cue: Cue) -> AVAudioPCMBuffer? {
        if let cached = buffers[cue] { return cached }
        let rendered: AVAudioPCMBuffer?
        switch cue {
        case .alert:
            rendered = render(duration: 0.26) { t in
                let env = exp(-t * 16) * min(1, t * 400)
                let f1 = 1480 - 380 * t / 0.26
                let f2 = 2220 - 520 * t / 0.26
                return env * (0.55 * Self.softSquare(f1 * t) + 0.35 * Self.softSquare(f2 * t))
            }
        case .call:
            // Two rings, each a fast trill between two pitches.
            rendered = render(duration: 0.62) { t in
                let ringLength = 0.24, gap = 0.12
                let local = t.truncatingRemainder(dividingBy: ringLength + gap)
                guard local < ringLength else { return 0 }
                let env = min(1, local * 300) * min(1, (ringLength - local) * 60)
                let high = Int(local * 28) % 2 == 0
                return env * 0.5 * Self.softSquare((high ? 2093 : 1568) * t)
            }
        case .lost:
            rendered = render(duration: 0.42) { t in
                let notes: [Double] = [880, 660, 440]
                let slot = Int(t / 0.14)
                guard slot < notes.count else { return 0 }
                let local = t - Double(slot) * 0.14
                guard local < 0.1 else { return 0 }
                let env = min(1, local * 300) * exp(-local * 18)
                return env * 0.5 * Self.softSquare(notes[slot] * t)
            }
        }
        buffers[cue] = rendered
        return rendered
    }

    /// A band-limited square: warm enough to not hurt, buzzy enough to read as "electronic".
    private static func softSquare(_ cycles: Double) -> Double {
        let x = 2 * Double.pi * cycles
        return sin(x) + sin(3 * x) / 3 + sin(5 * x) / 5
    }

    private func render(duration: Double, _ sample: (Double) -> Double) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(duration * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            channel[i] = Float(sample(Double(i) / rate) * 0.6)
        }
        return buffer
    }
}
