import BodyMeasurementEngine
import Foundation
import Testing
@testable import WearIQ

@Suite struct ScanVoiceTests {
    /// The names must match scripts/generate_voice.py's (values printed by its key()).
    @Test func clipNamesMatchTheGenerator() {
        #expect(ScanVoice.name("Good.") == "voice_2c33dcef91e06624")
        #expect(ScanVoice.name("Güzel.") == "voice_766c629d8266718f")
        #expect(ScanVoice.name("Turn a little  further clockwise.") == "voice_aecd3beb521d10b4")
    }

    @Test func sentencesSplitLikeTheGenerator() {
        #expect(ScanVoice.sentences("Good. Keep turning: now.  Stop!") == ["Good.", "Keep turning:", "now.", "Stop!"])
        #expect(ScanVoice.sentences("3") == ["3"])
        #expect(ScanVoice.sentences("  ").isEmpty)
    }

    /// Every fixed line of the scan has a recorded clip, so nothing falls back to the
    /// choppy on-device synthesizer.
    @Test func everyScanLineIsRecorded() {
        var lines = (0..<StationScan.stationCount).map(StationGuide.instruction)
        lines += [PoseIssue.noPerson, .headNotVisible, .feetNotVisible, .tooClose, .tooFar, .notCentered,
                  .notFacingCamera, .armsTooCloseToBody, .notSideways].map(\.instruction)
        lines += ["3", "2", "1", String(localized: "Good.") + " " + StationGuide.instruction(3),
                  String(localized: "Scan complete. Your measurements are ready."),
                  String(localized: "One more look at \(2) position(s).")]
        for line in lines { #expect(ScanVoice.clips(for: line) != nil, "\(line)") }
    }
}
