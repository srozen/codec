import AppKit
import AVFoundation
import CodecCore

/// Plays the codec cues. Uses `Sounds/codec_*.mp3` from the app bundle when present and falls back to
/// synthesized tones otherwise.
@MainActor
final class CodecSound: SoundPlaying {
    enum Cue: String, CaseIterable {
        /// Attention from a pane you aren't looking at: a bell, or a long command finishing.
        case call = "codec_call"
        /// Bell in the focused pane (when enabled), and opening a pane.
        case lock = "codec_lock"
        /// A shell crashing, and closing a pane.
        case exit = "codec_exit"
    }

    private let preferences: Preferences
    private let bundle: Bundle
    private var players: [Cue: AVAudioPlayer] = [:]
    private var lastPlayed: [Cue: Date] = [:]

    init(preferences: Preferences, bundle: Bundle = .main) {
        self.preferences = preferences
        self.bundle = bundle
    }

    func play(_ sound: Sound) {
        switch sound {
        case .call: play(Cue.call)
        case .lock: play(Cue.lock)
        case .exit: play(Cue.exit)
        case .system: NSSound.beep()
        }
    }

    func play(_ cue: Cue) {
        let prefs = preferences
        guard prefs.codecSounds else { return }
        // Don't let a burst of events stack up a burst of sounds.
        if let last = lastPlayed[cue], Date().timeIntervalSince(last) < 1.5 { return }
        lastPlayed[cue] = Date()
        guard let player = player(for: cue) else { return }
        player.volume = Float(prefs.soundVolume)
        player.currentTime = 0
        player.play()
    }

    private func player(for cue: Cue) -> AVAudioPlayer? {
        if let player = players[cue] { return player }
        let player: AVAudioPlayer?
        if let url = bundle.url(forResource: cue.rawValue, withExtension: "mp3", subdirectory: "Sounds") {
            player = try? AVAudioPlayer(contentsOf: url)
        } else {
            player = try? AVAudioPlayer(data: Synth.wav(for: cue))
        }
        player?.prepareToPlay()
        players[cue] = player
        return player
    }
}

/// Fallback tones for builds without the sound files.
enum Synth {
    static func wav(for cue: CodecSound.Cue) -> Data {
        switch cue {
        case .call:
            return render(duration: 0.62) { t in
                let ring = 0.24, gap = 0.12
                let local = t.truncatingRemainder(dividingBy: ring + gap)
                guard local < ring else { return 0 }
                let env = min(1, local * 300) * min(1, (ring - local) * 60)
                return env * 0.5 * softSquare((Int(local * 28) % 2 == 0 ? 2093 : 1568) * t)
            }
        case .lock:
            return render(duration: 0.2) { t in
                let env = min(1, t * 400) * exp(-t * 14)
                return env * 0.5 * softSquare((t < 0.07 ? 1760 : 2349) * t)
            }
        case .exit:
            return render(duration: 0.42) { t in
                let notes: [Double] = [880, 660, 440]
                let slot = Int(t / 0.14)
                guard slot < notes.count else { return 0 }
                let local = t - Double(slot) * 0.14
                guard local < 0.1 else { return 0 }
                return min(1, local * 300) * exp(-local * 18) * 0.5 * softSquare(notes[slot] * t)
            }
        }
    }

    private static func softSquare(_ cycles: Double) -> Double {
        let x = 2 * Double.pi * cycles
        return sin(x) + sin(3 * x) / 3 + sin(5 * x) / 5
    }

    /// 16-bit mono PCM in a WAV container.
    static func render(duration: Double, _ sample: (Double) -> Double) -> Data {
        let rate = 44_100
        let count = Int(duration * Double(rate))
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let value = Int16(max(-1, min(1, sample(Double(i) / Double(rate)) * 0.6)) * Double(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
