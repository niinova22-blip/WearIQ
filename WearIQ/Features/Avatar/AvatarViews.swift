import AvatarEngine
import FitEngine
import ProductMeasurementParser
import SceneKit
import SwiftData
import SwiftUI
import WearIQCore

/// Renders an `Avatar` with SceneKit: drag to turn it, pinch to zoom. A matte grey body
/// under a soft key light with ambient occlusion and a contact shadow on the floor. Body
/// and garment geometry are swapped in place, so the camera stays where the user put it
/// while measurements or sizes change. With `fitMap` the garment is coloured by how hard
/// the fabric stretches: teal relaxed, yellow close, red pulling.
struct AvatarSceneView: UIViewRepresentable {
    let avatar: Avatar
    /// Small coloured dots on the garment where a region fits well (green) or not.
    var markers: [(Avatar.Anchor, UIColor)] = []
    var fitMap = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.scene = context.coordinator.scene
        context.coordinator.update(avatar, markers: markers, fitMap: fitMap, in: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(avatar, markers: markers, fitMap: fitMap, in: view)
    }

    @MainActor
    final class Coordinator {
        let scene = SCNScene()
        private let bodyNode = SCNNode()
        private let garmentNode = SCNNode()
        private let markerNode = SCNNode()
        private var placedCamera = false

        init() {
            scene.rootNode.addChildNode(bodyNode)
            scene.rootNode.addChildNode(garmentNode)
            scene.rootNode.addChildNode(markerNode)
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

        func update(_ avatar: Avatar, markers: [(Avatar.Anchor, UIColor)], fitMap: Bool, in view: SCNView) {
            bodyNode.geometry = Self.geometry(avatar.body, color: UIColor(red: 0.8, green: 0.81, blue: 0.83, alpha: 1), roughness: 0.92)
            bodyNode.castsShadow = true
            garmentNode.geometry = avatar.garment.map {
                fitMap
                    ? Self.geometry($0, color: .white, roughness: 0.9, doubleSided: true, colors: $0.strain.map(Self.strainColor))
                    : Self.geometry($0, color: UIColor(red: 0.24, green: 0.3, blue: 0.44, alpha: 1), roughness: 0.88, doubleSided: true)
            }
            markerNode.childNodes.forEach { $0.removeFromParentNode() }
            for (anchor, color) in markers where !fitMap {
                guard let p = avatar.anchors[anchor] else { continue }
                let dot = SCNNode(geometry: SCNSphere(radius: 0.016))
                dot.geometry?.firstMaterial?.diffuse.contents = color
                dot.geometry?.firstMaterial?.lightingModel = .constant
                dot.castsShadow = false
                dot.position = SCNVector3(p.x + 0.02, p.y, p.z + 0.08)
                markerNode.addChildNode(dot)
            }
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
        }

        /// Fit-map colour for a strain (1 = the fabric's stretch limit).
        static func strainColor(_ strain: Float) -> SIMD4<Float> {
            let relaxed = SIMD4<Float>(0.36, 0.72, 0.68, 1), close = SIMD4<Float>(0.98, 0.8, 0.32, 1)
            let pulling = SIMD4<Float>(0.9, 0.3, 0.28, 1)
            if strain < 0.6 { return relaxed + (close - relaxed) * max(0, (strain - 0.2) / 0.4) }
            return close + (pulling - close) * min(1, (strain - 0.6) / 0.5)
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
/// verdict for each region next to it, or the fit map of where the fabric stretches.
struct AvatarFitView: View {
    let analysis: FitAnalysis
    let spec: GarmentSpec
    @State var sizeLabel: String
    /// The fabric composition from the product page, when known.
    var material: String?
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @Environment(\.dismiss) private var dismiss
    @State private var showFitMap = false
    @State private var avatar: Avatar?

    var body: some View {
        NavigationStack {
            Group {
                if let body = profiles.first?.profile, Avatar.Measurements(body) != nil {
                    let regions = analysis.sizes.first { $0.label == sizeLabel }?.regions.filter { $0.verdict != .insufficientData } ?? []
                    VStack(spacing: 0) {
                        ZStack {
                            if let avatar {
                                AvatarSceneView(avatar: avatar, markers: regions.map {
                                    (AvatarFitMapper.anchor(for: $0.region, trousers: spec.category == .pants), UIColor($0.severity.color))
                                }, fitMap: showFitMap)
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
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
                HStack(spacing: Theme.Spacing.m) {
                    legend("Relaxed", Color(red: 0.36, green: 0.72, blue: 0.68))
                    legend("Close", Color(red: 0.98, green: 0.8, blue: 0.32))
                    legend("Pulling", Color(red: 0.9, green: 0.3, blue: 0.28))
                }
                .font(.subheadline)
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
            Text("Draped with cloth physics: the garment is cut to the size chart and settles on your body under its own weight. The fit map shows where the fabric has to stretch, judged by what its fibres allow.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.m)
        .background(.bar)
        .sensoryFeedback(.selection, trigger: sizeLabel)
        .sensoryFeedback(.selection, trigger: showFitMap)
    }

    private func legend(_ title: LocalizedStringKey, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title)
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

    private static let editable: [BodyDimension] = [.shoulderWidth, .chest, .waist, .hip, .thigh, .armLength, .inseam]

    var body: some View {
        VStack(spacing: 0) {
            if let base = profiles.first?.profile, let m = Avatar.Measurements(adjusted(base)) {
                AvatarSceneView(avatar: Avatar(m))
                    .frame(maxHeight: .infinity)
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
