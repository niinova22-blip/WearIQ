import SceneKit
import SwiftUI

/// How the scan goes, shown before it as a looping 3D scene: a little character leans
/// the phone against a pile of books on a side table at waist height, steps back, holds the front pose for the photo, hears
/// 3, 2, 1 and turns once round with the arms out, in the same ten seconds the real
/// turn takes. Eight dots on the floor light up as it comes round, the way the scan
/// collects its eight directions.
struct ScanTutorialView: View {
    @State private var start = Date()

    enum Step: Int, CaseIterable {
        case place, stepBack, front, countdown, turn, done

        /// When each step starts, seconds into the loop; the turn lasts the real ten.
        static let starts: [Double] = [0, 2.6, 4.6, 6.8, 9.8, 19.8]
        static let length = 22.0

        static func at(_ t: Double) -> (Step, Double) {
            let step = allCases.last { starts[$0.rawValue] <= t } ?? .place
            return (step, t - starts[step.rawValue])
        }

        var caption: LocalizedStringKey {
            switch self {
            case .place: "Lean the phone upright against something at waist height"
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
        .accessibilityLabel(Text("How the scan works: lean the phone upright against something at waist height, step back, hold the front pose, then turn once round slowly with your arms out."))
    }

    static func loopTime(_ date: Date, start: Date) -> Double {
        max(0, date.timeIntervalSince(start)).truncatingRemainder(dividingBy: Step.length)
    }
}

/// The SceneKit side of the tutorial: the character, the phone leaning on its books, the floor
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
    private let near: Float = 0.52, far: Float = 1.95
    /// Where the phone rests, leaning back against the books, and how far it leans.
    private let rest = SCNVector3(0, 0.615, 0.02)
    private let lean: Float = -0.16

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

    /// The phone's screen: the camera view with a person standing in its frame.
    private static func screenImage() -> UIImage {
        let size = CGSize(width: 200, height: 424)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(red: 0.35, green: 0.38, blue: 0.56, alpha: 1).cgColor,
                          UIColor(red: 0.18, green: 0.2, blue: 0.32, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            // Viewfinder corners.
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            cg.setLineWidth(7)
            cg.setLineCap(.round)
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 26, dy: 58)
            let arm: CGFloat = 34
            let corners: [(CGPoint, CGFloat, CGFloat)] = [(CGPoint(x: r.minX, y: r.minY), arm, arm), (CGPoint(x: r.maxX, y: r.minY), -arm, arm),
                                                          (CGPoint(x: r.minX, y: r.maxY), arm, -arm), (CGPoint(x: r.maxX, y: r.maxY), -arm, -arm)]
            for (corner, dx, dy) in corners {
                cg.move(to: CGPoint(x: corner.x + dx, y: corner.y))
                cg.addLine(to: corner)
                cg.addLine(to: CGPoint(x: corner.x, y: corner.y + dy))
            }
            cg.strokePath()
            // The person in frame.
            if let figure = UIImage(systemName: "figure.stand")?
                .withTintColor(UIColor(red: 0.55, green: 1, blue: 0.7, alpha: 1), renderingMode: .alwaysOriginal) {
                figure.draw(in: CGRect(x: 55, y: 120, width: 90, height: 190))
            }
            // The record dot.
            cg.setFillColor(UIColor(red: 1, green: 0.3, blue: 0.4, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 86, y: 362, width: 28, height: 28))
        }
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
        // A phone at a glance: a rounded slab, a lit camera screen with a person in its
        // viewfinder, the island at the top, the lenses on the back.
        let dark = material(UIColor(white: 0.1, alpha: 1), roughness: 0.25)
        let frame = material(UIColor(red: 0.78, green: 0.8, blue: 0.86, alpha: 1), roughness: 0.2)
        phone.addChildNode(node(SCNBox(width: 0.118, height: 0.232, length: 0.016, chamferRadius: 0.018), frame))
        phone.addChildNode(node(SCNBox(width: 0.11, height: 0.224, length: 0.017, chamferRadius: 0.016), dark))
        screen.lightingModel = .constant
        screen.diffuse.contents = Self.screenImage()
        let glass = SCNPlane(width: 0.1, height: 0.212)
        glass.cornerRadius = 0.014
        phone.addChildNode(node(glass, screen, at: SCNVector3(0, 0, 0.0088)))
        let pill = node(SCNCapsule(capRadius: 0.0055, height: 0.03), material(.black, roughness: 0.1),
                        at: SCNVector3(0, 0.094, 0.0092))
        pill.eulerAngles.z = .pi / 2
        pill.scale = SCNVector3(1, 1, 0.3)
        phone.addChildNode(pill)
        phone.addChildNode(node(SCNBox(width: 0.045, height: 0.045, length: 0.006, chamferRadius: 0.01), dark,
                                at: SCNVector3(-0.025, 0.08, -0.01)))
        for (x, y) in [(-0.035, 0.09), (-0.015, 0.07)] as [(Float, Float)] {
            let lens = node(SCNCylinder(radius: 0.008, height: 0.004), material(.black, roughness: 0.05),
                            at: SCNVector3(x, y, -0.014))
            lens.eulerAngles.x = .pi / 2
            phone.addChildNode(lens)
        }
        phone.enumerateHierarchy { n, _ in n.castsShadow = true }
        phone.position = rest
        phone.eulerAngles.x = lean
        scene.rootNode.addChildNode(phone)

