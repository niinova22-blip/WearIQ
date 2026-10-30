import Foundation
import Testing
@testable import AvatarEngine

/// Renders avatars to raw RGB files for eyeballing (converted to PNG outside).
@Suite struct RenderProbe {
    let me = Avatar.Measurements(height: 173, chest: 90, waist: 83.5, hip: 89, thigh: 56.9,
                                 shoulderWidth: 37.6, armLength: 56.4, inseam: 83.4)

    func render(_ a: Avatar, yaw: Float, fitMap: Bool, name: String) {
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
        if let g = a.garment {
            draw(g) { i in
                guard fitMap else { return Vec3(0.25, 0.32, 0.5) }
                let s = g.strain[i]
                let relaxed = Vec3(0.3, 0.55, 0.75), on = Vec3(0.36, 0.75, 0.6), close = Vec3(0.98, 0.8, 0.32), pull = Vec3(0.9, 0.3, 0.28)
                if s < 0.35 { return relaxed + (on - relaxed) * (s / 0.35) }
                if s < 0.7 { return on + (close - on) * ((s - 0.35) / 0.35) }
                return close + (pull - close) * min(1, (s - 0.7) / 0.4)
            }
        }
        for i in stride(from: 0, to: a.seams.count, by: 1) {
            let v = view(a.seams[i])
            let x = Int(cx + v.x * scale), y = Int((top - v.y) * scale)
            guard x >= 0, x < W, y >= 0, y < H, v.z >= depth[y * W + x] - 0.01 else { continue }
            color[(y * W + x) * 3] = 250; color[(y * W + x) * 3 + 1] = 250; color[(y * W + x) * 3 + 2] = 250
        }
        for l in a.landmarks {
            let v = view(l.position)
            let x = Int(cx + v.x * scale), y = Int((top - v.y) * scale)
            for dx in -2...2 { for dy in -2...2 where x + dx >= 0 && x + dx < W && y + dy >= 0 && y + dy < H {
                let k = (y + dy) * W + x + dx; color[k * 3] = 255; color[k * 3 + 1] = 60; color[k * 3 + 2] = 200 } }
        }
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
    }
}
