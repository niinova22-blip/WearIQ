import AVFoundation
import CryptoKit

/// Voice and sound cues for the hands-free scan.
///
/// Every fixed line the scan says is a recorded clip bundled with the app (see
/// `ScanVoice` and scripts/generate_voice.py), played gaplessly through our own
/// `AVAudioEngine`: synthesising on the phone came out choppy. Text without clips (an
/// error's own description) falls back to the system synthesizer:
/// it is rendered with `AVSpeechSynthesizer.write` and played through the same engine,
/// together with the cue tones. Letting the synthesizer play by itself
/// proved unreliable: stopping and restarting it a few times a second (live pose
/// feedback) silently drops utterances, and on some iOS 17 builds it stops producing
/// sound altogether. If rendering yields nothing, the synthesizer's own playback is
/// tried as a fallback. The session uses `.playback` so cues are heard in silent mode.
@MainActor
final class ScanAudio {
    enum Priority {
        /// Dropped while something else is being said.
        case normal
        /// Cuts off whatever is being said.
        case high
    }

    enum Cue {
        case tick
        case go
        /// One of the ring's sectors filled; pitch rises around the ring.
        case sector(Int)
        /// A body region was measured from every direction.
        case region
        case success
        case problem
    }

    var isEnabled = true {
        didSet { if !isEnabled { silence() } }
    }

    private let engine = AVAudioEngine()
    private let speechPlayer = AVAudioPlayerNode()
    private let clipPlayer = AVAudioPlayerNode()
    private let tonePlayer = AVAudioPlayerNode()
    private let speechFormat = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
    private let toneFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let renderer = AVSpeechSynthesizer()
    private let fallback = AVSpeechSynthesizer()
    private var converters: [String: AVAudioConverter] = [:]
    private var generation = 0
    /// Last utterance whose rendering produced audio.
    private var renderedGeneration = -1
    private var speakingUntil = Date.distantPast
    private var configured = false
    private var observers: [NSObjectProtocol] = []

