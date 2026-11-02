import SceneKit
import SwiftUI

/// How the scan goes, shown before it as a looping 3D scene: a little character props
/// the phone up at waist height, steps back, holds the front pose for the photo, hears
/// 3, 2, 1 and turns once round with the arms out, in the same ten seconds the real
/// turn takes. Eight dots on the floor light up as it comes round, the way the scan
/// collects its eight directions.
struct ScanTutorialView: View {
    @State private var start = Date()

    enum Step: Int, CaseIterable {
        case place, stepBack, front, countdown, turn, done

        /// When each step starts, seconds into the loop; the turn lasts the real ten.
        static let starts: [Double] = [0, 1.6, 3.6, 5.8, 8.8, 18.8]
        static let length = 21.0

        static func at(_ t: Double) -> (Step, Double) {
            let step = allCases.last { starts[$0.rawValue] <= t } ?? .place
            return (step, t - starts[step.rawValue])
        }

        var caption: LocalizedStringKey {
            switch self {
            case .place: "Prop the phone upright at waist height"
            case .stepBack: "Step back about three steps"
            case .front: "Arms slightly out: the front photo"
            case .countdown: "Listen: 3, 2, 1, then arms straight out"
            case .turn: "Turn once round slowly, counting to ten"
            case .done: "Done: your measurements are ready"
            }
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = Self.loopTime(context.date, start: start)
            let (step, local) = Step.at(t)
            VStack(spacing: 10) {
                TutorialSceneView(start: start)
                    .frame(height: 230)
                    .overlay {
                        // The front photo's flash.
                        if step == .front, local > 1.3, local < 1.75 {
                            Color.white.opacity(0.8 * (1 - (local - 1.3) / 0.45)).allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .top) {
                        if step == .done {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.white, .green)
                                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                                .padding(.top, 14)
                                .scaleEffect(min(1, 0.4 + local * 2.5))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if step == .turn {
                            Text(verbatim: "\(min(10, Int(local) + 1))/10")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Theme.accentGradient, in: Capsule())
                                .padding(10)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text(step.caption)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: step.rawValue)
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { s in
                        Capsule()
                            .fill(s.rawValue <= step.rawValue ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.25)))
                            .frame(width: s == step ? 18 : 6, height: 6)
                            .animation(.spring(duration: 0.35), value: step.rawValue)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("How the scan works: prop the phone at waist height, step back, hold the front pose, then turn once round slowly with your arms out."))
    }

    static func loopTime(_ date: Date, start: Date) -> Double {
        max(0, date.timeIntervalSince(start)).truncatingRemainder(dividingBy: Step.length)
    }
}

/// The SceneKit side of the tutorial: the character, the phone on its tripod, the floor
/// dots and the numbers above the phone, all posed every frame from the loop's clock.
private struct TutorialSceneView: UIViewRepresentable {
    let start: Date

    func makeCoordinator() -> TutorialScene { TutorialScene(start: start) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.delegate = context.coordinator
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 60
        view.allowsCameraControl = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.start = start
    }

    static func dismantleUIView(_ view: SCNView, coordinator: TutorialScene) {
        view.isPlaying = false
        view.delegate = nil
    }
}

/// Builds the scene once and poses it on SceneKit's render loop.
private final class TutorialScene: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    typealias Step = ScanTutorialView.Step

    var start: Date
    let scene = SCNScene()
    let camera = SCNNode()

    private let person = SCNNode()
    private let body = SCNNode()
    private let leftArm = SCNNode(), rightArm = SCNNode()
    private let leftLeg = SCNNode(), rightLeg = SCNNode()
    private let phone = SCNNode()
    private let screen = SCNMaterial()
    private let number = SCNNode()
    private var shownNumber = ""
    private var dots: [SCNMaterial] = []

    /// Where the character stands for the photo and the turn (the phone is at the origin
    /// facing +z, the character faces it, towards −z).
    private let near: Float = 0.75, far: Float = 1.95

    private static let coral = UIColor(red: 1.0, green: 0.52, blue: 0.42, alpha: 1)
    private static let pink = UIColor(red: 0.93, green: 0.32, blue: 0.52, alpha: 1)

    init(start: Date) {
        self.start = start
        super.init()
        build()
    }

    // MARK: Building

    private func material(_ color: UIColor, roughness: CGFloat = 0.55, emission: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        // Blinn with a soft highlight: a clay-toy look that doesn't need an environment map.
        m.lightingModel = .blinn
        m.diffuse.contents = color
        m.specular.contents = UIColor(white: 1, alpha: 1 - roughness * 0.9)
        m.shininess = 0.15 + (1 - roughness) * 0.4
        if let emission { m.emission.contents = emission }
        return m
    }

