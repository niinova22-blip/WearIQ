import CoreGraphics
import Vision

/// Whether the camera's lens looks smudged (iOS 26, A14 and later): a greasy front camera
/// blurs the outline the measurement is read from. Checked once while positioning; the
/// scan goes on either way, the user is only told to wipe it.
enum LensCheck {
    /// Vision's confidence above which the lens is called smudged (1 = surely smudged).
    static let threshold: Float = 0.85

    nonisolated static func isSmudged(_ image: CGImage) async -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard let observation = try? await DetectLensSmudgeRequest().perform(on: image, orientation: nil) else { return false }
        return observation.confidence >= threshold
    }
}