    init() {
        engine.attach(speechPlayer)
        engine.attach(clipPlayer)
        engine.attach(tonePlayer)
        engine.connect(speechPlayer, to: engine.mainMixerNode, format: speechFormat)
        engine.connect(clipPlayer, to: engine.mainMixerNode, format: ScanVoice.format)
        engine.connect(tonePlayer, to: engine.mainMixerNode, format: toneFormat)
        renderer.usesApplicationAudioSession = true
        fallback.usesApplicationAudioSession = true
    }

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? session.setActive(true)
        if !configured {
            configured = true
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ensureRunning() }
            })
            observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
                guard type == .ended else { return }
                MainActor.assumeIsolated { self?.ensureRunning() }
            })
        }
        ensureRunning()
    }

    func stop() {
        silence()
        engine.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        configured = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var isSpeaking: Bool { Date() < speakingUntil }

    func say(_ text: String, priority: Priority = .normal) {
        guard isEnabled else { return }
        if priority == .normal, isSpeaking { return }
        ensureRunning()
        silenceSpeech()
        if let clips = ScanVoice.clips(for: text) {
            var seconds = 0.0
            for clip in clips {
                clipPlayer.scheduleFile(clip, at: nil, completionHandler: nil)
                seconds += Double(clip.length) / clip.processingFormat.sampleRate
            }
            clipPlayer.play()
            speakingUntil = Date().addingTimeInterval(seconds + 0.1)
            return
        }
        generation += 1
        let token = generation
        // Rough length so normal-priority lines don't talk over this one before it renders.
        speakingUntil = Date().addingTimeInterval(0.4 + Double(text.count) * 0.06)

        renderer.write(utterance(text)) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.generation else { return }
                    self.renderedGeneration = token
                    self.schedule(pcm, token: token)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.generation, self.renderedGeneration != token else { return }
                self.renderer.stopSpeaking(at: .immediate)
                self.fallback.speak(self.utterance(text))
            }
        }
    }

    func play(_ cue: Cue) {
        guard isEnabled else { return }
        ensureRunning()
        guard let buffer = Self.render(cue, format: toneFormat) else { return }
        tonePlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !tonePlayer.isPlaying { tonePlayer.play() }
    }

    private func silence() {
        silenceSpeech()
        tonePlayer.stop()
    }

    private func silenceSpeech() {
        generation += 1
        renderer.stopSpeaking(at: .immediate)
        fallback.stopSpeaking(at: .immediate)
        speechPlayer.stop()
        clipPlayer.stop()
        speakingUntil = .distantPast
    }

    private func ensureRunning() {
        guard !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.prepare()
        try? engine.start()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, token: Int) {
        guard let converted = convert(buffer) else { return }
        speechPlayer.scheduleBuffer(converted, at: nil, options: [], completionHandler: nil)
        if !speechPlayer.isPlaying { speechPlayer.play() }
        let seconds = Double(converted.frameLength) / speechFormat.sampleRate
        speakingUntil = max(speakingUntil, Date()).addingTimeInterval(seconds)
    }

    /// Synthesizer output varies by voice (16-bit or float, 16–24 kHz); the player takes one format.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let input = buffer.format
        if input == speechFormat { return buffer }
        let key = "\(input.commonFormat.rawValue)-\(input.sampleRate)-\(input.channelCount)-\(input.isInterleaved)"
        let converter = converters[key] ?? AVAudioConverter(from: input, to: speechFormat)
        guard let converter else { return nil }
        converters[key] = converter
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * speechFormat.sampleRate / input.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    private func utterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        // A little slower and lower than the default sounds calmer and more natural.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 0.95
        return utterance
    }

    /// The most natural installed voice in the language the app is shown in (so the
    /// voice matches the on-screen text): premium, then enhanced (Siri-quality voices the
    /// user may have downloaded), then any.
    private static let voice: AVSpeechSynthesisVoice? = {
        let appLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(appLanguage) && !$0.voiceTraits.contains(.isNoveltyVoice)
                && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? voices.first
            ?? AVSpeechSynthesisVoice(language: appLanguage)
    }()

    // MARK: Tones

    /// Short, soft sine tones with a quick attack and exponential decay.
    private static func render(_ cue: Cue, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // (frequency Hz, start s, length s)
        let notes: [(Double, Double, Double)]
        switch cue {
        case .tick: notes = [(880, 0, 0.09)]
        case .go: notes = [(1320, 0, 0.22)]
        case let .sector(n):
            // Major pentatonic from C5 upwards, one step per sector.
            let steps = [0, 2, 4, 7, 9]
            let semitone = steps[n % 5] + 12 * (n / 5)
            notes = [(523.25 * pow(2, Double(semitone) / 12), 0, 0.14)]
        case .region: notes = [(659.25, 0, 0.12), (987.77, 0.09, 0.2)]
        case .success: notes = [(523.25, 0, 0.18), (659.25, 0.12, 0.18), (783.99, 0.24, 0.18), (1046.5, 0.36, 0.45)]
        case .problem: notes = [(392, 0, 0.16), (311.13, 0.14, 0.26)]
        }
        let rate = format.sampleRate
        let total = notes.map { $0.1 + $0.2 }.max() ?? 0
        let frames = AVAudioFrameCount(total * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { samples[i] = 0 }
        for (frequency, start, length) in notes {
            let first = Int(start * rate), count = Int(length * rate)
            for i in 0..<count where first + i < Int(frames) {
                let t = Double(i) / rate
                let envelope = min(1, t / 0.005) * exp(-t * 5 / length)
                // A quiet octave overtone makes it sound less like a test tone.
                let wave = sin(2 * .pi * frequency * t) + 0.25 * sin(4 * .pi * frequency * t)
                samples[first + i] += Float(0.32 * envelope * wave)
            }
        }
        return buffer
    }
}

/// The recorded voice: one clip per sentence, named by a hash of its text.
enum ScanVoice {
    /// The clips' format after decoding (24 kHz mono, see scripts/generate_voice.py).
    static let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    /// Clips for every sentence of `text`, in order, or nil if any sentence has none.
    static func clips(for text: String) -> [AVAudioFile]? {
        let parts = sentences(text)
        guard !parts.isEmpty else { return nil }
        var files: [AVAudioFile] = []
        for part in parts {
            guard let url = Bundle.main.url(forResource: name(part), withExtension: "m4a"),
                  let file = try? AVAudioFile(forReading: url),
                  file.processingFormat.sampleRate == format.sampleRate,
                  file.processingFormat.channelCount == 1 else { return nil }
            files.append(file)
        }
        return files
    }

    /// Split after . ! ? : followed by whitespace, as the generator splits.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var previous: Character?
        for c in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if c.isWhitespace, let p = previous, ".!?:".contains(p) {
                if !current.isEmpty { out.append(current) }
                current = ""
            } else if !(c.isWhitespace && current.isEmpty) {
                current.append(c)
            }
            previous = c
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// "voice_" and the first 16 hex digits of the SHA-256 of the NFC sentence with
    /// whitespace collapsed.
    static func name(_ sentence: String) -> String {
        let collapsed = sentence.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let digest = SHA256.hash(data: Data(collapsed.precomposedStringWithCanonicalMapping.utf8))
        return "voice_" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
