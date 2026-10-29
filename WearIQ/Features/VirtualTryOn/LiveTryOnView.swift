import AVFoundation
import BodyMeasurementEngine
import BodyScanVision
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import SwiftUI
import Vision
import WearIQCore

/// Live try-on with the front camera, entirely on the device: the garment is lifted out
/// of the store's product photo (Vision foreground mask) and laid over the user's body
/// in every frame, stretched between their shoulders and hips (or hips and ankles for
/// trousers) as found by Vision's body pose. It follows the user as they move.
///
/// It shows how the garment's look and proportions sit on this body, not how the fabric
/// drapes: it is a 2D overlay, and the screen says so.
@MainActor
@Observable
final class LiveTryOnModel {
    enum Phase: Equatable {
        case preparing
        case live
        case failed(String)
    }

    private(set) var phase: Phase = .preparing
    private(set) var frame: CGImage?
    /// The user is too close, too far or not fully in view for the overlay.
    private(set) var hint: String?
    /// Garment width relative to the reference size (a larger size draws wider).
    var widthScale: Double = 1 {
        didSet { scale.set(widthScale) }
    }
    /// The same, readable from the camera queue where frames are drawn.
    private let scale = SharedValue(1.0)

    let camera = CameraController()
    private let category: GarmentCategory
    private var garment: Garment?
    private let renderer = Renderer()

    /// The garment cut out of the product photo, and the box it spans on the model.
    struct Garment: @unchecked Sendable {
        let image: CIImage
        /// Corners in the photo (Core Image coordinates, y up): top-left, top-right,
        /// bottom-left, bottom-right.
        let quad: [CGPoint]
    }

    init(category: GarmentCategory) {
        self.category = category
    }

    func start(imageURL: URL) async {
        guard let (data, _) = try? await URLSession.shared.data(from: imageURL),
              let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            phase = .failed(String(localized: "The product photo couldn't be loaded."))
            return
        }
        let category = category
        let garment = await Task.detached(priority: .userInitiated) { Self.prepare(source, category: category) }.value
        guard let garment else {
            phase = .failed(String(localized: "No person was found in the product photo, so the garment can't be lifted out of it. Try a product whose photo shows it worn."))
            return
        }
        self.garment = garment
        do {
            try await camera.start(position: .front)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .live
        let renderer = renderer
        let vision = VisionBodyAnalyzer()
        let scale = scale
        camera.frameRate = 15
        // Pose and drawing run on the camera queue; only the finished frame goes to the UI.
        camera.onFrame = { [weak self] buffer in
            let joints = vision.detectJoints(in: buffer)
            let (image, hint) = renderer.compose(buffer: buffer, joints: joints, garment: garment,
                                                 category: category, widthScale: scale.get())
            Task { @MainActor in
                self?.frame = image
                self?.hint = hint
            }
        }
    }

    func stop() {
        camera.onFrame = nil
        camera.stop()
    }

    // MARK: Preparing the garment

    /// Lifts the person (and so the garment) out of the photo and finds the garment's box
    /// from the model's pose.
    nonisolated static func prepare(_ photo: CIImage, category: GarmentCategory) -> Garment? {
        let context = CIContext()
        guard let cg = context.createCGImage(photo, from: photo.extent) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        let pose = VNDetectHumanBodyPoseRequest()
        let foreground = VNGenerateForegroundInstanceMaskRequest()
        try? handler.perform([pose, foreground])
        guard let body = pose.results?.first, let points = try? body.recognizedPoints(.all) else { return nil }
        let w = photo.extent.width, h = photo.extent.height
        var joints: [BodyJoint: CGPoint] = [:]
        let names: [(VNHumanBodyPoseObservation.JointName, BodyJoint)] = [
            (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder), (.neck, .neck),
            (.leftHip, .leftHip), (.rightHip, .rightHip), (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle),
        ]
        for (name, joint) in names {
            guard let p = points[name], p.confidence >= 0.3 else { continue }
            // Vision's normalised points have y up, like Core Image.
            joints[joint] = CGPoint(x: p.location.x * w, y: p.location.y * h)
        }
        guard let quad = Renderer.quad(joints, category: category) else { return nil }

        var image = photo
        if let observation = foreground.results?.first,
           let masked = try? observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                             croppedToInstancesExtent: false) {
            image = CIImage(cvPixelBuffer: masked)
        }
        return Garment(image: image, quad: quad)
    }
}

