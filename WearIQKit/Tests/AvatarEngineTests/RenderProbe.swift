import Foundation
import Testing
@testable import AvatarEngine
import WearIQCore

/// Renders avatars to raw RGB files for eyeballing (converted to PNG outside).
@Suite struct RenderProbe {
    let me = Avatar.Measurements(height: 173, chest: 90, waist: 83.5, hip: 89, thigh: 56.9,
                                 shoulderWidth: 37.6, armLength: 56.4, inseam: 83.4)

    func render(_ a: Avatar, yaw: Float, fitMap: Bool, name: String, marks: [Vec3] = []) {
        let W = 420, H = 820
        var color = [UInt8](repeating: 20, count: W * H * 3)
        var depth = [Float](repeating: -1e9, count: W * H)
        let scale: Float = 440, cx = Float(W) / 2, top: Float = 1.8
        let cy = cos(yaw), sy = sin(yaw)
        func view(_ p: Vec3) -> Vec3 { Vec3(p.x * cy + p.z * sy, p.y, -p.x * sy + p.z * cy) }
        let light = Vec3(-0.4, 0.6, 0.7).normalized
        func draw(_ mesh: Mesh, base: (Int) -> Vec3) {
            for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
                let ids = (0..<3).map { Int(mesh.indices[t + $0]) }
                let v = ids.map { view(mesh.positions[$0]) }
                let s = v.map { (cx + $0.x * scale, (top - $0.y) * scale, $0.z) }
                let n = (v[1] - v[0]).cross(v[2] - v[0]).normalized
                let shade = 0.35 + 0.65 * max(0, abs(n.dot(light)))
                let c = base(ids[0])
                let minX = max(0, Int(s.map(\.0).min()!)), maxX = min(W - 1, Int(s.map(\.0).max()!) + 1)
                let minY = max(0, Int(s.map(\.1).min()!)), maxY = min(H - 1, Int(s.map(\.1).max()!) + 1)
                guard minX <= maxX, minY <= maxY else { continue }
                let den = (s[1].1 - s[2].1) * (s[0].0 - s[2].0) + (s[2].0 - s[1].0) * (s[0].1 - s[2].1)
                guard abs(den) > 1e-6 else { continue }
                for y in minY...maxY { for x in minX...maxX {
                    let px = Float(x) + 0.5, py = Float(y) + 0.5
                    let w0 = ((s[1].1 - s[2].1) * (px - s[2].0) + (s[2].0 - s[1].0) * (py - s[2].1)) / den
                    let w1 = ((s[2].1 - s[0].1) * (px - s[2].0) + (s[0].0 - s[2].0) * (py - s[2].1)) / den
                    let w2 = 1 - w0 - w1
                    guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                    let z = w0 * s[0].2 + w1 * s[1].2 + w2 * s[2].2
                    let k = y * W + x
                    guard z > depth[k] else { continue }
                    depth[k] = z
                    color[k * 3] = UInt8(min(255, c.x * shade * 255)); color[k * 3 + 1] = UInt8(min(255, c.y * shade * 255))
                    color[k * 3 + 2] = UInt8(min(255, c.z * shade * 255))
                }}
            }
        }
        draw(a.body) { _ in Vec3(0.8, 0.81, 0.84) }
        let palette: [FitTone: Vec3] = [.fits: Vec3(0.2, 0.45, 0.9), .loose: Vec3(1, 0.85, 0.2), .long: Vec3(0.95, 0.2, 0.2),
                                        .tight: Vec3(0.6, 0.3, 0.9), .short: Vec3(1, 0.55, 0.15)]
        for layer in a.layers {
            let g = layer.mesh
            draw(g) { i in
                guard fitMap else { return Vec3(0.25, 0.32, 0.5) }
                let base = palette[.fits]!, tone = palette[g.tones[i]]!
                return base + (tone - base) * g.toneWeight[i]
            }
        }
        func plot(_ p: Vec3, _ c: Vec3, _ r: Int) {
            let v = view(p)
            let x = Int(cx + v.x * scale), y = Int((top - v.y) * scale)
            guard x >= 0, x < W, y >= 0, y < H, v.z >= depth[y * W + x] - 0.012 else { return }
            for dx in -r...r { for dy in -r...r where x + dx >= 0 && x + dx < W && y + dy >= 0 && y + dy < H {
                let k = (y + dy) * W + x + dx
                color[k * 3] = UInt8(c.x * 255); color[k * 3 + 1] = UInt8(c.y * 255); color[k * 3 + 2] = UInt8(c.z * 255) } }
        }
        func segments(_ pts: [Vec3], _ c: Vec3, _ r: Int) {
            for k in stride(from: 0, to: pts.count - 1, by: 2) {
                for t in 0...6 { plot(pts[k] + (pts[k + 1] - pts[k]) * (Float(t) / 6), c, r) }
            }
        }
        for layer in a.layers {
            segments(layer.seams, Vec3(0.95, 0.95, 0.95), 0)
            guard fitMap else { continue }
            for line in layer.fitLines {
                segments(line.line, palette[line.tone]! * 0.6 + Vec3(0.4, 0.4, 0.4), 1)
                segments(line.target, Vec3(1, 1, 1), 1)
            }
        }
        for l in a.landmarks {
            let v = view(l.position)
            let x = Int(cx + v.x * scale), y = Int((top - v.y) * scale)
            for dx in -2...2 { for dy in -2...2 where x + dx >= 0 && x + dx < W && y + dy >= 0 && y + dy < H {
                let k = (y + dy) * W + x + dx; color[k * 3] = 255; color[k * 3 + 1] = 60; color[k * 3 + 2] = 200 } }
        }
        for p in marks { plot(p, Vec3(0.1, 1, 0.2), 1) }
        let dir = ProcessInfo.processInfo.environment["RENDER_DIR"] ?? "."
        FileManager.default.createFile(atPath: dir + "/" + name + ".rgb", contents: Data(color))
    }

    @Test func renders() {
        guard ProcessInfo.processInfo.environment["RENDER_DIR"] != nil else { return }
        render(Avatar(me), yaw: 0, fitMap: false, name: "body_front")
        render(Avatar(me), yaw: 0.9, fitMap: false, name: "body_side")
        var tee = Avatar.GarmentFit(kind: .top(longSleeves: false))
        tee.chestEase = 10; tee.waistEase = 13; tee.hipEase = 13
        let t = Avatar(me, garment: tee)
        render(t, yaw: 0, fitMap: false, name: "tee_front")
        render(t, yaw: 0.6, fitMap: true, name: "tee_map")
        var tight = tee; tight.chestEase = -3; tight.waistEase = -1; tight.fabric = .woven
        render(Avatar(me, garment: tight), yaw: 0.3, fitMap: true, name: "tight_map")
        var pants = Avatar.GarmentFit(kind: .trousers)
        pants.waistEase = 1.5; pants.hipEase = 7; pants.thighEase = 9; pants.lengthDelta = 3
        let p = Avatar(me, garment: pants)
        render(p, yaw: 0, fitMap: false, name: "pants_front")
        render(p, yaw: 0.7, fitMap: true, name: "pants_map")
        // A small T-shirt whose shoulders are 2 cm too wide each side, over long trousers.
        var small = Avatar.GarmentFit(kind: .top(longSleeves: false))
        small.chestEase = 8; small.waistEase = 10; small.hipEase = 10; small.shoulderDelta = 4
        var long = pants; long.lengthDelta = 6
        let outfit = Avatar(me, garments: [small, long])
        render(outfit, yaw: 0.35, fitMap: true, name: "outfit_map")
        var shirt = Avatar.GarmentFit(kind: .top(longSleeves: true))
        shirt.chestEase = 18; shirt.waistEase = 22; shirt.hipEase = 22; shirt.sleeveDelta = 5; shirt.lengthDelta = 6
        render(Avatar(me, garment: shirt), yaw: -0.4, fitMap: true, name: "shirt_map")
    }
    /// Garment kinds and the body by sex: a coat, a jacket, a dress, a skirt; the same
    /// measurements as a man and as a woman.
    /// Leg cuts and top cuts: skinny to wide trousers, a regular and an oversized tee.
    @Test func cuts() {
        guard ProcessInfo.processInfo.environment["RENDER_DIR"] != nil else { return }
        let only = ProcessInfo.processInfo.environment["VARIANTS"].map { Set($0.split(separator: ",").map(String.init)) }
        func trousers(_ cut: LegCut?, thigh: Double, fit: FitStyle) -> Avatar.GarmentFit {
            var f = Avatar.GarmentFit(kind: .trousers)
            f.waistEase = 1.5; f.hipEase = cut == .skinny ? 2 : cut == .wide ? 12 : 7; f.thighEase = thigh
            f.legCut = cut; f.cut = fit; f.fabric = cut == .skinny ? .stretchJersey : .denim
            return f
        }
        var tee = Avatar.GarmentFit(kind: .top(longSleeves: false))
        tee.chestEase = 12; tee.waistEase = 15; tee.hipEase = 15; tee.fabric = .cottonJersey
        var over = tee; over.cut = .oversized; over.chestEase = 30; over.waistEase = 34; over.hipEase = 34
        over.shoulderDelta = 8; over.hemOffset = 5
        let cases: [(String, [Avatar.GarmentFit])] = [
            ("skinny", [trousers(.skinny, thigh: 2, fit: .slim)]), ("slim", [trousers(.slim, thigh: 5, fit: .slim)]),
            ("regular", [trousers(nil, thigh: 9, fit: .regular)]), ("straight", [trousers(.straight, thigh: 9, fit: .regular)]),
            ("wide", [trousers(.wide, thigh: 18, fit: .relaxed)]), ("flare", [trousers(.flare, thigh: 5, fit: .slim)]),
            ("tapered", [trousers(.tapered, thigh: 12, fit: .regular)]),
            ("tee", [tee]), ("oversized", [over]),
        ]
        for (name, garments) in cases where only?.contains(name) ?? true {
            let a = Avatar(me, garments: garments)
            render(a, yaw: 0, fitMap: true, name: "cut_\(name)_front")
            render(a, yaw: -.pi / 2, fitMap: true, name: "cut_\(name)_side")
            print("CUT", name, a.fitReport.map { "\($0.key) \($0.value.tension)" }.sorted())
        }
    }

    @Test func styles() {
        guard ProcessInfo.processInfo.environment["RENDER_DIR"] != nil else { return }
        let only = ProcessInfo.processInfo.environment["VARIANTS"].map { Set($0.split(separator: ",").map(String.init)) }
        let her = Avatar.Measurements(height: 165, chest: 92, waist: 72, hip: 98, thigh: 56,
                                      shoulderWidth: 35, armLength: 53, inseam: 76, sex: .female)
        var him = me; him.sex = .male
        var coat = Avatar.GarmentFit(kind: .top(longSleeves: true)); coat.style = .coat
        coat.chestEase = 18; coat.waistEase = 22; coat.hipEase = 24; coat.sleeveDelta = 2
        var jacket = coat; jacket.style = .jacket; jacket.chestEase = 14; jacket.waistEase = 16; jacket.hipEase = 16
        var dress = Avatar.GarmentFit(kind: .top(longSleeves: false)); dress.style = .dress
        dress.chestEase = 8; dress.waistEase = 6; dress.hipEase = 12
        var skirt = Avatar.GarmentFit(kind: .skirt); skirt.waistEase = 1; skirt.hipEase = 8
        var blouse = Avatar.GarmentFit(kind: .top(longSleeves: true)); blouse.chestEase = 10; blouse.waistEase = 12; blouse.hipEase = 12
        let cases: [(String, Avatar.Measurements, [Avatar.GarmentFit])] = [
            ("body_him", him, []), ("body_her", her, []),
            ("coat", him, [coat]), ("jacket", him, [jacket]),
            ("dress", her, [dress]), ("skirt", her, [skirt, blouse]), ("coat_her", her, [coat]),
        ]
        for (name, m, garments) in cases where only?.contains(name) ?? true {
            let a = Avatar(m, garments: garments)
            render(a, yaw: 0, fitMap: true, name: "style_\(name)_front")
            render(a, yaw: -.pi / 2, fitMap: true, name: "style_\(name)_side")
            print(name, a.fitReport.map { "\($0.key) \($0.value.tension)" }.sorted())
        }
    }

    /// The outfit from the device screenshots: a slim tee with wide shoulders over trousers.
    @Test func screenshotOutfit() {
        guard ProcessInfo.processInfo.environment["RENDER_DIR"] != nil else { return }
        var tee = Avatar.GarmentFit(kind: .top(longSleeves: false))
        tee.chestEase = 5; tee.waistEase = 8; tee.hipEase = 8; tee.shoulderDelta = 9; tee.lengthDelta = 8
        tee.fabric = .knit
        for (label, waist) in [("33", 3.0), ("28", -7.0)] {
            var pants = Avatar.GarmentFit(kind: .trousers)
            pants.waistEase = waist; pants.hipEase = 7; pants.thighEase = 9; pants.lengthDelta = 2
            let p = Avatar(me, garment: pants)
            render(p, yaw: .pi, fitMap: true, name: "shot_pants\(label)_back")
            render(p, yaw: 0, fitMap: true, name: "shot_pants\(label)_front")
            print("zones \(label):", p.fitReport.map { "\($0.key) \($0.value.tension) \(Int($0.value.stretchPercent))% c\(Int($0.value.contactShare * 100))" }.sorted())
            let o = Avatar(me, garments: [tee, pants])
            render(o, yaw: 0, fitMap: true, name: "shot_outfit\(label)_front")
            render(o, yaw: -.pi / 2, fitMap: true, name: "shot_outfit\(label)_side")
            render(o, yaw: .pi, fitMap: true, name: "shot_outfit\(label)_back")
        }
    }
    /// Body points a garment should cover but doesn't: no fabric within 6 cm outside
    /// the skin there (a gap, or skin poking through the cloth).
    static func uncovered(_ a: Avatar, layer: Int, region: (Vec3) -> Bool) -> (share: Double, points: [Vec3]) {
        let g = a.layers[layer].mesh.positions
        let cell: Float = 0.03
        func key(_ p: Vec3) -> SIMD3<Int32> {
            SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down)))
        }
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for i in g.indices { grid[key(g[i]), default: []].append(i) }
        var total = 0
        var open: [Vec3] = []
        for i in a.body.positions.indices {
            let p = a.body.positions[i], n = a.body.normals[i]
            guard region(p) else { continue }
            total += 1
            let k = key(p + n * 0.03)
            var found = false
            search: for dx: Int32 in -2...2 { for dy: Int32 in -2...2 { for dz: Int32 in -2...2 {
                for j in grid[k &+ SIMD3(dx, dy, dz)] ?? [] {
                    let d = g[j] - p, along = d.dot(n)
                    guard along > -0.004, along < 0.06 else { continue }
                    if (d - n * along).length < 0.025 { found = true; break search }
                }
            } } }
            if !found { open.append(p) }
        }
        return (total > 0 ? Double(open.count) / Double(total) : 0, open)
    }

    /// Sizes from tight to loose on a body like the user's, dressed as the app dresses
    /// them (the animated dressing), from the front, side and back, with the body
    /// points the garment leaves uncovered marked green.
    @Test func variations() {
        guard ProcessInfo.processInfo.environment["RENDER_DIR"] != nil else { return }
        let user = Avatar.Measurements(height: 173, chest: 92, waist: 82, hip: 92, thigh: 56,
                                       shoulderWidth: 37, armLength: 56, inseam: 81)
        let model = BodyModel.make(user)
        let waistband = (model.waistY + model.hipY) / 2
        let only = ProcessInfo.processInfo.environment["VARIANTS"]
        func trousersRegion(_ p: Vec3) -> Bool {
            p.y > model.kneeY && p.y < waistband - 0.025 && abs(p.x) < model.hip.0 + 0.03
        }
        let trousers: [(String, Double, Double, Double)] = [
            ("t-6", -6, 4, 6), ("t-2", -2, 5, 7), ("t+2", 2, 7, 9), ("t+6", 6, 9, 12), ("t+14", 14, 14, 18), ("trelax", 3, 14, 20),
        ]
        for (name, waist, hip, thigh) in trousers where only == nil || only!.contains(name) {
            var f = Avatar.GarmentFit(kind: .trousers)
            f.waistEase = waist; f.hipEase = hip; f.thighEase = thigh; f.lengthDelta = 2
            let a = Avatar(user, garment: f, detail: .animated)
            let (share, open) = Self.uncovered(a, layer: 0, region: trousersRegion)
            print("VAR \(name): uncovered \(String(format: "%.1f", share * 100))%",
                  a.fitReport.map { "\($0.key)=\($0.value.tension) \(Int($0.value.stretchPercent))% c\(Int($0.value.contactShare * 100)) g\(String(format: "%.1f", $0.value.gapCm)) e\(Int($0.value.easeCm))" }.sorted())
            for (yaw, view) in [(Float(0), "front"), (Float.pi, "back"), (-Float.pi / 2, "side")] {
                render(a, yaw: yaw, fitMap: true, name: "var_\(name)_\(view)", marks: open)
            }
        }
        let tops: [(String, Double, Double, Double)] = [
            ("s-4", -4, 0, 0), ("s+6", 6, 0, 0), ("s+12d4", 12, 4, 2), ("s+30d10", 30, 10, 4),
        ]
        for (name, chest, shoulder, length) in tops where only == nil || only!.contains(name) {
            var f = Avatar.GarmentFit(kind: .top(longSleeves: false))
            f.chestEase = chest; f.waistEase = chest + 3; f.hipEase = chest + 3; f.shoulderDelta = shoulder; f.lengthDelta = length
            let a = Avatar(user, garment: f, detail: .animated)
            let hem = (a.layers[0].mesh.positions.map(\.y).min() ?? 0) + 0.04
            let (share, open) = Self.uncovered(a, layer: 0) { p in
                p.y > hem && p.y < model.armpitY - 0.03 && abs(p.x) < model.chest.0 + 0.02
            }
            print("VAR \(name): uncovered \(String(format: "%.1f", share * 100))%",
                  a.fitReport.map { "\($0.key)=\($0.value.tension) \(Int($0.value.stretchPercent))% c\(Int($0.value.contactShare * 100)) g\(String(format: "%.1f", $0.value.gapCm)) e\(Int($0.value.easeCm))" }.sorted(),
                  a.layers[0].fitLines.map { "\($0.kind)=\($0.tone) \($0.deltaCm)" })
            for (yaw, view) in [(Float(0), "front"), (Float.pi, "back"), (-Float.pi / 2, "side")] {
                render(a, yaw: yaw, fitMap: true, name: "var_\(name)_\(view)", marks: open)
            }
        }
        if only == nil || only!.contains("outfit") {
            var top = Avatar.GarmentFit(kind: .top(longSleeves: false))
            top.chestEase = 12; top.waistEase = 15; top.hipEase = 15; top.shoulderDelta = 4; top.lengthDelta = 2
            var pants = Avatar.GarmentFit(kind: .trousers)
            pants.waistEase = 2; pants.hipEase = 7; pants.thighEase = 9; pants.lengthDelta = 2
            let a = Avatar(user, garments: [top, pants], detail: .animated)
            let (share, open) = Self.uncovered(a, layer: 1, region: trousersRegion)
            print("VAR outfit: trousers uncovered \(String(format: "%.1f", share * 100))%")
            for (yaw, view) in [(Float(0), "front"), (Float.pi, "back"), (-Float.pi / 2, "side")] {
                render(a, yaw: yaw, fitMap: true, name: "var_outfit_\(view)", marks: open)
            }
        }
    }
    /// Open edges of a garment drawn as marks: where its holes are.
    @Test func holes() {
        guard ProcessInfo.processInfo.environment["RENDER_DIR"] != nil else { return }
        let user = Avatar.Measurements(height: 173, chest: 92, waist: 82, hip: 92, thigh: 56,
                                       shoulderWidth: 37, armLength: 56, inseam: 81)
        var f = Avatar.GarmentFit(kind: .trousers)
        f.waistEase = 20; f.hipEase = 24; f.thighEase = 28; f.lengthDelta = 2
        var top = Avatar.GarmentFit(kind: .top(longSleeves: false))
        top.chestEase = 6; top.waistEase = 9; top.hipEase = 9; top.lengthDelta = 3
        for (name, fit) in [("holes_trousers", f), ("holes_top", top)] {
            let a = Avatar(user, garment: fit, detail: .preview)
            let mesh = a.layers[0].mesh
            var count: [Int: Int] = [:]
            for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
                for e in 0..<3 {
                    let x = Int(mesh.indices[t + e]), y = Int(mesh.indices[t + (e + 1) % 3])
                    count[min(x, y) << 32 | max(x, y), default: 0] += 1
                }
            }
            let open = count.filter { $0.value == 1 }.flatMap { [mesh.positions[$0.key >> 32], mesh.positions[$0.key & 0xFFFF_FFFF]] }
            for (yaw, view) in [(Float(0), "front"), (Float.pi / 2, "side"), (Float.pi / 4, "diag")] {
                render(a, yaw: yaw, fitMap: false, name: "\(name)_\(view)", marks: open)
            }
        }
    }
}
