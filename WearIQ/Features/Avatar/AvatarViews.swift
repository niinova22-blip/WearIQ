import AvatarEngine
import FitEngine
import ProductMeasurementParser
import SceneKit
import SwiftData
import SwiftUI
import WearIQCore

/// Renders an `Avatar` with SceneKit: drag to turn it, pinch to zoom. A matte grey body
/// under a soft key light with ambient occlusion and a contact shadow on the floor, the
/// garment's stitch lines as faint dashes, and labelled body points (see
/// `LandmarkLabels`) that follow the avatar as it turns. Body and garment geometry are
/// swapped in place, so the camera stays where the user put it. With `fitMap` the
/// garment is coloured by how it sits: blue loose, green resting on the body, yellow
/// tight, red pulling past what the fabric gives.
struct AvatarSceneView: UIViewRepresentable {
    let avatar: Avatar
    var fitMap = false
    /// Text for each body point; nil leaves it unlabelled.
    var labels: [Avatar.Landmark.Kind: String] = [:]
    @ObservedObject var labelModel: LandmarkLabels

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.scene = context.coordinator.scene
        view.delegate = context.coordinator
        context.coordinator.update(avatar, fitMap: fitMap, labels: labels, model: labelModel, in: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(avatar, fitMap: fitMap, labels: labels, model: labelModel, in: view)
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let scene = SCNScene()
        private let bodyNode = SCNNode()
        private let garmentNode = SCNNode()
        private let seamNode = SCNNode()
        private var placedCamera = false
        private var shownMesh: (Int, Int, Bool)?
        // Read on the render thread.
        private let lock = NSLock()
        private var landmarks: [(Avatar.Landmark, String)] = []
        private weak var model: LandmarkLabels?

        override init() {
            super.init()
            scene.rootNode.addChildNode(bodyNode)
            scene.rootNode.addChildNode(garmentNode)
            scene.rootNode.addChildNode(seamNode)
            // Soft key light from the front left, casting a blurred shadow.
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 800
            key.light?.castsShadow = true
            key.light?.shadowMode = .deferred
            key.light?.shadowSampleCount = 16
            key.light?.shadowRadius = 10
            key.light?.shadowColor = UIColor(white: 0, alpha: 0.28)
            key.light?.orthographicScale = 1.4
            key.eulerAngles = SCNVector3(-1.0, 0.45, 0)
            scene.rootNode.addChildNode(key)
            // Rim light from behind, so the outline reads against the background.
            let rim = SCNNode()
            rim.light = SCNLight()
            rim.light?.type = .directional
            rim.light?.intensity = 420
            rim.eulerAngles = SCNVector3(-0.35, .pi * 0.85, 0)
            scene.rootNode.addChildNode(rim)
            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .ambient
            fill.light?.intensity = 380
            fill.light?.color = UIColor(red: 0.93, green: 0.95, blue: 1, alpha: 1)
            scene.rootNode.addChildNode(fill)
            // A floor that only shows the shadow.
            let floor = SCNFloor()
            floor.reflectivity = 0
            let floorMaterial = SCNMaterial()
            floorMaterial.lightingModel = .shadowOnly
            floor.materials = [floorMaterial]
            scene.rootNode.addChildNode(SCNNode(geometry: floor))
        }

        @MainActor
        func update(_ avatar: Avatar, fitMap: Bool, labels: [Avatar.Landmark.Kind: String], model: LandmarkLabels, in view: SCNView) {
            self.model = model
            let key = (avatar.body.positions.count, avatar.garment?.positions.count ?? 0, fitMap)
            if shownMesh.map({ $0 != key }) ?? true {
                shownMesh = key
                bodyNode.geometry = Self.geometry(avatar.body, color: UIColor(red: 0.8, green: 0.81, blue: 0.83, alpha: 1), roughness: 0.92)
                garmentNode.geometry = avatar.garment.map {
                    fitMap
                        ? Self.geometry($0, color: .white, roughness: 0.9, doubleSided: true, colors: $0.strain.map(Self.fitColor))
                        : Self.geometry($0, color: UIColor(red: 0.24, green: 0.3, blue: 0.44, alpha: 1), roughness: 0.88, doubleSided: true)
                }
                seamNode.geometry = Self.stitches(avatar.seams)
            }
            lock.lock()
            landmarks = avatar.landmarks.compactMap { l in labels[l.kind].map { (l, $0) } }
            lock.unlock()
            if !placedCamera {
                placedCamera = true
                let height = avatar.body.maxY
                let camera = SCNNode()
                camera.camera = SCNCamera()
                camera.camera?.fieldOfView = 34
                camera.camera?.screenSpaceAmbientOcclusionIntensity = 0.9
                camera.camera?.screenSpaceAmbientOcclusionRadius = 0.08
                camera.position = SCNVector3(0, height * 0.55, height * 1.9)
                camera.look(at: SCNVector3(0, height * 0.5, 0))
                scene.rootNode.addChildNode(camera)
                view.pointOfView = camera
            }
            view.setNeedsDisplay()
        }

        // Each frame: where the labelled points land on screen, and which face the camera.
        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            guard let camera = renderer.pointOfView?.presentation.worldPosition else { return }
            lock.lock()
            let points = landmarks
            lock.unlock()
            let items = points.compactMap { l, text -> LandmarkLabels.Item? in
                let p = l.position
                let toCamera = Vec3(camera.x - p.x, camera.y - p.y, camera.z - p.z)
                guard l.normal.x * toCamera.x + l.normal.y * toCamera.y + l.normal.z * toCamera.z > 0 else { return nil }
                let at = renderer.projectPoint(SCNVector3(p.x, p.y, p.z))
                let towards = renderer.projectPoint(SCNVector3(p.x + l.side * 0.1, p.y, p.z))
                guard at.z > 0, at.z < 1 else { return nil }
                return LandmarkLabels.Item(id: l.kind.rawValue, point: CGPoint(x: CGFloat(at.x), y: CGFloat(at.y)),
                                           rightward: towards.x >= at.x, text: text)
            }
            DispatchQueue.main.async { [weak self] in
                guard let model = self?.model, model.items != items else { return }
                model.items = items
            }
        }

