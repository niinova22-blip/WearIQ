import ARKit
import BodyMeasurementEngine
import BodyScanVision
import CoreImage
import Observation
import SwiftUI

/// Measures a standing person's height with ARKit, as a real-world scale that doesn't
/// rely on the typed height (`FloorScale`). Someone holds the phone (back camera)
/// 2–3 m from the person: first the floor is found, then each third of a second the
/// person's silhouette is found and its feet and head are measured against the floor
/// plane. Frames where ARKit isn't tracking normally are left out. Where the phone has
/// a LiDAR, its distance to the body is kept as a check on the camera geometry; the
/// LiDAR is never required.
@MainActor
@Observable
final class ARScaleSession: NSObject, ARSessionDelegate {
    enum Stage: Equatable {
        case unsupported
        case searchingFloor
        case findPerson
        case measuring
        case done
    }

    /// What one frame gave.
    struct Sample: Sendable {
        var statureCm: Double?
        var distanceM: Double?
        var lidarDistanceM: Double?
        var cutOff = false
    }

    let session = ARSession()
    private(set) var stage: Stage = .searchingFloor
    private(set) var floorY: Double?
    private(set) var floorClassified = false
    private(set) var trackingNote: String?
    private(set) var lastStature: Double?
    private(set) var lastDistance: Double?
    private(set) var personCutOff = false
    private(set) var statures: [Double] = []
    private var distances: [Double] = []
    private var lidar: [Double] = []
    private var framesSeen = 0
    private var framesNormal = 0
    private var busy = false
    private var lastProcessed = Date.distantPast
    private let typedHeightCm: Double
    static let samplesNeeded = 15

    nonisolated(unsafe) private static let context = CIContext()

    init(typedHeightCm: Double) {
        self.typedHeightCm = typedHeightCm
        super.init()
    }

    var result: ARScaleReading? {
        guard let combined = FloorScale.combine(statures) else { return nil }
        func median(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.sorted()[v.count / 2] }
        return ARScaleReading(statureCm: combined.cm, sdCm: combined.sdCm, distanceM: median(distances) ?? 0,
                              samples: statures.count, lidarDistanceM: median(lidar),
                              trackingNormalShare: framesSeen > 0 ? Double(framesNormal) / Double(framesSeen) : 0,
                              floorClassified: floorClassified)
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            stage = .unsupported
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() { session.pause() }

    func measureAgain() {
        statures = []; distances = []; lidar = []
        framesSeen = 0; framesNormal = 0
        stage = floorY == nil ? .searchingFloor : .findPerson
    }

    // MARK: ARSessionDelegate (called on the main queue)

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        MainActor.assumeIsolated { self.updateFloor(anchors) }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated { self.updateFloor(anchors) }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { self.handle(frame) }
    }

    /// The floor: the lowest horizontal plane at least 30 cm under the camera, one ARKit
    /// calls a floor preferred.
    private func updateFloor(_ anchors: [ARAnchor]) {
        let cameraY = session.currentFrame.map { Double($0.camera.transform.columns.3.y) }
        for case let plane as ARPlaneAnchor in anchors where plane.alignment == .horizontal {
            let y = Double(plane.transform.columns.3.y)
            if let cameraY, y > cameraY - 0.3 { continue }
            var isFloor = false
            if ARPlaneAnchor.isClassificationSupported, case .floor = plane.classification { isFloor = true }
            if floorY == nil || (isFloor && !floorClassified) || (isFloor == floorClassified && y < floorY!) {
                floorY = y
                floorClassified = isFloor
            }
        }
        if floorY != nil, stage == .searchingFloor { stage = .findPerson }
    }

    private func handle(_ frame: ARFrame) {
        guard stage == .findPerson || stage == .measuring else { return }
        framesSeen += 1
        switch frame.camera.trackingState {
        case .normal:
            framesNormal += 1
            trackingNote = nil
        case .limited(.excessiveMotion): trackingNote = String(localized: "Move the phone more slowly.")
        case .limited(.insufficientFeatures): trackingNote = String(localized: "Too little detail in view; more light helps.")
        case .limited: trackingNote = String(localized: "Tracking is limited for a moment.")
        case .notAvailable: trackingNote = String(localized: "Tracking isn't available.")
        }
        guard case .normal = frame.camera.trackingState, let floorY, !busy,
              Date().timeIntervalSince(lastProcessed) > 0.3 else { return }
        busy = true
        lastProcessed = Date()
        let camera = Self.cameraModel(frame.camera)
        let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let depth = frame.smoothedSceneDepth?.depthMap
        let typed = typedHeightCm
        Task.detached(priority: .userInitiated) {
            let sample = Self.measure(image: image, camera: camera, floorY: floorY, typedHeightCm: typed, depth: depth)
            await MainActor.run { self.accept(sample) }
        }
    }

    private func accept(_ sample: Sample?) {
        busy = false
        guard stage == .findPerson || stage == .measuring else { return }
        personCutOff = sample?.cutOff ?? false
        guard let sample, let stature = sample.statureCm else {
            lastStature = nil
            return
        }
        lastStature = stature
        lastDistance = sample.distanceM
        stage = .measuring
        statures.append(stature)
        if let d = sample.distanceM { distances.append(d) }
        if let l = sample.lidarDistanceM { lidar.append(l) }
        if statures.count >= Self.samplesNeeded { stage = .done }
    }

    // MARK: Off the main thread

