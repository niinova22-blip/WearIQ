import AvatarEngine
import Combine
import Metal
import RealityKit
import SwiftUI
import UIKit

/// Picks the renderer: RealityKit from iOS 18 (Apple has put SceneKit in maintenance
/// mode), SceneKit before it. Both take the same inputs and draw the same avatar.
struct AvatarCanvas: View {
    let avatar: Avatar
    var revision: Int
    var fitColors = true
    var frame: Int?
    var labels: [SceneLabel] = []
    @ObservedObject var labelModel: LandmarkLabels
    var facing: Float?
    var facingTurn = 0
    var viewHeight: CGFloat = 0
    var coveredTop: CGFloat = 0
    var coveredBottom: CGFloat = 0
    var hidden: Set<Int> = []
    var layerColors: [Int: UIColor] = [:]
    var snapshotter: AvatarSnapshotter?

    var body: some View {
        if #available(iOS 18.0, *), !AvatarRealityView.unavailable {
            AvatarRealityView(avatar: avatar, revision: revision, fitColors: fitColors, frame: frame, labels: labels,
                              labelModel: labelModel, facing: facing, facingTurn: facingTurn, viewHeight: viewHeight,
                              coveredTop: coveredTop, coveredBottom: coveredBottom, hidden: hidden,
                              layerColors: layerColors, snapshotter: snapshotter)
        } else {
            AvatarSceneView(avatar: avatar, revision: revision, fitColors: fitColors, frame: frame, labels: labels,
                            labelModel: labelModel, facing: facing, facingTurn: facingTurn, viewHeight: viewHeight,
                            coveredTop: coveredTop, coveredBottom: coveredBottom, hidden: hidden,
                            layerColors: layerColors, snapshotter: snapshotter)
        }
    }
}

/// The avatar in RealityKit: the same scene as `AvatarSceneView` (a matte grey body under
/// a soft key light with a contact shadow, every garment coloured by how it sits, seams
/// as faint lines and the fit lines bright, drag to turn with a little spin when let go,
/// pinch to zoom, the garments swinging behind the body as it turns), drawn by
/// RealityKit's physically based renderer. Per-vertex fit colours and the swing go
/// through a custom material (AvatarShaders.metal); where that can't be made, a plain
/// material in the garment's colour.
@available(iOS 18.0, *)
struct AvatarRealityView: UIViewRepresentable {
    /// Set when RealityKit failed to start on this device: the SceneKit view is used.
    nonisolated(unsafe) static var unavailable = false

