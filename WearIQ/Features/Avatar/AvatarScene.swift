import AvatarEngine
import SceneKit
import SwiftUI

/// A text pinned to a point on the avatar, drawn by `LandmarkOverlay` where the point
/// lands on screen while it faces the camera.
struct SceneLabel: Equatable {
    var id: String
    var position: Vec3
    /// Outward surface direction, to tell whether the point faces the camera.
    var normal: Vec3
    /// +1 when the label goes towards the avatar's left (+x), −1 its right.
    var side: Float
    var text: String
    /// Colour of the dot and the label's edge; nil for a plain white label.
    var tone: FitTone?
}

/// Renders an `Avatar` with SceneKit: drag sideways to turn it (it keeps spinning a
/// little when let go), pinch to zoom. A matte grey body under a soft key light with
/// ambient occlusion and a contact shadow, every garment worn coloured by how it sits
/// (`FitTone`), its seams as faint dashes and its fit lines (shoulder seams, cuffs,
/// hems, waistband) as glowing lines in the same colours, with white dashes where they
/// belong on the body.
///
/// Loose fabric swings: the garments lag behind the body as it turns and swing back
/// when it stops, a damped spring per garment (a pendulum of about 1.2 Hz) applied on
/// the GPU to each vertex as far as `Mesh.sway` lets it move.
struct AvatarSceneView: UIViewRepresentable {
    let avatar: Avatar
    /// Changes whenever `avatar` is replaced, so geometry is rebuilt only then.
    var revision: Int
    /// Colour garments by fit; otherwise a plain navy.
    var fitColors = true
    /// While the dressing plays: which of each layer's frames to show.
    var frame: Int?
    var labels: [SceneLabel] = []
    @ObservedObject var labelModel: LandmarkLabels

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.rendersContinuously = true
        view.scene = context.coordinator.scene
        view.delegate = context.coordinator
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        context.coordinator.update(avatar, revision: revision, fitColors: fitColors, frame: frame, labels: labels,
                                   model: labelModel, in: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(avatar, revision: revision, fitColors: fitColors, frame: frame, labels: labels,
                                   model: labelModel, in: view)
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
        let scene = SCNScene()
        /// Everything that turns with the avatar.
        private let figure = SCNNode()
        private let bodyNode = SCNNode()
        private let layersNode = SCNNode()
        private var camera: SCNNode?
        private var shownKey: String?
        private var placedCamera = false
        private weak var model: LandmarkLabels?
        /// Garment and line materials carrying the sway uniform.
        private var swayMaterials: [SCNMaterial] = []

        // Shared with the render thread.
        private let lock = NSLock()
        private var labels: [SceneLabel] = []
        private var pendingYaw: Float = 0
        private var flingVelocity: Float?
        private var dragging = false

        // Render thread only.
        private var yaw: Float = 0.25
        private var yawVelocity: Float = 0
        private var lastOmega: Float = 0
        private var swing: Float = 0
        private var swingVelocity: Float = 0
        private var lastTime: TimeInterval?

        override init() {
            super.init()
            scene.rootNode.addChildNode(figure)
            figure.addChildNode(bodyNode)
            figure.addChildNode(layersNode)
            figure.eulerAngles.y = yaw
            // Soft key light from the front left, casting a blurred shadow.
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 820
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
            rim.light?.intensity = 480
            rim.eulerAngles = SCNVector3(-0.35, .pi * 0.85, 0)
            scene.rootNode.addChildNode(rim)
            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .ambient
            fill.light?.intensity = 400
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

        // MARK: Gestures

        @MainActor @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let dx = Float(gesture.translation(in: gesture.view).x)
            gesture.setTranslation(.zero, in: gesture.view)
            lock.lock()
            pendingYaw += dx * 0.011
            switch gesture.state {
            case .began, .changed: dragging = true
            default:
                dragging = false
                flingVelocity = max(-9, min(9, Float(gesture.velocity(in: gesture.view).x) * 0.011))
            }
            lock.unlock()
        }

        @MainActor @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            guard let camera = camera?.camera else { return }
            camera.fieldOfView = min(60, max(14, camera.fieldOfView / gesture.scale))
            gesture.scale = 1
        }