    nonisolated static func cameraModel(_ camera: ARCamera) -> ARCameraModel {
        let k = camera.intrinsics, t = camera.transform
        let columns = [t.columns.0, t.columns.1, t.columns.2, t.columns.3]
        return ARCameraModel(fx: Double(k.columns.0.x), fy: Double(k.columns.1.y),
                             cx: Double(k.columns.2.x), cy: Double(k.columns.2.y),
                             sensorWidth: Double(camera.imageResolution.width), sensorHeight: Double(camera.imageResolution.height),
                             transform: columns.flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] })
    }

    nonisolated static func measure(image: CIImage, camera: ARCameraModel, floorY: Double, typedHeightCm: Double,
                                    depth: CVPixelBuffer?) -> Sample? {
        guard let cg = context.createCGImage(image, from: image.extent),
              let frame = VisionBodyAnalyzer().turnFrame(cg, time: 0),
              let points = SilhouetteKeyPoints.find(frame.mask, centerX: frame.centerX) else { return nil }
        if points.cutOff { return Sample(cutOff: true) }
        // Mask pixels to the upright picture's pixels.
        let sx = camera.portraitWidth / Double(frame.mask.width), sy = camera.portraitHeight / Double(frame.mask.height)
        guard let reading = FloorScale.measure(camera: camera, floorY: floorY,
                                               feet: (points.feetU * sx, points.feetV * sy),
                                               head: (points.headU * sx, points.headV * sy),
                                               setbackM: FloorScale.footSetback(statureCm: typedHeightCm)) else { return nil }
        var sample = Sample(statureCm: reading.statureCm, distanceM: reading.distanceM)
        if let depth { sample.lidarDistanceM = lidarDistance(depth, mask: frame.mask, points: points, camera: camera) }
        return sample
    }

    /// The LiDAR's median depth over the torso (40–55% of the way down the silhouette),
    /// metres; the camera looks almost level, so depth ≈ distance to the body's front.
    nonisolated static func lidarDistance(_ depth: CVPixelBuffer, mask: BinaryMask, points: SilhouetteKeyPoints,
                                          camera: ARCameraModel) -> Double? {
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let dw = CVPixelBufferGetWidth(depth), dh = CVPixelBufferGetHeight(depth), row = CVPixelBufferGetBytesPerRow(depth)
        let sx = camera.portraitWidth / Double(mask.width), sy = camera.portraitHeight / Double(mask.height)
        let body = points.feetV - points.headV
        var values: [Double] = []
        for y in stride(from: Int(points.headV + 0.40 * body), to: Int(points.headV + 0.55 * body), by: 2) {
            for x in stride(from: 0, to: mask.width, by: 2) where mask[x, y] {
                let sensor = camera.sensorPixel(u: Double(x) * sx, v: Double(y) * sy)
                let px = Int(sensor.x / camera.sensorWidth * Double(dw)), py = Int(sensor.y / camera.sensorHeight * Double(dh))
                guard px >= 0, px < dw, py >= 0, py < dh else { continue }
                let d = base.load(fromByteOffset: py * row + px * 4, as: Float32.self)
                if d.isFinite, d > 0.3 { values.append(Double(d)) }
            }
        }
        guard values.count >= 20 else { return nil }
        return values.sorted()[values.count / 2]
    }
}

/// The camera feed ARKit is tracking.
struct ARCameraFeed: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = false
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {}
}

/// "Measure height with ARKit": one person holds the phone, the other stands; the
/// height measured from the floor is kept with the validation record.
@MainActor
struct ARHeightCheckView: View {
    @Binding var record: ValidationRecord
    @State private var model: ARScaleSession
    @Environment(\.dismiss) private var dismiss

    init(record: Binding<ValidationRecord>) {
        _record = record
        _model = State(initialValue: ARScaleSession(typedHeightCm: record.wrappedValue.heightCm))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ARCameraFeed(session: model.session).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                Text(instruction).font(.headline)
                if let note = model.trackingNote { Text(note).foregroundStyle(.orange) }
                if model.personCutOff { Text("Head or feet are out of the picture: step back.").foregroundStyle(.orange) }
                if let s = model.lastStature, let d = model.lastDistance, model.stage != .done {
                    Text(String(format: "%.1f cm · %.2f m", s, d)).font(.subheadline.monospacedDigit())
                }
                if model.stage == .measuring {
                    ProgressView(value: Double(model.statures.count), total: Double(ARScaleSession.samplesNeeded))
                }
                if model.stage == .done, let result = model.result {
                    Text(String(format: "%.1f ± %.1f cm", result.statureCm, result.sdCm)).font(.title2.monospacedDigit().bold())
                    Text("Typed height: \(Int(record.heightCm.rounded())) cm · distance \(String(format: "%.2f", result.distanceM)) m")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let l = result.lidarDistanceM {
                        Text("LiDAR to the body's front: \(String(format: "%.2f", l)) m").font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Measure again") { model.measureAgain() }.buttonStyle(.bordered)
                        Spacer()
                        Button("Save to this scan") {
                            record.arScale = result
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
        .navigationTitle("Height with ARKit")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var instruction: String {
        switch model.stage {
        case .unsupported: String(localized: "This device doesn't support ARKit world tracking.")
        case .searchingFloor: String(localized: "Point the camera at the floor and move it slowly until the floor is found.")
        case .findPerson: String(localized: "Floor found. Now point at the person: whole body in view, 2–3 m away, standing straight, arms by the sides.")
        case .measuring: String(localized: "Measuring… hold the phone steady.")
        case .done: String(localized: "Measured height")
        }
    }
}