        /// Fit-map colour: loose, resting on the body, tight, pulling (see `fitValues`).
        static func fitColor(_ v: Float) -> SIMD4<Float> {
            let loose = SIMD4<Float>(0.3, 0.55, 0.78, 1), resting = SIMD4<Float>(0.36, 0.76, 0.6, 1)
            let tight = SIMD4<Float>(0.98, 0.8, 0.32, 1), pulling = SIMD4<Float>(0.9, 0.3, 0.28, 1)
            if v < 0.35 { return loose + (resting - loose) * (v / 0.35) }
            if v < 0.7 { return resting + (tight - resting) * ((v - 0.35) / 0.35) }
            return tight + (pulling - tight) * min(1, (v - 0.7) / 0.4)
        }

        /// Faint dashed stitching from pairs of points.
        static func stitches(_ points: [Vec3]) -> SCNGeometry? {
            guard points.count >= 2 else { return nil }
            let source = SCNGeometrySource(vertices: points.map { SCNVector3($0.x, $0.y, $0.z) })
            let element = SCNGeometryElement(indices: (0..<UInt32(points.count)).map { $0 }, primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor(white: 1, alpha: 0.6)
            material.blendMode = .alpha
            geometry.materials = [material]
            return geometry
        }

        static func geometry(_ mesh: Mesh, color: UIColor, roughness: CGFloat, doubleSided: Bool = false,
                             colors: [SIMD4<Float>]? = nil) -> SCNGeometry {
            var sources = [
                SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) }),
                SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0.x, $0.y, $0.z) }),
            ]
            if let colors, colors.count == mesh.positions.count {
                let data = colors.withUnsafeBufferPointer { Data(buffer: $0) }
                sources.append(SCNGeometrySource(data: data, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                                                 componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0,
                                                 dataStride: MemoryLayout<SIMD4<Float>>.stride))
            }
            let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
            let geometry = SCNGeometry(sources: sources, elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = color
            material.roughness.contents = roughness
            material.metalness.contents = 0.0
            material.isDoubleSided = doubleSided
            geometry.materials = [material]
            return geometry
        }
    }
}