        // MARK: Content

        @MainActor
        func update(_ avatar: Avatar, revision: Int, fitColors: Bool, frame: Int?, labels: [SceneLabel],
                    model: LandmarkLabels, in view: SCNView) {
            self.model = model
            let key = "\(revision)-\(fitColors)-\(frame ?? -1)"
            if key != shownKey {
                let bodyChanged = shownKey?.split(separator: "-").first != key.split(separator: "-").first
                shownKey = key
                if bodyChanged || bodyNode.geometry == nil {
                    bodyNode.geometry = Self.geometry(avatar.body, color: UIColor(red: 0.8, green: 0.81, blue: 0.83, alpha: 1),
                                                      roughness: 0.92)
                }
                layersNode.childNodes.forEach { $0.removeFromParentNode() }
                var materials: [SCNMaterial] = []
                for layer in avatar.layers {
                    let mesh = frame.map { avatar.layerMesh(layer, frame: $0) } ?? layer.mesh
                    let garment = Self.geometry(mesh, color: fitColors ? .white : UIColor(red: 0.24, green: 0.3, blue: 0.44, alpha: 1),
                                                roughness: 0.86, doubleSided: true,
                                                colors: fitColors ? Self.colors(mesh) : nil, sway: mesh.sway)
                    layersNode.addChildNode(SCNNode(geometry: garment))
                    materials += garment.materials
                    // Seams and fit lines belong to the settled garment.
                    guard frame == nil else { continue }
                    if let seams = Self.stitches(layer.seams, sway: Self.sway(of: layer.seams, on: mesh)) {
                        layersNode.addChildNode(SCNNode(geometry: seams))
                        materials += seams.materials
                    }
                    guard fitColors else { continue }
                    for line in layer.fitLines {
                        let color = UIColor(line.tone.color)
                        if let tube = Self.tubes(line.line, radius: 0.0021, color: color, glow: true,
                                                 sway: Self.sway(of: line.line, on: mesh)) {
                            layersNode.addChildNode(SCNNode(geometry: tube))
                            materials += tube.materials
                        }
                        if let target = Self.tubes(line.target, radius: 0.0015, color: .white, glow: true,
                                                   sway: Self.sway(of: line.target, on: mesh)) {
                            layersNode.addChildNode(SCNNode(geometry: target))
                            materials += target.materials
                        }
                    }
                }
                lock.lock()
                swayMaterials = materials
                lock.unlock()
            }
            lock.lock()
            self.labels = labels
            lock.unlock()
            if !placedCamera {
                placedCamera = true
                let height = avatar.body.maxY
                let camera = SCNNode()
                camera.camera = SCNCamera()
                camera.camera?.fieldOfView = 34
                camera.camera?.wantsHDR = true
                camera.camera?.bloomIntensity = 0.9
                camera.camera?.bloomThreshold = 0.85
                camera.camera?.bloomBlurRadius = 6
                camera.camera?.screenSpaceAmbientOcclusionIntensity = 0.9
                camera.camera?.screenSpaceAmbientOcclusionRadius = 0.08
                camera.position = SCNVector3(0, height * 0.55, height * 1.9)
                camera.look(at: SCNVector3(0, height * 0.5, 0))
                scene.rootNode.addChildNode(camera)
                view.pointOfView = camera
                self.camera = camera
            }
        }

