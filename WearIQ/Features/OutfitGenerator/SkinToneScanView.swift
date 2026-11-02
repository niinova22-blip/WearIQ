import AVFoundation
import OutfitRecommendationEngine
import SwiftUI
import Vision

/// Reads the skin's depth and undertone from the front camera, the way the body scan
/// reads the outline: the face is found, small patches of bare skin (forehead and both
/// cheeks) are averaged over about two seconds of frames, and the colour is classified
/// (see `SkinToneAnalyzer`). Nothing is stored or sent; only the result is kept.
struct SkinToneScanView: View {
    let onResult: (SkinToneAnalyzer.Reading) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = SkinToneScanModel()

    var body: some View {
        NavigationStack {
            ZStack {
                CameraPreview(session: model.camera.session)
                    .ignoresSafeArea()
                // Where the face goes.
                Ellipse()
                    .strokeBorder(model.faceFound ? Color.green : .white.opacity(0.8),
                                  style: StrokeStyle(lineWidth: 3, dash: model.faceFound ? [] : [8, 6]))
                    .frame(width: 230, height: 300)
                    .offset(y: -40)
                VStack {
                    Spacer()
                    VStack(spacing: 10) {
                        if let reading = model.reading {
                            Circle().fill(model.swatch).frame(width: 56, height: 56)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            Text("\(reading.depth.title) · \(reading.undertone.title)")
                                .font(.headline)
                            Button("Use this") {
                                onResult(reading)
                                dismiss()
                            }
                            .buttonStyle(.primary)
                            Button("Scan again") { model.restart() }
                                .font(.subheadline)
                        } else {
                            ProgressView(value: model.progress)
                                .tint(.green)
                            Text(model.faceFound ? "Hold still…" : "Fit your face in the oval")
                                .font(.headline)
                            Text("Daylight or a bright room, no filter or heavy make-up. Nothing is saved or sent.")
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(Theme.Spacing.m)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .padding(Theme.Spacing.m)
                }
            }
            .navigationTitle("Skin tone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await model.start() }
            .onDisappear { model.stop() }
        }
    }
}

@MainActor
@Observable
final class SkinToneScanModel {
    let camera = CameraController()
    var faceFound = false
    var progress = 0.0
    var reading: SkinToneAnalyzer.Reading?
    var swatch = Color.gray
    private var samples: [SIMD3<Double>] = []
    private let needed = 20

    func start() async {
        guard await CameraController.requestAccess() else { return }
        camera.frameRate = 10
        camera.onFrame = { [weak self] buffer in
            let sample = Self.skinColour(in: buffer)
            Task { @MainActor in self?.add(sample) }
        }
        try? await camera.start(position: .front)
    }

    func stop() {
        camera.onFrame = nil
        camera.stop()
    }

    func restart() {
        samples = []
        progress = 0
        reading = nil
    }

    private func add(_ sample: SIMD3<Double>?) {
        guard reading == nil else { return }
        faceFound = sample != nil
        guard let sample else { return }
        samples.append(sample)
        progress = Double(samples.count) / Double(needed)
        guard samples.count >= needed else { return }
        // Median per channel: a blink or a hand passing doesn't move it.
        func median(_ k: Int) -> Double { samples.map { $0[k] }.sorted()[samples.count / 2] }
        let rgb = SIMD3(median(0), median(1), median(2))
        reading = SkinToneAnalyzer.classify(red: rgb.x, green: rgb.y, blue: rgb.z)
        swatch = Color(red: rgb.x, green: rgb.y, blue: rgb.z)
        AppSounds.shared.play(.success)
    }

    /// Average colour (sRGB 0–1) of the forehead and both cheeks, or nil without a face
    /// or with one too dark or blown out to read.
    nonisolated static func skinColour(in buffer: CVPixelBuffer) -> SIMD3<Double>? {
        let request = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])) != nil,
              let face = request.results?.first?.boundingBox, face.width > 0.2 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        // Patches in face coordinates (x right, y up from the bottom of the box).
        let patches: [(Double, Double)] = [(0.5, 0.82), (0.27, 0.42), (0.73, 0.42)]
        var sum = SIMD3<Double>(0, 0, 0), count = 0.0
        let half = max(2, Int(face.width * Double(width) * 0.05))
        for (px, py) in patches {
            let cx = Int((face.minX + face.width * px) * Double(width))
            let cy = Int((1 - (face.minY + face.height * py)) * Double(height))
            for y in max(0, cy - half)..<min(height, cy + half) {
                for x in max(0, cx - half)..<min(width, cx + half) {
                    let p = pixels + y * row + x * 4  // BGRA
                    sum += SIMD3(Double(p[2]), Double(p[1]), Double(p[0])) / 255
                    count += 1
                }
            }
        }
        guard count > 0 else { return nil }
        let mean = sum / count
        let brightness = (mean.x + mean.y + mean.z) / 3
        return brightness > 0.12 && brightness < 0.95 ? mean : nil
    }
}
