import AvatarEngine
import FitEngine
import SceneKit
import SwiftData
import SwiftUI
import WearIQCore

/// Renders an `Avatar` with SceneKit: drag to turn it, pinch to zoom. Body and garment
/// geometry are swapped in place, so the camera stays where the user put it while
/// measurements or sizes change.
struct AvatarSceneView: UIViewRepresentable {
    let avatar: Avatar
    /// Small coloured dots on the garment where a region fits well (green) or not.
    var markers: [(Avatar.Anchor, UIColor)] = []

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.scene = context.coordinator.scene
        context.coordinator.update(avatar, markers: markers, in: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(avatar, markers: markers, in: view)
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
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 900
            key.eulerAngles = SCNVector3(-0.6, 0.5, 0)
            scene.rootNode.addChildNode(key)
            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .ambient
            fill.light?.intensity = 450
            scene.rootNode.addChildNode(fill)
        }

        func update(_ avatar: Avatar, markers: [(Avatar.Anchor, UIColor)], in view: SCNView) {
            bodyNode.geometry = Self.geometry(avatar.body, color: UIColor(red: 0.86, green: 0.74, blue: 0.66, alpha: 1), roughness: 0.7)
            garmentNode.geometry = avatar.garment.map {
                Self.geometry($0, color: UIColor(red: 0.22, green: 0.28, blue: 0.42, alpha: 1), roughness: 0.85, doubleSided: true)
            }
            markerNode.childNodes.forEach { $0.removeFromParentNode() }
            for (anchor, color) in markers {
                guard let p = avatar.anchors[anchor] else { continue }
                let dot = SCNNode(geometry: SCNSphere(radius: 0.018))
                dot.geometry?.firstMaterial?.diffuse.contents = color
                dot.geometry?.firstMaterial?.lightingModel = .constant
                dot.position = SCNVector3(p.x + 0.02, p.y, p.z + 0.08)
                markerNode.addChildNode(dot)
            }
            if !placedCamera {
                placedCamera = true
                let height = avatar.body.maxY
                let camera = SCNNode()
                camera.camera = SCNCamera()
                camera.camera?.fieldOfView = 34
                camera.position = SCNVector3(0, height * 0.55, height * 1.9)
                camera.look(at: SCNVector3(0, height * 0.5, 0))
                scene.rootNode.addChildNode(camera)
                view.pointOfView = camera
            }
        }

        static func geometry(_ mesh: Mesh, color: UIColor, roughness: CGFloat, doubleSided: Bool = false) -> SCNGeometry {
            let vertices = SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) })
            let normals = SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0.x, $0.y, $0.z) })
            let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
            let geometry = SCNGeometry(sources: [vertices, normals], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = color
            material.roughness.contents = roughness
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

/// "See it on my avatar": the chosen size on the user's own 3D body, with the verdict
/// for each region next to it.
struct AvatarFitView: View {
    let analysis: FitAnalysis
    let spec: GarmentSpec
    @State var sizeLabel: String
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let body = profiles.first?.profile, let m = Avatar.Measurements(body),
                   let size = spec.sizes.first(where: { $0.label == sizeLabel }) {
                    let fit = AvatarFitMapper.fit(spec: spec, size: size, body: body)
                    let regions = analysis.sizes.first { $0.label == sizeLabel }?.regions.filter { $0.verdict != .insufficientData } ?? []
                    VStack(spacing: 0) {
                        AvatarSceneView(avatar: Avatar(m, garment: fit), markers: regions.map {
                            (AvatarFitMapper.anchor(for: $0.region, trousers: spec.category == .pants), UIColor($0.severity.color))
                        })
                        .frame(maxHeight: .infinity)
                        panel(regions)
                    }
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

    private func panel(_ regions: [RegionFit]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if spec.sizes.count > 1 {
                Picker("Size", selection: $sizeLabel) {
                    ForEach(spec.sizes, id: \.label) { Text($0.label).tag($0.label) }
                }
                .pickerStyle(.segmented)
            }
            ForEach(regions, id: \.region) { r in
                HStack {
                    Image(systemName: r.severity.symbol).foregroundStyle(r.severity.color)
                    Text(r.region.title)
                    Spacer()
                    Text(r.detailText).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            Text("Drawn from the size chart and your measurements: hems and cuffs end where the numbers put them. It shows fit and proportions, not the fabric's exact drape.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.m)
        .background(.bar)
        .sensoryFeedback(.selection, trigger: sizeLabel)
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