    private func node(_ geometry: SCNGeometry, _ material: SCNMaterial, at p: SCNVector3 = SCNVector3Zero) -> SCNNode {
        geometry.firstMaterial = material
        let n = SCNNode(geometry: geometry)
        n.position = p
        return n
    }

    private func build() {
        scene.background.contents = Self.backdrop()

        let floor = SCNFloor()
        floor.reflectivity = 0.06
        floor.reflectionFalloffEnd = 0.6
        let floorMaterial = material(UIColor(red: 0.98, green: 0.9, blue: 0.86, alpha: 1), roughness: 0.9)
        floor.firstMaterial = floorMaterial
        scene.rootNode.addChildNode(SCNNode(geometry: floor))

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 900
        key.light!.castsShadow = true
        key.light!.shadowMode = .deferred
        key.light!.shadowSampleCount = 16
        key.light!.shadowRadius = 8
        key.light!.shadowColor = UIColor(white: 0, alpha: 0.22)
        key.eulerAngles = SCNVector3(-1.0, 0.7, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light!.type = .ambient
        fill.light!.intensity = 350
        fill.light!.color = UIColor(red: 1, green: 0.93, blue: 0.95, alpha: 1)
        scene.rootNode.addChildNode(fill)

        buildPhone()
        buildPerson()
        buildDots()

        camera.camera = SCNCamera()
        camera.camera!.fieldOfView = 36
        camera.camera!.wantsHDR = false
        let target = SCNNode()
        target.position = SCNVector3(0, 0.55, 1.2)
        scene.rootNode.addChildNode(target)
        let look = SCNLookAtConstraint(target: target)
        look.isGimbalLockEnabled = true
        camera.constraints = [look]
        scene.rootNode.addChildNode(camera)
    }

    /// A soft peach-to-lilac wall.
    private static func backdrop() -> UIImage {
        let size = CGSize(width: 4, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 1.0, green: 0.86, blue: 0.82, alpha: 1).cgColor,
                          UIColor(red: 0.93, green: 0.84, blue: 0.96, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }

    private func buildPhone() {
        let dark = material(UIColor(white: 0.12, alpha: 1), roughness: 0.3)
        let case_ = SCNBox(width: 0.085, height: 0.165, length: 0.014, chamferRadius: 0.012)
        phone.addChildNode(node(case_, dark))
        screen.lightingModel = .constant
        screen.diffuse.contents = UIColor(red: 0.3, green: 0.32, blue: 0.45, alpha: 1)
        let glass = SCNPlane(width: 0.072, height: 0.15)
        glass.cornerRadius = 0.01
        phone.addChildNode(node(glass, screen, at: SCNVector3(0, 0, 0.0075)))
        let lens = node(SCNSphere(radius: 0.006), material(.black, roughness: 0.1), at: SCNVector3(0, 0.066, 0.008))
        phone.addChildNode(lens)
        phone.position = SCNVector3(0, 0.62, 0)
        scene.rootNode.addChildNode(phone)

        // Tripod: a stem and three legs to the floor.
        let metal = material(UIColor(white: 0.55, alpha: 1), roughness: 0.35)
        let tripod = SCNNode()
        tripod.addChildNode(node(SCNCylinder(radius: 0.008, height: 0.2), metal, at: SCNVector3(0, 0.44, 0)))
        for k in 0..<3 {
            let a = Float(k) * 2 * .pi / 3
            let leg = node(SCNCylinder(radius: 0.007, height: 0.38), metal)
            leg.position = SCNVector3(0.06 * sin(a), 0.17, 0.06 * cos(a))
            leg.eulerAngles = SCNVector3(0.32 * cos(a), 0, -0.32 * sin(a))
            tripod.addChildNode(leg)
        }
        scene.rootNode.addChildNode(tripod)

        // Font units are points: set at 10 and scaled down, so the curves stay smooth.
        let text = SCNText(string: "3", extrusionDepth: 1.5)
        text.font = UIFont.systemFont(ofSize: 10, weight: .heavy)
        text.flatness = 0.1
        text.firstMaterial = material(Self.pink, roughness: 0.4, emission: Self.pink.withAlphaComponent(0.35))
        number.geometry = text
        number.position = SCNVector3(0, 1.0, 0)
        number.scale = SCNVector3(0.022, 0.022, 0.022)
        number.constraints = [SCNBillboardConstraint()]
        number.opacity = 0
        scene.rootNode.addChildNode(number)
    }

    private func buildPerson() {
        let shirt = material(Self.coral)
        let trousers = material(UIColor(red: 0.36, green: 0.4, blue: 0.62, alpha: 1))
        let skin = material(UIColor(red: 1.0, green: 0.83, blue: 0.71, alpha: 1), roughness: 0.6)
        let hairColor = material(UIColor(red: 0.33, green: 0.22, blue: 0.18, alpha: 1), roughness: 0.7)
        let shoe = material(UIColor(white: 0.97, alpha: 1), roughness: 0.5)
        let eye = material(UIColor(white: 0.1, alpha: 1), roughness: 0.15)
        let blushColor = material(UIColor(red: 1, green: 0.5, blue: 0.6, alpha: 0.55), roughness: 0.8)
        blushColor.transparencyMode = .aOne

        // Torso and head.
        body.addChildNode(node(SCNCapsule(capRadius: 0.17, height: 0.5), shirt, at: SCNVector3(0, 0.62, 0)))
        body.addChildNode(node(SCNSphere(radius: 0.21), skin, at: SCNVector3(0, 1.08, 0)))
        let hair = node(SCNSphere(radius: 0.205), hairColor, at: SCNVector3(0, 1.13, 0.035))
        hair.scale = SCNVector3(1.04, 0.9, 1.02)
        body.addChildNode(hair)
        for side in [Float(-1), 1] {
            let e = node(SCNSphere(radius: 0.027), eye, at: SCNVector3(side * 0.072, 1.1, -0.192))
            e.scale = SCNVector3(1, 1.15, 0.55)
            body.addChildNode(e)
            let sparkle = node(SCNSphere(radius: 0.008), material(.white, roughness: 0.1, emission: .white),
                               at: SCNVector3(side * 0.072 + 0.008, 1.112, -0.206))
            body.addChildNode(sparkle)
            let blush = node(SCNSphere(radius: 0.03), blushColor, at: SCNVector3(side * 0.12, 1.035, -0.17))
            blush.scale = SCNVector3(1.2, 0.7, 0.4)
            body.addChildNode(blush)
        }
        // A small round "o" of a mouth.
        let smile = node(SCNTorus(ringRadius: 0.018, pipeRadius: 0.006), eye, at: SCNVector3(0, 1.025, -0.198))
        smile.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        body.addChildNode(smile)

        // Arms hang from the shoulders, legs from the hips; each turns about its top.
        for (arm, side) in [(leftArm, Float(-1)), (rightArm, 1)] {
            arm.position = SCNVector3(side * 0.185, 0.8, 0)
            arm.addChildNode(node(SCNCapsule(capRadius: 0.05, height: 0.36), shirt, at: SCNVector3(0, -0.17, 0)))
            arm.addChildNode(node(SCNSphere(radius: 0.055), skin, at: SCNVector3(0, -0.36, 0)))
            body.addChildNode(arm)
        }
        for (leg, side) in [(leftLeg, Float(-1)), (rightLeg, 1)] {
            leg.position = SCNVector3(side * 0.085, 0.43, 0)
            leg.addChildNode(node(SCNCapsule(capRadius: 0.068, height: 0.38), trousers, at: SCNVector3(0, -0.17, 0)))
            let foot = node(SCNSphere(radius: 0.07), shoe, at: SCNVector3(0, -0.385, -0.03))
            foot.scale = SCNVector3(0.95, 0.6, 1.35)
            leg.addChildNode(foot)
            body.addChildNode(leg)
        }
        body.enumerateHierarchy { n, _ in n.castsShadow = true }
        person.addChildNode(body)
        person.position = SCNVector3(0, 0, near)
        scene.rootNode.addChildNode(person)
    }

    /// Eight dots round where the turn happens, lit in the order it passes them.
    private func buildDots() {
        for k in 0..<8 {
            let theta = Float(k) * .pi / 4
            let m = material(UIColor(white: 1, alpha: 1), roughness: 0.4)
            let dot = node(SCNCylinder(radius: 0.035, height: 0.008), m,
                           at: SCNVector3(0.46 * sin(theta), 0.004, far - 0.46 * cos(theta)))
            dot.castsShadow = false
            scene.rootNode.addChildNode(dot)
            dots.append(m)
        }
        let ring = node(SCNTorus(ringRadius: 0.46, pipeRadius: 0.004), material(UIColor(white: 1, alpha: 0.7), roughness: 0.6),
                        at: SCNVector3(0, 0.003, far))
        ring.castsShadow = false
        scene.rootNode.addChildNode(ring)
    }

    // MARK: Posing

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let now = Date()
        let t = ScanTutorialView.loopTime(now, start: start)
        let clock = Float(now.timeIntervalSince(start))
        pose(t)
        // A slow drift of the camera, so the scene reads as 3D.
        camera.position = SCNVector3(2.4 + 0.18 * sin(clock * 0.35), 1.35 + 0.05 * sin(clock * 0.5), 0.2 + 0.3 * sin(clock * 0.22))
    }

    private static func smooth(_ x: Double) -> Double {
        let f = min(1, max(0, x))
        return f * f * (3 - 2 * f)
    }

    /// Overshoots a little before settling: the phone dropping into its stand.
    private static func backOut(_ x: Double) -> Double {
        let f = min(1, max(0, x)) - 1
        return 1 + f * f * (2.7 * f + 1.7)
    }

    private func pose(_ t: Double) {
        let (step, local) = Step.at(t)
        let turnLength = Step.starts[Step.done.rawValue] - Step.starts[Step.turn.rawValue]

        // The phone drops onto the tripod at the start of the loop.
        let drop = step == .place ? Self.backOut(local / 0.9) : 1
        phone.position = SCNVector3(0, Float(0.62 + (1 - drop) * 1.1), 0)
        phone.opacity = CGFloat(min(1, drop * 3))

        // Where the character stands: by the phone, then three steps back.
        var z = Double(near), walk = 0.0
        switch step {
        case .place: z = Double(near)
        case .stepBack:
            let f = Self.smooth(local / 1.8)
            z = Double(near) + f * Double(far - near)
            walk = local < 1.8 ? sin(local / 1.8 * 3 * .pi) : 0
        default: z = Double(far)
        }
        var hop = 0.0
        if step == .done, local < 0.9 { hop = 0.1 * abs(sin(local / 0.45 * .pi)) }
        let breathe = 1 + 0.012 * sin(t * 2.4)
        person.position = SCNVector3(0, Float(abs(walk) * 0.025 + hop), Float(z))
        body.scale = SCNVector3(1, Float(breathe), 1)
        leftLeg.eulerAngles.x = Float(walk * 0.45)
        rightLeg.eulerAngles.x = Float(-walk * 0.45)

        // Arms: at the sides, slightly out for the photo, straight out from the countdown.
        let down = 0.1, slightly = 0.38, out = Double.pi / 2
        let arm: Double
        var swing = 0.0
        switch step {
        case .place: arm = down
        case .stepBack: arm = down; swing = walk * 0.35
        case .front: arm = down + (slightly - down) * Self.smooth(local / 0.5)
        case .countdown: arm = slightly + (out - slightly) * Self.smooth((local - 1.6) / 0.8)
        case .turn: arm = out
        case .done: arm = out + (down - out) * Self.smooth(local / 0.5)
        }
        leftArm.eulerAngles = SCNVector3(Float(swing), 0, Float(-arm))
        rightArm.eulerAngles = SCNVector3(Float(-swing), 0, Float(arm))

        // One turn round, clockwise from above (to the character's right), mostly steady.
        var turned = 0.0
        if step == .turn {
            let f = local / turnLength
            turned = 0.75 * f + 0.25 * Self.smooth(f)
        } else if step == .done {
            turned = 1
        }
        person.eulerAngles.y = Float(-turned * 2 * .pi)

        for (k, dot) in dots.enumerated() {
            let lit = step == .done || (step == .turn && turned * 8 >= Double(k) + 0.001) || (step == .turn && k == 0)
            dot.diffuse.contents = lit ? UIColor(red: 0.2, green: 0.78, blue: 0.45, alpha: 1) : UIColor(white: 1, alpha: 1)
            dot.emission.contents = lit ? UIColor(red: 0.1, green: 0.45, blue: 0.25, alpha: 1) : UIColor.black
        }

        // The phone's screen: lit while it speaks, a flash for the photo.
        let flash = step == .front && local > 1.3 && local < 1.75
        let speaking = step == .countdown || step == .turn
        screen.diffuse.contents = flash ? UIColor.white
            : speaking ? Self.pink.withAlphaComponent(0.6 + 0.4 * CGFloat(abs(sin(t * 5))))
            : UIColor(red: 0.3, green: 0.32, blue: 0.45, alpha: 1)

        // The numbers the phone says: 3, 2, 1 before the turn, then 1 to 10 through it.
        var label = ""
        var since = 0.0
        if step == .countdown, local < 3 {
            label = "\(3 - Int(local))"
            since = local.truncatingRemainder(dividingBy: 1)
        } else if step == .turn {
            label = "\(min(10, Int(local) + 1))"
            since = local.truncatingRemainder(dividingBy: 1)
        }
        if label != shownNumber, let text = number.geometry as? SCNText {
            shownNumber = label
            text.string = label
            let (lo, hi) = number.boundingBox
            number.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 0)
        }
        let pop = label.isEmpty ? 0 : 1 + 0.35 * max(0, 1 - since * 5)
        let size = Float(step == .turn ? 0.013 : 0.022) * Float(pop)
        number.scale = SCNVector3(size, size, size)
        number.opacity = label.isEmpty ? 0 : CGFloat(min(1, (1 - since) * 3))
    }
}

#Preview {
    ScanTutorialView().padding()
}
