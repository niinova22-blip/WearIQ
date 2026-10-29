import AVFoundation
import SwiftUI

/// Small interface sounds: a soft tick on main buttons, a chime when a result is ready,
/// a low note for problems. Short synthesised tones through the ambient audio session,
/// so they respect the silent switch and mix with music. Off in Profile → Sounds.
@MainActor
final class AppSounds {
    static let shared = AppSounds()

    enum Sound {
        case tick, success, saved, problem
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private var started = false

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "soundsEnabled") as? Bool ?? true
    }

    func play(_ sound: Sound) {
        guard Self.isEnabled else { return }
        if !started || !engine.isRunning {
            // The scan's voice guidance uses playback (audible in silent mode); don't undo that.
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback { try? session.setCategory(.ambient, options: [.mixWithOthers]) }
            engine.prepare()
            started = (try? engine.start()) != nil
            guard started else { return }
        }
        guard let buffer = buffers[sound] ?? render(sound) else { return }
        buffers[sound] = buffer
        player.scheduleBuffer(buffer, at: nil)
        if !player.isPlaying { player.play() }
    }

    /// (frequency Hz, start s, length s, level)
    private func notes(_ sound: Sound) -> [(Double, Double, Double, Double)] {
        switch sound {
        case .tick: [(1800, 0, 0.03, 0.12)]
        case .success: [(784, 0, 0.12, 0.22), (1046.5, 0.09, 0.22, 0.22)]
        case .saved: [(659.25, 0, 0.1, 0.18), (987.77, 0.07, 0.16, 0.18)]
        case .problem: [(392, 0, 0.14, 0.2), (329.63, 0.11, 0.2, 0.2)]
        }
    }

    private func render(_ sound: Sound) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let parts = notes(sound)
        let frames = AVAudioFrameCount((parts.map { $0.1 + $0.2 }.max() ?? 0) * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { samples[i] = 0 }
        for (frequency, start, length, level) in parts {
            let first = Int(start * rate)
            for i in 0..<Int(length * rate) where first + i < Int(frames) {
                let t = Double(i) / rate
                let envelope = min(1, t / 0.004) * exp(-t * 6 / length)
                samples[first + i] += Float(level * envelope * sin(2 * .pi * frequency * t))
            }
        }
        return buffer
    }
}

/// Tiles and cards that shrink slightly and tap when pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}