        // MARK: Motion

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let dt = Float(min(1.0 / 20, max(1.0 / 240, time - (lastTime ?? time - 1.0 / 60))))
            lastTime = time
            lock.lock()
            let delta = pendingYaw
            pendingYaw = 0
            let drag = dragging
            if let fling = flingVelocity {
                yawVelocity = fling
                flingVelocity = nil
            }
            let materials = swayMaterials
            lock.unlock()
            let before = yaw
            if drag {
                yaw += delta
                yawVelocity = 0
            } else {
                yaw += delta + yawVelocity * dt
                yawVelocity *= exp(-2.2 * dt)
                if abs(yawVelocity) < 0.02 { yawVelocity = 0 }
            }
            let omega = (yaw - before) / dt
            let alpha = max(-80, min(80, (omega - lastOmega) / dt))
            lastOmega = omega
            // The garment's lag behind the body: a damped spring driven by the body's
            // angular acceleration (k ≈ (2π·1.2 Hz)², damping ratio 0.22).
            let k: Float = 57, c: Float = 2 * 0.22 * k.squareRoot()
            let steps = 4
            let h = dt / Float(steps)
            for _ in 0..<steps {
                swingVelocity += (-k * swing - c * swingVelocity - alpha) * h
                swing += swingVelocity * h
            }
            swing = max(-0.4, min(0.4, swing))
            figure.eulerAngles.y = yaw
            for material in materials { material.setValue(NSNumber(value: swing), forKey: "swayAngle") }
        }

        // Each frame: where the labelled points land on screen, and which face the camera.
        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            guard let camera = renderer.pointOfView?.presentation.worldPosition else { return }
            lock.lock()
            let points = labels
            lock.unlock()
            let node = figure.presentation
            let items = points.compactMap { l -> LandmarkLabels.Item? in
                let p = node.convertPosition(SCNVector3(l.position.x, l.position.y, l.position.z), to: nil)
                let n = node.convertVector(SCNVector3(l.normal.x, l.normal.y, l.normal.z), to: nil)
                guard n.x * (camera.x - p.x) + n.y * (camera.y - p.y) + n.z * (camera.z - p.z) > 0 else { return nil }
                let side = node.convertVector(SCNVector3(l.side * 0.1, 0, 0), to: nil)
                let at = renderer.projectPoint(p)
                let towards = renderer.projectPoint(SCNVector3(p.x + side.x, p.y + side.y, p.z + side.z))
                guard at.z > 0, at.z < 1 else { return nil }
                return LandmarkLabels.Item(id: l.id, point: CGPoint(x: CGFloat(at.x), y: CGFloat(at.y)),
                                           rightward: towards.x >= at.x, text: l.text, tone: l.tone)
            }
            DispatchQueue.main.async { [weak self] in
                guard let model = self?.model, model.items != items else { return }
                model.items = items
            }
        }

        // MARK: Geometry

        /// Per vertex: the fit colour over the good-fit blue, as strongly as the engine says.
        static func colors(_ mesh: Mesh) -> [SIMD4<Float>]? {
            guard mesh.tones.count == mesh.positions.count else { return nil }
            let base = FitTone.fits.rgba
            return mesh.tones.indices.map { i in
                let w = mesh.toneWeight[i]
                return base + (mesh.tones[i].rgba - base) * w
            }
        }

        /// Sway weights for points on a garment: the weight of the nearest vertex.
        static func sway(of points: [Vec3], on mesh: Mesh) -> [Float] {
            guard mesh.sway.count == mesh.positions.count, !points.isEmpty else { return [] }
            let cell: Float = 0.03
            func key(_ p: Vec3) -> SIMD3<Int32> {
                SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down)))
            }
            var grid: [SIMD3<Int32>: [Int]] = [:]
            for i in mesh.positions.indices { grid[key(mesh.positions[i]), default: []].append(i) }
            return points.map { p in
                let k = key(p)
                var best: Float = .greatestFiniteMagnitude, weight: Float = 0
                for dx: Int32 in -1...1 { for dy: Int32 in -1...1 { for dz: Int32 in -1...1 {
                    for i in grid[k &+ SIMD3(dx, dy, dz)] ?? [] {
                        let d = (mesh.positions[i] - p).length
                        if d < best { best = d; weight = mesh.sway[i] }
                    }
                } } }
                return weight
            }
        }

        /// Turns each vertex round the body's vertical axis by the garment's lag, as far
        /// as its sway weight (first texture coordinate) lets it.
        static let swayModifier = """
        #pragma arguments
        float swayAngle;
        #pragma body
        float w = _geometry.texcoords[0].x;
        float a = swayAngle * w;
        float c = cos(a);
        float s = sin(a);
        float3 p = _geometry.position.xyz;
        _geometry.position.xyz = float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
        float3 n = _geometry.normal;
        _geometry.normal = float3(c * n.x + s * n.z, n.y, -s * n.x + c * n.z);
        """

        static func swayMaterial(_ material: SCNMaterial) {
            material.shaderModifiers = [.geometry: swayModifier]
            material.setValue(NSNumber(value: 0), forKey: "swayAngle")
        }

        static func swaySource(_ weights: [Float], count: Int) -> SCNGeometrySource? {
            guard weights.count == count else { return nil }
            return SCNGeometrySource(textureCoordinates: weights.map { CGPoint(x: CGFloat($0), y: 0) })
        }

        /// Faint dashed stitching from pairs of points.
        static func stitches(_ points: [Vec3], sway: [Float]) -> SCNGeometry? {
            guard points.count >= 2 else { return nil }
            var sources = [SCNGeometrySource(vertices: points.map { SCNVector3($0.x, $0.y, $0.z) })]
            if let s = swaySource(sway, count: points.count) { sources.append(s) }
            let element = SCNGeometryElement(indices: (0..<UInt32(points.count)).map { $0 }, primitiveType: .line)
            let geometry = SCNGeometry(sources: sources, elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor(white: 1, alpha: 0.45)
            material.blendMode = .alpha
            swayMaterial(material)
            geometry.materials = [material]
            return geometry
        }

        /// Thin square tubes along segment pairs, unlit and bright enough to bloom.
        static func tubes(_ points: [Vec3], radius: Float, color: UIColor, glow: Bool, sway: [Float]) -> SCNGeometry? {
            guard points.count >= 2 else { return nil }
            var vertices: [SCNVector3] = [], weights: [Float] = [], indices: [UInt32] = []
            for k in stride(from: 0, to: points.count - 1, by: 2) {
                let a = points[k], b = points[k + 1]
                let d = (b - a).normalized
                let helper = abs(d.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
                let u = d.cross(helper).normalized * radius, v = d.cross(u).normalized * radius
                let corners = [u, v, u * -1, v * -1]
                let base = UInt32(vertices.count)
                for end in [a, b] {
                    for c in corners {
                        let p = end + c
                        vertices.append(SCNVector3(p.x, p.y, p.z))
                    }
                }
                let wa = sway.count == points.count ? sway[k] : 0, wb = sway.count == points.count ? sway[k + 1] : 0
                weights += [wa, wa, wa, wa, wb, wb, wb, wb]
                for s in 0..<UInt32(4) {
                    let n = (s + 1) % 4
                    indices += [base + s, base + 4 + s, base + 4 + n, base + s, base + 4 + n, base + n]
                }
            }
            var sources = [SCNGeometrySource(vertices: vertices)]
            if let s = swaySource(weights, count: vertices.count) { sources.append(s) }
            let geometry = SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            material.emission.contents = glow ? color : UIColor.black
            material.isDoubleSided = true
            swayMaterial(material)
            geometry.materials = [material]
            return geometry
        }

        static func geometry(_ mesh: Mesh, color: UIColor, roughness: CGFloat, doubleSided: Bool = false,
                             colors: [SIMD4<Float>]? = nil, sway: [Float] = []) -> SCNGeometry {
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
            let swaying = swaySource(sway, count: mesh.positions.count)
            if let swaying { sources.append(swaying) }
            let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
            let geometry = SCNGeometry(sources: sources, elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = color
            material.roughness.contents = roughness
            material.metalness.contents = 0.0
            material.isDoubleSided = doubleSided
            if swaying != nil { swayMaterial(material) }
            geometry.materials = [material]
            return geometry
        }
    }
}

/// Where the labels are on screen, updated as the avatar turns.
final class LandmarkLabels: ObservableObject {
    struct Item: Equatable, Identifiable {
        var id: String
        var point: CGPoint
        /// Whether the label goes to the right of its point.
        var rightward: Bool
        var text: String
        var tone: FitTone?
    }

    @Published var items: [Item] = []
}

/// The labels themselves: a ring on the point, a small jagged leader going outward,
/// and the text; fit labels carry their tone's colour.
struct LandmarkOverlay: View {
    @ObservedObject var model: LandmarkLabels

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.items) { item in
                let sign: CGFloat = item.rightward ? 1 : -1
                let end = CGPoint(x: item.point.x + sign * 40, y: item.point.y)
                let color = item.tone?.color ?? .white
                Circle()
                    .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: item.tone == nil ? 1 : 2, dash: item.tone == nil ? [2, 2] : []))
                    .frame(width: 9, height: 9)
                    .position(item.point)
                Self.leader(from: CGPoint(x: item.point.x + sign * 5, y: item.point.y), to: end)
                    .stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                Text(item.text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .overlay(Capsule().stroke(color.opacity(item.tone == nil ? 0 : 0.9), lineWidth: 1))
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

extension FitTone {
    var title: String {
        switch self {
        case .fits: String(localized: "Fits")
        case .loose: String(localized: "Loose")
        case .long: String(localized: "Long")
        case .tight: String(localized: "Tight")
        case .short: String(localized: "Short")
        }
    }

    /// Blue fits, yellow loose, red long, purple tight, orange short.
    var rgba: SIMD4<Float> {
        switch self {
        case .fits: SIMD4(0.2, 0.47, 0.95, 1)
        case .loose: SIMD4(1.0, 0.84, 0.18, 1)
        case .long: SIMD4(0.95, 0.2, 0.22, 1)
        case .tight: SIMD4(0.62, 0.32, 0.95, 1)
        case .short: SIMD4(1.0, 0.55, 0.12, 1)
        }
    }

    var color: Color { Color(red: Double(rgba.x), green: Double(rgba.y), blue: Double(rgba.z)) }
}

extension Avatar.FitLine {
    /// What the line says, for its label; nil where there's nothing to say.
    func text(trousers: Bool) -> String? {
        func cm(_ v: Double) -> String { String(Int(max(1, abs(v).rounded()))) }
        switch kind {
        case .shoulderSeam:
            switch tone {
            case .loose: return String(localized: "Shoulder seams sit about \(cm(deltaCm)) cm low")
            case .tight: return String(localized: "Shoulder seams sit about \(cm(deltaCm)) cm inside your shoulders")
            default: return String(localized: "Seams sit on your shoulders")
            }
        case .sleeveEnd:
            switch tone {
            case .long: return String(localized: "Sleeves reach about \(cm(deltaCm)) cm past your wrists")
            case .short: return String(localized: "Sleeves end about \(cm(deltaCm)) cm above your wrists")
            default: return nil
            }
        case .waistband:
            return tone == .fits ? nil : FitZone.waist.title + ": " + tone.title
        case .hem:
            break
        }
        switch (tone, trousers) {
        case (.long, true): return String(localized: "Legs about \(cm(deltaCm)) cm long; they'll gather at the ankle")
        case (.short, true): return String(localized: "Legs end about \(cm(deltaCm)) cm above the ankle")
        case (.long, false): return String(localized: "About \(cm(deltaCm)) cm longer than usual")
        case (.short, false): return String(localized: "About \(cm(deltaCm)) cm shorter than usual")
        default: return nil
        }
    }
}
