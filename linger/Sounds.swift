import AVFoundation
import os

private let log = Logger(subsystem: "com.adityakolte.linger", category: "sounds")

enum Sound: CaseIterable {
    /// Ten seconds before a break: two soft taps ("tik tik").
    case finalCountdown
    /// The blur arrives: a slow chord swell, slightly under pitch and settling into tune.
    case breakStart
    /// A break was skipped: one low, damped note. Acknowledges, does not reward.
    case skip
    /// The break ran its course: the same chord, quick and rising, with a bright top note.
    case breakEnd
}

enum Sounds {
    static func play(_ sound: Sound, ignoringPreference: Bool = false) {
        guard ignoringPreference || UserDefaults.standard.bool(forKey: DefaultsKey.soundOn) else { return }
        SoundEngine.shared.play(sound)
    }
}

// Every sound is rendered once from the same instrument and played through the same small
// room, so they read as one voice rather than a set of alerts.
private final class SoundEngine {
    static let shared = SoundEngine()

    private static let sampleRate = 44_100.0
    private static let masterVolume: Float = 0.5
    private static let idleStop: TimeInterval = 4

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let reverb = AVAudioUnitReverb()
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private var idleTask: Task<Void, Never>?

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)
        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = 22
        engine.attach(player)
        engine.attach(reverb)
        engine.connect(player, to: reverb, format: format)
        // The reverb only outputs stereo; forcing mono here raises an NSException that freezes the app.
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = Self.masterVolume
    }

    func play(_ sound: Sound) {
        let buffer = buffers[sound] ?? {
            let rendered = Instrument.render(Self.recipe(for: sound), sampleRate: Self.sampleRate)
            buffers[sound] = rendered
            return rendered
        }()

        idleTask?.cancel()
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                log.error("Audio engine failed to start: \(error.localizedDescription)")
                return
            }
        }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.stopWhenIdle() }
        }
    }

    // The engine keeps the audio hardware awake, so it goes down once the reverb tail is gone.
    private func stopWhenIdle() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleStop))
            guard !Task.isCancelled, let self else { return }
            player.stop()
            engine.stop()
        }
    }

    // MARK: Palette (all in A; frequencies in Hz, times in seconds)

    private static func recipe(for sound: Sound) -> Instrument.Recipe {
        let a2 = 110.0, e3 = 164.81, a3 = 220.0, e4 = 329.63, a4 = 440.0, e5 = 659.26, d6 = 1174.66, e6 = 1318.51

        switch sound {
        case .finalCountdown:
            return Instrument.Recipe(peak: 0.5, partials: [
                .init(frequency: e6, start: 0, attack: 0.008, hold: 0, release: 0.14, gain: 1, glide: 1.1),
                .init(frequency: e5, start: 0, attack: 0.008, hold: 0, release: 0.10, gain: 0.3, glide: 1.1),
                .init(frequency: d6, start: 0.17, attack: 0.008, hold: 0, release: 0.14, gain: 1, glide: 1.1),
                .init(frequency: e5, start: 0.17, attack: 0.008, hold: 0, release: 0.10, gain: 0.3, glide: 1.1),
            ])

        case .breakStart:
            return Instrument.Recipe(peak: 0.35, partials: [
                .init(frequency: a3, start: 0, attack: 0.9, hold: 0.5, release: 1.7, gain: 1, glide: 0.985),
                .init(frequency: a3 + 0.6, start: 0, attack: 0.9, hold: 0.5, release: 1.7, gain: 0.35, glide: 0.985),
                .init(frequency: e4, start: 0.05, attack: 1.0, hold: 0.45, release: 1.7, gain: 0.7, glide: 0.985),
                .init(frequency: a4, start: 0.12, attack: 1.1, hold: 0.4, release: 1.8, gain: 0.45, glide: 0.985),
            ])

        case .skip:
            return Instrument.Recipe(peak: 0.4, partials: [
                .init(frequency: a2, start: 0, attack: 0.006, hold: 0.02, release: 0.5, gain: 1, glide: 1.03),
                .init(frequency: e3, start: 0, attack: 0.006, hold: 0.02, release: 0.35, gain: 0.5, glide: 1.03),
                .init(frequency: a3, start: 0, attack: 0.006, hold: 0.02, release: 0.25, gain: 0.25, glide: 1.03),
            ])

        case .breakEnd:
            return Instrument.Recipe(peak: 0.35, partials: [
                .init(frequency: a3, start: 0, attack: 0.12, hold: 0.3, release: 1.6, gain: 0.8),
                .init(frequency: e4, start: 0.1, attack: 0.12, hold: 0.3, release: 1.7, gain: 0.7),
                .init(frequency: a4, start: 0.2, attack: 0.12, hold: 0.3, release: 1.8, gain: 0.6),
                .init(frequency: e5, start: 0.32, attack: 0.15, hold: 0.25, release: 2.0, gain: 0.35),
            ])
        }
    }
}

// MARK: - Instrument

private enum Instrument {
    struct Partial {
        let frequency: Double
        let start: Double
        let attack: Double
        let hold: Double
        let release: Double
        let gain: Double
        /// Frequency multiplier at onset, easing to 1 over the attack. <1 rises into tune, >1 drops.
        var glide: Double = 1

        var end: Double { start + attack + hold + release }
    }

    struct Recipe {
        let peak: Float
        let partials: [Partial]
    }

    static func render(_ recipe: Recipe, sampleRate: Double) -> AVAudioPCMBuffer {
        let duration = recipe.partials.map(\.end).max() ?? 0
        let frameCount = Int(duration * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let out = buffer.floatChannelData![0]

        for partial in recipe.partials {
            var phase = 0.0
            let firstFrame = Int(partial.start * sampleRate)
            let length = Int((partial.attack + partial.hold + partial.release) * sampleRate)

            for i in 0..<length where firstFrame + i < frameCount {
                let t = Double(i) / sampleRate
                let envelope: Double
                if t < partial.attack {
                    envelope = (1 - exp(-4 * t / partial.attack)) / (1 - exp(-4))
                } else if t < partial.attack + partial.hold {
                    envelope = 1
                } else {
                    envelope = exp(-(t - partial.attack - partial.hold) / (partial.release / 4))
                }

                let settle = min(1, t / max(partial.attack, 0.001))
                let frequency = partial.frequency * (partial.glide + (1 - partial.glide) * settle)
                phase += 2 * .pi * frequency / sampleRate

                // The shared timbre: a sine with a little 2nd and 3rd harmonic for warmth.
                let sample = sin(phase) + 0.18 * sin(2 * phase) + 0.05 * sin(3 * phase)
                out[firstFrame + i] += Float(sample * envelope * partial.gain)
            }
        }

        var loudest: Float = 0
        for i in 0..<frameCount { loudest = max(loudest, abs(out[i])) }
        if loudest > 0 {
            let scale = recipe.peak / loudest
            for i in 0..<frameCount { out[i] *= scale }
        }
        return buffer
    }
}