/// Where the labelled body points are on screen, updated as the avatar turns.
final class LandmarkLabels: ObservableObject {
    struct Item: Equatable, Identifiable {
        var id: String
        var point: CGPoint
        /// Whether the label goes to the right of its point.
        var rightward: Bool
        var text: String
    }

    @Published var items: [Item] = []
}

/// The labels themselves: a faint dotted ring on the point, a small jagged leader going
/// outward, and the text.
struct LandmarkOverlay: View {
    @ObservedObject var model: LandmarkLabels

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.items) { item in
                let sign: CGFloat = item.rightward ? 1 : -1
                let end = CGPoint(x: item.point.x + sign * 40, y: item.point.y)
                Circle()
                    .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 9, height: 9)
                    .position(item.point)
                Self.leader(from: CGPoint(x: item.point.x + sign * 5, y: item.point.y), to: end)
                    .stroke(.white.opacity(0.65), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                Text(item.text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: Capsule())
                    .fixedSize()
                    .alignmentGuide(.leading) { d in item.rightward ? 0 : d.width }
                    .alignmentGuide(.top) { d in d.height / 2 }
                    .offset(x: end.x + sign * 3, y: end.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// A zigzag with small teeth, then a short straight run.
    static func leader(from a: CGPoint, to b: CGPoint) -> Path {
        var p = Path()
        p.move(to: a)
        let length = b.x - a.x
        let teeth = 6
        for k in 1...teeth {
            let x = a.x + length * 0.75 * CGFloat(k) / CGFloat(teeth)
            p.addLine(to: CGPoint(x: x, y: a.y + (k % 2 == 0 ? 0 : (k % 4 == 1 ? -2.5 : 2.5))))
        }
        p.addLine(to: b)
        return p
    }
}

extension Avatar.Landmark.Kind {
    var title: String {
        switch self {
        case .neck: String(localized: "Neck")
        case .shoulder: String(localized: "Shoulder point")
        case .chest: String(localized: "Chest")
        case .elbow: String(localized: "Elbow")
        case .waist: String(localized: "Waist")
        case .wrist: String(localized: "Wrist")
        case .hip: String(localized: "Hip")
        case .crotch: String(localized: "Crotch")
        case .thigh: String(localized: "Thigh")
        case .knee: String(localized: "Kneecap")
        case .ankle: String(localized: "Ankle")
        }
    }
}

/// Turns a garment's size chart into how it sits on the avatar: ease (garment minus
/// body girth) and how much longer or shorter than the body each length is. Garment
/// charts give the ease directly; body charts describe the body a size suits, so the
/// garment is taken as that body plus the usual ease for the fit (see EaseTable).
enum AvatarFitMapper {
    static func fit(spec: GarmentSpec, size: SizeEntry, body: BodyProfile) -> Avatar.GarmentFit {
        let isTrousers = spec.category == .pants
        var fit = Avatar.GarmentFit(kind: isTrousers ? .trousers : .top(longSleeves: spec.category != .tshirt))
        func diff(_ g: GarmentDimension, _ b: BodyDimension) -> Double? {
            guard let gv = size.values[g]?.cm, let bv = body[b]?.cm else { return nil }
            return gv - bv
        }
        func ease(_ g: GarmentDimension, _ b: BodyDimension, typical: Double) -> Double {
            guard let d = diff(g, b) else { return typical }
            return spec.chartKind == .garment ? d : typical + d
        }
        let style = spec.fitStyle
        if isTrousers {
            fit.waistEase = ease(.waist, .waist, typical: 1.5)
            fit.hipEase = ease(.hip, .hip, typical: [FitStyle.slim: 4, .regular: 7, .relaxed: 12, .oversized: 20][style] ?? 7)
            fit.thighEase = ease(.thigh, .thigh, typical: [FitStyle.slim: 5, .regular: 9, .relaxed: 15, .oversized: 24][style] ?? 9)
            fit.lengthDelta = diff(.inseam, .inseam) ?? diff(.outseam, .outseam) ?? 0
        } else {
            let chestTypical: Double = [FitStyle.slim: 7, .regular: 12, .relaxed: 19, .oversized: 30][style] ?? 12
            fit.chestEase = ease(.chest, .chest, typical: chestTypical)
            fit.waistEase = ease(.waist, .waist, typical: chestTypical + 3)
            fit.hipEase = fit.waistEase
            let lengthEase: Double = spec.category == .tshirt ? 18 : spec.category == .jacket ? 25 : 21
            if let d = diff(.bodyLength, .torsoLength) { fit.lengthDelta = spec.chartKind == .garment ? d - lengthEase : d }
            if let d = diff(.sleeveLength, .armLength) { fit.sleeveDelta = spec.chartKind == .garment ? d - 2.5 : d }
            if let d = diff(.shoulderWidth, .shoulderWidth) {
                fit.shoulderDelta = spec.chartKind == .garment ? d : d + (style == .oversized ? 7 : 0)
            } else if style == .oversized {
                fit.shoulderDelta = 7
            }
        }
        return fit
    }

    /// How the fabric stretches and drapes, from its composition when the product page
    /// gave one, otherwise from the category and the chart's stretch setting.
    static func fabric(spec: GarmentSpec, material: String?) -> Fabric {
        let knit = spec.category == .tshirt
        let fibres = FabricAdvice.fibres(in: material ?? "")
        guard !fibres.isEmpty else {
            var fabric: Fabric = knit ? .knit : .woven
            fabric.stretchLimit += Float(spec.stretch.comfortableStretch)
            return fabric
        }
        return Fabric(fibres: Dictionary(uniqueKeysWithValues: fibres.map { ($0.key.rawValue, $0.value) }), knit: knit)
    }

    /// Where each fit region's dot goes.
    static func anchor(for region: FitRegion, trousers: Bool) -> Avatar.Anchor {
        switch region {
        case .shoulder: .shoulder
        case .chest: .chest
        case .waist: .waist
        case .hip: .hip
        case .thigh: .thigh
        case .sleeve: .sleeveEnd
        case .bodyLength, .inseam, .outseam: .hem
        }
    }
}

/// "See it on my avatar": the chosen size draped on the user's own 3D body, with the
/// verdict for each region next to it, or the fit map of how the fabric sits.
struct AvatarFitView: View {
    let analysis: FitAnalysis
    let spec: GarmentSpec
    @State var sizeLabel: String
    /// The fabric composition from the product page, when known.
    var material: String?
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @Environment(\.dismiss) private var dismiss
    @State private var showFitMap = false
    @State private var showLabels = true
    @State private var avatar: Avatar?
    @StateObject private var labelModel = LandmarkLabels()

    var body: some View {
        NavigationStack {
            Group {
                if let body = profiles.first?.profile, Avatar.Measurements(body) != nil {
                    let regions = analysis.sizes.first { $0.label == sizeLabel }?.regions.filter { $0.verdict != .insufficientData } ?? []
                    VStack(spacing: 0) {
                        ZStack {
                            if let avatar {
                                AvatarSceneView(avatar: avatar, fitMap: showFitMap, labels: showLabels ? labels(regions) : [:],
                                                labelModel: labelModel)
                                LandmarkOverlay(model: labelModel)
                            } else {
                                ProgressView("Draping the fabric…")
                            }
                        }
                        .frame(maxHeight: .infinity)
                        panel(regions)
                    }
                    .task(id: sizeLabel) { await drape(body) }
                } else {
                    ContentUnavailableView("Scan or enter your measurements first", systemImage: "figure.stand")
                }
            }
            .background(Theme.screenBackground)
            .navigationTitle("On your avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showLabels.toggle() } label: {
                        Image(systemName: showLabels ? "tag.fill" : "tag")
                    }
                    .accessibilityLabel(Text("Labels"))
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    /// Body points named, with the verdict of the region each one belongs to.
    private func labels(_ regions: [RegionFit]) -> [Avatar.Landmark.Kind: String] {
        let trousers = spec.category == .pants
        var regionOf: [Avatar.Landmark.Kind: FitRegion] = trousers
            ? [.waist: .waist, .hip: .hip, .thigh: .thigh]
            : [.shoulder: .shoulder, .chest: .chest, .waist: .waist, .wrist: .sleeve]
        if trousers {
            regionOf[.ankle] = regions.contains { $0.region == .inseam } ? .inseam : .outseam
        } else {
            regionOf[.hip] = .bodyLength
        }
        var out: [Avatar.Landmark.Kind: String] = [:]
        for kind in Avatar.Landmark.Kind.allCases {
            if let region = regionOf[kind], let r = regions.first(where: { $0.region == region }) {
                out[kind] = kind.title + " · " + r.detailText
            } else {
                out[kind] = kind.title
            }
        }
        return out
    }

    /// Runs the cloth simulation off the main thread.
    private func drape(_ body: BodyProfile) async {
        guard let m = Avatar.Measurements(body), let size = spec.sizes.first(where: { $0.label == sizeLabel }) else { return }
        var fit = AvatarFitMapper.fit(spec: spec, size: size, body: body)
        fit.fabric = AvatarFitMapper.fabric(spec: spec, material: material)
        let draped = await Task.detached(priority: .userInitiated) { Avatar(m, garment: fit) }.value
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) { avatar = draped }
    }

    private func panel(_ regions: [RegionFit]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if spec.sizes.count > 1 {
                Picker("Size", selection: $sizeLabel) {
                    ForEach(spec.sizes, id: \.label) { Text($0.label).tag($0.label) }
                }
                .pickerStyle(.segmented)
            }
            Picker("View", selection: $showFitMap) {
                Text("Garment").tag(false)
                Text("Fit map").tag(true)
            }
            .pickerStyle(.segmented)
            if showFitMap {
                HStack(spacing: Theme.Spacing.s) {
                    legend("Loose", Color(red: 0.3, green: 0.55, blue: 0.78))
                    legend("On the body", Color(red: 0.36, green: 0.76, blue: 0.6))
                    legend("Tight", Color(red: 0.98, green: 0.8, blue: 0.32))
                    legend("Pulling", Color(red: 0.9, green: 0.3, blue: 0.28))
                }
                .font(.footnote)
            } else {
                ForEach(regions, id: \.region) { r in
                    HStack {
                        Image(systemName: r.severity.symbol).foregroundStyle(r.severity.color)
                        Text(r.region.title)
                        Spacer()
                        Text(r.detailText).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            Text("Draped with cloth physics: the garment is cut to the size chart, settles on your body under its own weight and stretches where it must, as far as its fibres allow. Dashed lines are its seams and hems.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.m)
        .background(.bar)
        .sensoryFeedback(.selection, trigger: sizeLabel)
        .sensoryFeedback(.selection, trigger: showFitMap)
    }

    private func legend(_ title: LocalizedStringKey, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

/// "My avatar": the body from the measurements, fine-tuned with sliders and saved back.
struct AvatarEditorView: View {
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var values: [BodyDimension: Double] = [:]
    @State private var original: [BodyDimension: Double] = [:]
    @State private var avatar: Avatar?
    @StateObject private var labelModel = LandmarkLabels()

    private static let editable: [BodyDimension] = [.shoulderWidth, .chest, .waist, .hip, .thigh, .armLength, .inseam]

    var body: some View {
        VStack(spacing: 0) {
            if let base = profiles.first?.profile, let m = Avatar.Measurements(adjusted(base)) {
                ZStack {
                    if let avatar {
                        AvatarSceneView(avatar: avatar, labels: labels(m), labelModel: labelModel)
                        LandmarkOverlay(model: labelModel)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxHeight: .infinity)
                // A quick coarse body while a slider moves, the full one once it stops.
                .task(id: m) {
                    let quick = await Task.detached(priority: .userInitiated) { Avatar(m, detail: .preview) }.value
                    guard !Task.isCancelled else { return }
                    if avatar == nil { avatar = quick }
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    avatar = quick
                    let full = await Task.detached(priority: .userInitiated) { Avatar(m) }.value
                    guard !Task.isCancelled else { return }
                    avatar = full
                }
                ScrollView {
                    VStack(spacing: Theme.Spacing.s) {
                        ForEach(Self.editable, id: \.self) { d in
                            if let start = original[d] {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(d.title)
                                        Spacer()
                                        Text("\(values[d] ?? start, format: .number.precision(.fractionLength(1))) cm")
                                            .monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .font(.subheadline)
                                    Slider(value: binding(d, start: start), in: (start * 0.85)...(start * 1.15), step: 0.5)
                                }
                            }
                        }
                        Button("Save to my measurements") { save(base) }
                            .buttonStyle(.primary)
                            .disabled(values == original)
                    }
                    .padding(Theme.Spacing.m)
                }
                .frame(maxHeight: 330)
                .background(.bar)
            } else {
                ContentUnavailableView("Scan or enter your measurements first", systemImage: "figure.stand")
            }
        }
        .background(Theme.screenBackground)
        .navigationTitle("My avatar")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard original.isEmpty, let base = profiles.first?.profile else { return }
            for d in Self.editable { if let v = base[d]?.cm { original[d] = v } }
            values = original
        }
    }

    /// Body points named, with the measurement that belongs to each.
    private func labels(_ m: Avatar.Measurements) -> [Avatar.Landmark.Kind: String] {
        func cm(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1))) + " cm" }
        var out = Dictionary(uniqueKeysWithValues: Avatar.Landmark.Kind.allCases.map { ($0, $0.title) })
        out[.shoulder] = Avatar.Landmark.Kind.shoulder.title + " · " + cm(m.shoulderWidth)
        out[.chest] = Avatar.Landmark.Kind.chest.title + " · " + cm(m.chest)
        out[.waist] = Avatar.Landmark.Kind.waist.title + " · " + cm(m.waist)
        out[.hip] = Avatar.Landmark.Kind.hip.title + " · " + cm(m.hip)
        out[.thigh] = Avatar.Landmark.Kind.thigh.title + " · " + cm(m.thigh)
        out[.wrist] = Avatar.Landmark.Kind.wrist.title + " · " + String(localized: "arm \(cm(m.armLength))")
        out[.crotch] = Avatar.Landmark.Kind.crotch.title + " · " + String(localized: "inseam \(cm(m.inseam))")
        return out
    }

    private func binding(_ d: BodyDimension, start: Double) -> Binding<Double> {
        Binding(get: { values[d] ?? start }, set: { values[d] = $0 })
    }

    private func adjusted(_ base: BodyProfile) -> BodyProfile {
        var p = base
        for (d, v) in values where v != original[d] { p[d] = .manual(v) }
        return p
    }

    private func save(_ base: BodyProfile) {
        var p = adjusted(base)
        p.createdAt = Date()
        if let stored = try? StoredBodyProfile(profile: p) {
            modelContext.insert(stored)
            try? modelContext.save()
            AppSounds.shared.play(.saved)
            original = values
        }
    }
}