/// A value shared between the main actor and the camera queue.
private final class SharedValue: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ value: Double) { self.value = value }
    func get() -> Double { lock.withLock { value } }
    func set(_ v: Double) { lock.withLock { value = v } }
}

/// Places the garment on each camera frame.
private final class Renderer: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var smoothed: [CGPoint]?

    /// The garment's box from body joints (Core Image coordinates, y up): tops span the
    /// shoulders (widened for the sleeves) down past the hips; trousers the hips to below
    /// the ankles.
    static func quad(_ j: [BodyJoint: CGPoint], category: GarmentCategory) -> [CGPoint]? {
        switch category {
        case .pants:
            guard let lh = j[.leftHip], let rh = j[.rightHip], let la = j[.leftAnkle], let ra = j[.rightAnkle] else { return nil }
            let hipWidth = abs(rh.x - lh.x), legLength = ((lh.y + rh.y) - (la.y + ra.y)) / 2
            let (left, right) = lh.x < rh.x ? (lh, rh) : (rh, lh)
            let (leftAnkle, rightAnkle) = la.x < ra.x ? (la, ra) : (ra, la)
            let spread = hipWidth * 0.45, rise = legLength * 0.12, hem = legLength * 0.06
            return [CGPoint(x: left.x - spread, y: left.y + rise), CGPoint(x: right.x + spread, y: right.y + rise),
                    CGPoint(x: leftAnkle.x - spread, y: leftAnkle.y - hem), CGPoint(x: rightAnkle.x + spread, y: rightAnkle.y - hem)]
        default:
            guard let ls = j[.leftShoulder], let rs = j[.rightShoulder], let lh = j[.leftHip], let rh = j[.rightHip] else { return nil }
            let (left, right) = ls.x < rs.x ? (ls, rs) : (rs, ls)
            let (leftHip, rightHip) = lh.x < rh.x ? (lh, rh) : (rh, lh)
            let shoulder = abs(right.x - left.x), torso = ((ls.y + rs.y) - (lh.y + rh.y)) / 2
            let sleeve = shoulder * 0.35, collar = torso * 0.12, hem = torso * (category == .jacket ? 0.3 : 0.18)
            return [CGPoint(x: left.x - sleeve, y: left.y + collar), CGPoint(x: right.x + sleeve, y: right.y + collar),
                    CGPoint(x: leftHip.x - sleeve * 0.6, y: leftHip.y - hem), CGPoint(x: rightHip.x + sleeve * 0.6, y: rightHip.y - hem)]
        }
    }

    func compose(buffer: CVPixelBuffer, joints: [BodyJoint: DetectedJoint], garment: LiveTryOnModel.Garment,
                 category: GarmentCategory, widthScale: Double) -> (CGImage?, String?) {
        let camera = CIImage(cvPixelBuffer: buffer)
        let w = camera.extent.width, h = camera.extent.height
        // Detected joints are normalised with y down; Core Image has y up.
        let points = joints.filter { $0.value.confidence >= 0.3 }
            .mapValues { CGPoint(x: $0.point.x * w, y: (1 - $0.point.y) * h) }
        var hint: String?
        var output = camera
        if var target = Self.quad(points, category: category) {
            // A larger size is drawn wider about the body's centre line.
            let centre = target.map(\.x).reduce(0, +) / 4
            target = target.map { CGPoint(x: centre + ($0.x - centre) * widthScale, y: $0.y) }
            // Smooth the corners so the garment doesn't shiver with the pose estimate.
            if let previous = smoothed, previous.count == 4 {
                target = zip(previous, target).map { CGPoint(x: $0.x * 0.55 + $1.x * 0.45, y: $0.y * 0.55 + $1.y * 0.45) }
            }
            smoothed = target
            output = place(garment, on: target).composited(over: camera)
        } else {
            smoothed = nil
            hint = category == .pants
                ? String(localized: "Step back until your hips and ankles are in view.")
                : String(localized: "Step back until your shoulders and hips are in view.")
        }
        // Half resolution is plenty for the screen and keeps it smooth.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        return (context.createCGImage(scaled, from: scaled.extent), hint)
    }

    /// The garment's box warped onto the target corners.
    private func place(_ garment: LiveTryOnModel.Garment, on target: [CGPoint]) -> CIImage {
        let q = garment.quad
        let box = CGRect(x: min(q[0].x, q[2].x), y: min(q[2].y, q[3].y),
                         width: max(q[1].x, q[3].x) - min(q[0].x, q[2].x),
                         height: max(q[0].y, q[1].y) - min(q[2].y, q[3].y))
        let cropped = garment.image.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = cropped
        filter.topLeft = target[0]
        filter.topRight = target[1]
        filter.bottomLeft = target[2]
        filter.bottomRight = target[3]
        return filter.outputImage ?? cropped
    }
}