        // The side table it leans on: a top, four legs, two books behind the phone.
        let wood = material(UIColor(red: 0.86, green: 0.66, blue: 0.5, alpha: 1), roughness: 0.6)
        let table = SCNNode()
        table.addChildNode(node(SCNBox(width: 0.36, height: 0.03, length: 0.3, chamferRadius: 0.012), wood,
                                at: SCNVector3(0, 0.485, -0.04)))
        for (x, z) in [(-0.15, -0.16), (0.15, -0.16), (-0.15, 0.08), (0.15, 0.08)] as [(Float, Float)] {
            table.addChildNode(node(SCNCylinder(radius: 0.016, height: 0.47), wood, at: SCNVector3(x, 0.235, z)))
        }
        let books: [(UIColor, Float, Float)] = [(UIColor(red: 0.42, green: 0.62, blue: 0.86, alpha: 1), 0.522, -0.05),
                                                (UIColor(red: 0.98, green: 0.78, blue: 0.36, alpha: 1), 0.567, 0.12)]
        for (color, y, turn) in books {
            let book = node(SCNBox(width: 0.2, height: 0.045, length: 0.14, chamferRadius: 0.006), material(color, roughness: 0.7),
                            at: SCNVector3(0, y, -0.1))
            book.eulerAngles.y = turn
            table.addChildNode(book)
        }
        table.enumerateHierarchy { n, _ in n.castsShadow = true }
        scene.rootNode.addChildNode(table)

        // Font units are points: set at 10 and scaled down, so the curves stay smooth.
        let text = SCNText(string: "3", extrusionDepth: 1.5)
        text.font = UIFont.systemFont(ofSize: 10, weight: .heavy)
        text.flatness = 0.1
        text.firstMaterial = material(Self.pink, roughness: 0.4, emission: Self.pink.withAlphaComponent(0.35))
        number.geometry = text
        number.position = SCNVector3(0, 0.92, 0)
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

    private func pose(_ t: Double) {
        let (step, local) = Step.at(t)
        let turnLength = Step.starts[Step.done.rawValue] - Step.starts[Step.turn.rawValue]

        // Where the character stands: at the table, then three steps back.
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
        // At the start the right hand holds the phone up, reaches out and leans it on the
        // books, then comes back down.
        let down = 0.1, slightly = 0.38, out = Double.pi / 2
        let arm: Double
        var swing = 0.0
        var reach = 0.0
        switch step {
        case .place:
            arm = down
            reach = local < 0.6 ? 0.75
                : local < 1.6 ? 0.75 + 0.6 * Self.smooth((local - 0.6) / 0.8)
                : 1.35 * (1 - Self.smooth((local - 1.6) / 0.7))
        case .stepBack: arm = down; swing = walk * 0.35
        case .front: arm = down + (slightly - down) * Self.smooth(local / 0.5)
        case .countdown: arm = slightly + (out - slightly) * Self.smooth((local - 1.6) / 0.8)
        case .turn: arm = out
        case .done: arm = out + (down - out) * Self.smooth(local / 0.5)
        }
        leftArm.eulerAngles = SCNVector3(Float(swing), 0, Float(-arm))
        rightArm.eulerAngles = SCNVector3(Float(-swing + reach), 0, Float(arm))

        // One turn round, clockwise from above (to the character's right), mostly steady.
        var turned = 0.0
        if step == .turn {
            let f = local / turnLength
            turned = 0.75 * f + 0.25 * Self.smooth(f)
        } else if step == .done {
            turned = 1
        }
        person.eulerAngles.y = Float(-turned * 2 * .pi)

        // The phone: in the hand, carried to the books, leaning on them with a little wobble.
        if step == .place, local < 1.45 {
            let hand = rightArm.convertPosition(SCNVector3(0, -0.4, 0), to: nil)
            let held = SCNVector3(hand.x - 0.02, hand.y + 0.06, hand.z - 0.03)
            let f = Float(Self.smooth((local - 0.7) / 0.75))
            phone.position = SCNVector3(held.x + (rest.x - held.x) * f, held.y + (rest.y - held.y) * f,
                                        held.z + (rest.z - held.z) * f)
            phone.eulerAngles.x = lean * f
        } else {
            let since = step == .place ? local - 1.45 : 9
            phone.position = rest
            phone.eulerAngles.x = lean + (since < 1 ? Float(0.05 * sin(since * 14) * (1 - since)) : 0)
        }

        for (k, dot) in dots.enumerated() {
            let lit = step == .done || (step == .turn && turned * 8 >= Double(k) + 0.001) || (step == .turn && k == 0)
            dot.diffuse.contents = lit ? UIColor(red: 0.2, green: 0.78, blue: 0.45, alpha: 1) : UIColor(white: 1, alpha: 1)
            dot.emission.contents = lit ? UIColor(red: 0.1, green: 0.45, blue: 0.25, alpha: 1) : UIColor.black
        }

        // The phone's screen: lit while it speaks, a flash for the photo.
        let flash = step == .front && local > 1.3 && local < 1.75
        let speaking = step == .countdown || step == .turn
        let pulse = CGFloat(abs(sin(t * 5)))
        screen.emission.contents = flash ? UIColor.white : UIColor.black
        screen.multiply.contents = speaking ? UIColor(red: 1, green: 0.75 + 0.25 * pulse, blue: 0.85 + 0.15 * pulse, alpha: 1) : UIColor.white

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