    let avatar: Avatar
    var revision: Int
    var fitColors = true
    var frame: Int?
    var labels: [SceneLabel] = []
    @ObservedObject var labelModel: LandmarkLabels
    var facing: Float?
    var facingTurn = 0
    var viewHeight: CGFloat = 0
    var coveredTop: CGFloat = 0
    var coveredBottom: CGFloat = 0
    var hidden: Set<Int> = []
    var layerColors: [Int: UIColor] = [:]
    var snapshotter: AvatarSnapshotter?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.clear)
        view.backgroundColor = .clear
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableCameraGrain,
                              .disablePersonOcclusion, .disableAREnvironmentLighting]
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        context.coordinator.attach(to: view)
        update(view, context.coordinator)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        update(view, context.coordinator)
    }

    private func update(_ view: ARView, _ coordinator: Coordinator) {
        snapshotter?.arView = view
        coordinator.update(avatar, revision: revision, fitColors: fitColors, frame: frame, labels: labels,
                           hidden: hidden, layerColors: layerColors, model: labelModel)
        coordinator.turn(to: facing, turn: facingTurn)
        coordinator.frameBody(height: avatar.body.maxY, viewHeight: viewHeight, top: coveredTop, bottom: coveredBottom)
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var view: ARView?
        private let anchor = AnchorEntity(world: .zero)
        /// Everything that turns with the avatar.
        private let figure = Entity()
        private let bodyEntity = ModelEntity()
        private let layersEntity = Entity()
        private let camera = PerspectiveCamera()
        private var shownKey: String?
        private var framing: [Float] = []
        private var placedCamera = false
        private weak var model: LandmarkLabels?
        private var labels: [SceneLabel] = []
        /// Entities whose custom material carries the swing.
        private var swaying: [ModelEntity] = []
        private var updates: Cancellable?
        private static let library: MTLLibrary? = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary()

        // Turning.
        private var yaw: Float = 0.25
        private var yawVelocity: Float = 0
        private var pendingYaw: Float = 0
        private var dragging = false
        private var targetYaw: Float?
        private var shownTurn = 0
        private var lastOmega: Float = 0
        private var swing: Float = 0
        private var swingVelocity: Float = 0
        private var shownSwing: Float = .nan

        func attach(to view: ARView) {
            self.view = view
            view.scene.addAnchor(anchor)
            anchor.addChild(figure)
            figure.addChild(bodyEntity)
            figure.addChild(layersEntity)
            figure.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            anchor.addChild(camera)
            camera.camera.fieldOfViewInDegrees = 34

            // A soft key light from the front left with a shadow, a rim light from behind
            // so the outline reads, and a weak fill from the other side.
            let key = DirectionalLight()
            key.light.intensity = 2600
            key.shadow = DirectionalLightComponent.Shadow(maximumDistance: 4, depthBias: 2)
            key.look(at: .zero, from: [-0.9, 2.6, 2.2], relativeTo: nil)
            anchor.addChild(key)
            let rim = DirectionalLight()
            rim.light.intensity = 1300
            rim.look(at: .zero, from: [0.8, 1.6, -2.4], relativeTo: nil)
            anchor.addChild(rim)
            let fill = DirectionalLight()
            fill.light.intensity = 900
            fill.light.color = UIColor(red: 0.93, green: 0.95, blue: 1, alpha: 1)
            fill.look(at: .zero, from: [1.8, 0.8, 1.6], relativeTo: nil)
            anchor.addChild(fill)
            // A floor that only shows the shadow.
            let floor = ModelEntity(mesh: .generatePlane(width: 6, depth: 6),
                                    materials: [OcclusionMaterial(receivesDynamicLighting: true)])
            anchor.addChild(floor)

            updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                MainActor.assumeIsolated { self?.tick(Float(event.deltaTime)) }
            }
        }

        // MARK: Gestures

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let dx = Float(gesture.translation(in: gesture.view).x)
            gesture.setTranslation(.zero, in: gesture.view)
            pendingYaw += dx * 0.011
            switch gesture.state {
            case .began, .changed:
                dragging = true
                targetYaw = nil
            default:
                dragging = false
                yawVelocity = max(-9, min(9, Float(gesture.velocity(in: gesture.view).x) * 0.011))
            }
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            camera.camera.fieldOfViewInDegrees = min(60, max(14, camera.camera.fieldOfViewInDegrees / Float(gesture.scale)))
            gesture.scale = 1
        }

        func turn(to facing: Float?, turn: Int) {
            guard turn != shownTurn else { return }
            shownTurn = turn
            targetYaw = facing
        }

        // MARK: Content

        func update(_ avatar: Avatar, revision: Int, fitColors: Bool, frame: Int?, labels: [SceneLabel],
                    hidden: Set<Int>, layerColors: [Int: UIColor], model: LandmarkLabels) {
            self.model = model
            self.labels = labels
            let colorKey = layerColors.keys.sorted().map { k -> String in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                layerColors[k]!.getRed(&r, green: &g, blue: &b, alpha: &a)
                return String(format: "%d:%.2f,%.2f,%.2f", k, r, g, b)
            }.joined(separator: ";")
            let key = "\(revision)-\(fitColors)-\(frame ?? -1)-\(hidden.sorted())-\(colorKey)"
            guard key != shownKey else { return }
            let bodyChanged = shownKey?.split(separator: "-").first != key.split(separator: "-").first
            shownKey = key
            if bodyChanged || bodyEntity.model == nil {
                var skin = PhysicallyBasedMaterial()
                skin.baseColor = .init(tint: UIColor(red: 0.74, green: 0.75, blue: 0.77, alpha: 1))
                skin.roughness = .init(floatLiteral: 0.92)
                skin.metallic = .init(floatLiteral: 0)
                if let mesh = Self.resource(avatar.body.positions, normals: avatar.body.normals, indices: avatar.body.indices,
                                            colors: nil, uniform: SIMD4(0.74, 0.75, 0.77, 1), sway: []) {
                    bodyEntity.model = ModelComponent(mesh: mesh, materials: [skin])
                }
            }
            layersEntity.children.removeAll()
            swaying = []
            let navy = SIMD4<Float>(0.24, 0.3, 0.44, 1)
            for (index, layer) in avatar.layers.enumerated() where !hidden.contains(index) {
                let mesh = frame.map { avatar.layerMesh(layer, frame: $0) } ?? layer.mesh
                let plain = layerColors[index].map(Self.rgba) ?? navy
                let colors = fitColors ? AvatarSceneView.Coordinator.colors(mesh) : nil
                if let resource = Self.resource(mesh.positions, normals: mesh.normals, indices: mesh.indices,
                                                colors: colors, uniform: plain, sway: mesh.sway) {
                    add(resource, surface: "avatarFabric", fallback: Self.fabricFallback(plain))
                }
                // Seams and fit lines belong to the settled garment.
                guard frame == nil else { continue }
                if let seams = Self.tubes(layer.seams, radius: 0.0006, color: SIMD4(1, 1, 1, 0.45),
                                          sway: AvatarSceneView.Coordinator.sway(of: layer.seams, on: mesh)) {
                    add(seams, surface: "avatarGlow", fallback: UnlitMaterial(color: UIColor(white: 1, alpha: 0.45)))
                }
                guard fitColors else { continue }
                for line in layer.fitLines {
                    let tone = Self.rgba(UIColor(line.tone.color))
                    if let tube = Self.tubes(line.line, radius: 0.0021, color: tone,
                                             sway: AvatarSceneView.Coordinator.sway(of: line.line, on: mesh)) {
                        add(tube, surface: "avatarGlow", fallback: UnlitMaterial(color: UIColor(line.tone.color)))
                    }
                    if let target = Self.tubes(line.target, radius: 0.0015, color: SIMD4(1, 1, 1, 1),
                                               sway: AvatarSceneView.Coordinator.sway(of: line.target, on: mesh)) {
                        add(target, surface: "avatarGlow", fallback: UnlitMaterial(color: .white))
                    }
                }
            }
            shownSwing = .nan
            if !placedCamera {
                placedCamera = true
                let h = avatar.body.maxY
                camera.look(at: [0, h * 0.5, 0], from: [0, h * 0.55, h * 1.9], relativeTo: nil)
            }
        }

        private func add(_ mesh: MeshResource, surface: String, fallback: any RealityKit.Material) {
            let entity = ModelEntity()
            if let material = Self.custom(surface) {
                entity.model = ModelComponent(mesh: mesh, materials: [material])
                swaying.append(entity)
            } else {
                entity.model = ModelComponent(mesh: mesh, materials: [fallback])
            }
            layersEntity.addChild(entity)
        }

        private static func custom(_ surface: String) -> CustomMaterial? {
            guard let library else { return nil }
            let shader = CustomMaterial.SurfaceShader(named: surface, in: library)
            let modifier = CustomMaterial.GeometryModifier(named: "avatarSway", in: library)
            var material = try? CustomMaterial(surfaceShader: shader, geometryModifier: modifier, lightingModel: surface == "avatarGlow" ? .unlit : .lit)
            if surface == "avatarGlow" { material?.blending = .transparent(opacity: 1) }
            return material
        }

        private static func fabricFallback(_ c: SIMD4<Float>) -> any RealityKit.Material {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1))
            m.roughness = .init(floatLiteral: 0.86)
            return m
        }

        static func rgba(_ color: UIColor) -> SIMD4<Float> {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return SIMD4(Float(r), Float(g), Float(b), Float(a))
        }

        /// Places the camera so the whole figure fills the part of the view nothing covers
        /// (as `AvatarSceneView` does).
        func frameBody(height h: Float, viewHeight: CGFloat, top: CGFloat, bottom: CGFloat) {
            guard h > 0, viewHeight > 1 else { return }
            let key = [h, Float(viewHeight), Float(top), Float(bottom)]
            guard key != framing else { return }
            framing = key
            let H = Float(viewHeight)
            let band = max(0.4 * H, H - Float(top) - Float(bottom))
            let shown = h * 1.1 / (band / H)
            let middle = (Float(top) + band / 2) / H
            let centre = h * 0.5 + (middle - 0.5) * shown
            let halfAngle: Float = 34 * .pi / 180 / 2
            let distance = shown / 2 / tan(halfAngle)
            camera.look(at: [0, centre, 0], from: [0, centre + 0.05 * h, distance], relativeTo: nil)
        }

        // MARK: Motion

        private func tick(_ dt0: Float) {
            let dt = min(1.0 / 20, max(1.0 / 240, dt0))
            let delta = pendingYaw
            pendingYaw = 0
            let before = yaw
            if dragging {
                yaw += delta
                yawVelocity = 0
            } else if let target = targetYaw {
                let goal = target + 2 * .pi * ((yaw - target) / (2 * .pi)).rounded()
                let k: Float = 26
                yawVelocity += (k * (goal - yaw) - 2 * k.squareRoot() * yawVelocity) * dt
                yaw += yawVelocity * dt
                if abs(goal - yaw) < 0.002, abs(yawVelocity) < 0.01 {
                    yaw = goal
                    yawVelocity = 0
                    targetYaw = nil
                }
            } else {
                yaw += delta + yawVelocity * dt
                yawVelocity *= exp(-2.2 * dt)
                if abs(yawVelocity) < 0.02 { yawVelocity = 0 }
            }
            let omega = (yaw - before) / dt
            let alpha = max(-80, min(80, (omega - lastOmega) / dt))
            lastOmega = omega
            // The garment's lag: a damped spring driven by the body's angular acceleration.
            let k: Float = 57, c: Float = 2 * 0.22 * k.squareRoot()
            let h = dt / 4
            for _ in 0..<4 {
                swingVelocity += (-k * swing - c * swingVelocity - alpha) * h
                swing += swingVelocity * h
            }
            swing = max(-0.4, min(0.4, swing))
            figure.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            if !(abs(swing - shownSwing) < 0.0005) {
                shownSwing = swing
                for entity in swaying {
                    guard var material = entity.model?.materials.first as? CustomMaterial else { continue }
                    material.custom.value = SIMD4(swing, 0, 0, 0)
                    entity.model?.materials = [material]
                }
            }
            placeLabels()
        }

        /// Where the labelled points land on screen, and which face the camera.
        private func placeLabels() {
            guard let view, let model else { return }
            let world = figure.transformMatrix(relativeTo: nil)
            let eye = camera.position(relativeTo: nil)
            let items = labels.compactMap { l -> LandmarkLabels.Item? in
                let p4 = world * SIMD4(l.position.x, l.position.y, l.position.z, 1)
                let n4 = world * SIMD4(l.normal.x, l.normal.y, l.normal.z, 0)
                let p = SIMD3(p4.x, p4.y, p4.z)
                guard simd_dot(SIMD3(n4.x, n4.y, n4.z), eye - p) > 0, let at = view.project(p) else { return nil }
                let side4 = world * SIMD4(l.side * 0.1, 0, 0, 0)
                let towards = view.project(p + SIMD3(side4.x, side4.y, side4.z)) ?? at
                return LandmarkLabels.Item(id: l.id, point: at, rightward: towards.x >= at.x, text: l.text, tone: l.tone)
            }
            if model.items != items { model.items = items }
        }

        // MARK: Geometry

        /// A mesh with per-vertex colour and sway weight (uv0.x), through LowLevelMesh.
        static func resource(_ positions: [Vec3], normals: [Vec3], indices: [UInt32], colors: [SIMD4<Float>]?,
                             uniform: SIMD4<Float>, sway: [Float]) -> MeshResource? {
            let n = positions.count
            guard n > 0, !indices.isEmpty else { return nil }
            var descriptor = LowLevelMesh.Descriptor()
            descriptor.vertexAttributes = [
                .init(semantic: .position, format: .float3, offset: 0),
                .init(semantic: .normal, format: .float3, offset: 12),
                .init(semantic: .color, format: .float4, offset: 24),
                .init(semantic: .uv0, format: .float2, offset: 40),
            ]
            descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: 48)]
            descriptor.vertexCapacity = n
            descriptor.indexCapacity = indices.count
            descriptor.indexType = .uint32
            guard let mesh = try? LowLevelMesh(descriptor: descriptor) else { return nil }
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
                let f = raw.bindMemory(to: Float.self)
                for i in 0..<n {
                    let p = positions[i], q = i < normals.count ? normals[i] : Vec3(0, 1, 0)
                    let c = colors.map { i < $0.count ? $0[i] : uniform } ?? uniform
                    let b = i * 12
                    f[b] = p.x; f[b + 1] = p.y; f[b + 2] = p.z
                    f[b + 3] = q.x; f[b + 4] = q.y; f[b + 5] = q.z
                    f[b + 6] = c.x; f[b + 7] = c.y; f[b + 8] = c.z; f[b + 9] = c.w
                    f[b + 10] = i < sway.count ? sway[i] : 0; f[b + 11] = 0
                    lo = simd_min(lo, SIMD3(p.x, p.y, p.z)); hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
                }
            }
            mesh.withUnsafeMutableIndices { raw in
                let out = raw.bindMemory(to: UInt32.self)
                for (k, index) in indices.enumerated() { out[k] = index }
            }
            mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: indices.count, topology: .triangle,
                                                     bounds: BoundingBox(min: lo, max: hi))])
            return try? MeshResource(from: mesh)
        }

        /// Thin square tubes along segment pairs (seams, fit lines).
        static func tubes(_ points: [Vec3], radius: Float, color: SIMD4<Float>, sway: [Float]) -> MeshResource? {
            guard points.count >= 2 else { return nil }
            var positions: [Vec3] = [], normals: [Vec3] = [], weights: [Float] = [], indices: [UInt32] = []
            for k in stride(from: 0, to: points.count - 1, by: 2) {
                let a = points[k], b = points[k + 1]
                let d = (b - a).normalized
                let helper = abs(d.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
                let u = d.cross(helper).normalized, v = d.cross(u).normalized
                let corners = [u, v, u * -1, v * -1]
                let base = UInt32(positions.count)
                let wa = sway.count == points.count ? sway[k] : 0, wb = sway.count == points.count ? sway[k + 1] : 0
                for (end, w) in [(a, wa), (b, wb)] {
                    for c in corners {
                        positions.append(end + c * radius)
                        normals.append(c)
                        weights.append(w)
                    }
                }
                for s in 0..<UInt32(4) {
                    let n = (s + 1) % 4
                    indices += [base + s, base + 4 + s, base + 4 + n, base + s, base + 4 + n, base + n]
                }
            }
            return resource(positions, normals: normals, indices: indices, colors: nil, uniform: color, sway: weights)
        }
    }
}