/// The live try-on screen.
struct LiveTryOnView: View {
    let imageURL: URL
    let category: GarmentCategory
    /// Size labels and how much wider each is than the size the model wears.
    let sizes: [(label: String, widthScale: Double)]
    @State var selectedSize: String?
    @State private var model: LiveTryOnModel
    @Environment(\.dismiss) private var dismiss

    init(imageURL: URL, category: GarmentCategory, sizes: [(label: String, widthScale: Double)], selectedSize: String?) {
        self.imageURL = imageURL
        self.category = category
        self.sizes = sizes
        _selectedSize = State(initialValue: selectedSize)
        _model = State(initialValue: LiveTryOnModel(category: category))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let frame = model.frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.largeTitle).symbolRenderingMode(.hierarchical)
                    }
                    .tint(.white)
                    .accessibilityLabel(Text("Close"))
                }
                Spacer()
                bottom
            }
            .padding(Theme.Spacing.m)
        }
        .task {
            apply(selectedSize)
            await model.start(imageURL: imageURL)
        }
        .onDisappear { model.stop() }
        .onChange(of: selectedSize) { _, size in apply(size) }
    }

    @ViewBuilder
    private var bottom: some View {
        VStack(spacing: Theme.Spacing.s) {
            switch model.phase {
            case .preparing:
                HStack { ProgressView().tint(.white); Text("Preparing the garment…") }
                    .foregroundStyle(.white)
            case let .failed(message):
                Text(message).foregroundStyle(.white).multilineTextAlignment(.center)
            case .live:
                if let hint = model.hint {
                    Text(hint).font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
                }
                if sizes.count > 1 {
                    Picker("Size", selection: $selectedSize) {
                        ForEach(sizes, id: \.label) { Text($0.label).tag(String?.some($0.label)) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            Text("Preview: the product photo laid over you. It shows look and proportions, not how the fabric drapes. The camera image stays on this phone.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.m)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func apply(_ size: String?) {
        model.widthScale = sizes.first { $0.label == size }?.widthScale ?? 1
    }
}

extension LiveTryOnView {
    /// Width of each size relative to the reference size (the model's, else the
    /// recommended one), from the chart's chest (tops) or hip/waist (trousers).
    static func widthScales(spec: GarmentSpec?, reference: String?) -> [(label: String, widthScale: Double)] {
        guard let spec else { return [] }
        let dim: GarmentDimension = spec.category == .pants ? (spec.sizes.contains { $0.values[.hip] != nil } ? .hip : .waist) : .chest
        guard let ref = spec.sizes.first(where: { $0.label == reference })?.values[dim]?.cm ?? spec.sizes.first?.values[dim]?.cm,
              ref > 0 else { return spec.sizes.map { ($0.label, 1) } }
        return spec.sizes.map { size in (size.label, (size.values[dim]?.cm).map { min(1.3, max(0.75, $0 / ref)) } ?? 1) }
    }
}
