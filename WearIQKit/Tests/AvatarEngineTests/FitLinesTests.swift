import Testing
@testable import AvatarEngine

@Suite struct FitLinesTests {
    let me = Avatar.Measurements(height: 178, chest: 100, waist: 86, hip: 98, thigh: 58,
                                 shoulderWidth: 46, armLength: 63, inseam: 81)

    func share(_ m: Mesh, _ tone: FitTone) -> Double {
        Double(m.tones.filter { $0 == tone }.count) / Double(m.tones.count)
    }

    @Test func wideShouldersDropTheSeamAndShowWhereItBelongs() {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: false))
        fit.chestEase = 10; fit.waistEase = 12; fit.hipEase = 12
        let regular = Avatar(me, garment: fit, detail: .preview).layers[0]
        fit.shoulderDelta = 4
        let wide = Avatar(me, garment: fit, detail: .preview).layers[0]
        let seam = { (l: Avatar.Layer) in l.fitLines.first { $0.kind == .shoulderSeam }! }
        #expect(seam(regular).tone == .fits && seam(regular).target.isEmpty)
        #expect(seam(wide).tone == .loose && seam(wide).deltaCm == 2 && !seam(wide).target.isEmpty)
        // The dropped seam sits further out than the regular one.
        let outer = { (l: Avatar.Line) in l.map { abs($0.x) }.reduce(0, +) / Float(l.count) }
        #expect(outer(seam(wide).line) > outer(seam(regular).line) + 0.008)
        #expect(share(wide.mesh, .loose) > share(regular.mesh, .loose))
    }

    @Test func longSleevesAndHemAreRed() {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: true))
        fit.chestEase = 12; fit.waistEase = 14; fit.hipEase = 14; fit.sleeveDelta = 5; fit.lengthDelta = 6
        let layer = Avatar(me, garment: fit, detail: .preview).layers[0]
        #expect(layer.fitLines.first { $0.kind == .sleeveEnd }?.tone == .long)
        #expect(layer.fitLines.first { $0.kind == .hem }?.tone == .long)
        #expect(share(layer.mesh, .long) > 0.05)
        #expect(layer.mesh.tones.count == layer.mesh.positions.count)
    }

    @Test func tightWovenIsPurpleWhereItPresses() {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: false))
        fit.chestEase = -5; fit.waistEase = -4; fit.hipEase = -2; fit.fabric = .woven
        let layer = Avatar(me, garment: fit, detail: .preview).layers[0]
        #expect(share(layer.mesh, .tight) > 0.1)
    }

    @Test func topOverTrousers() {
        var top = Avatar.GarmentFit(kind: .top(longSleeves: false))
        top.chestEase = 12; top.waistEase = 14; top.hipEase = 14
        var trousers = Avatar.GarmentFit(kind: .trousers)
        trousers.waistEase = 1.5; trousers.hipEase = 7; trousers.thighEase = 9
        let avatar = Avatar(me, garments: [top, trousers], detail: .preview)
        #expect(avatar.layers.count == 2)
        // Layers keep the order given; the first is the top.
        if case .top = avatar.layers[0].fit.kind {} else { Issue.record("first layer should be the top") }
        // Where the top covers the waistband it lies over it, not inside the trousers.
        let model = BodyModel.make(me)
        let waistband = (model.waistY + model.hipY) / 2
        let shirt = avatar.layers[0].mesh.positions.filter { abs($0.y - (waistband - 0.03)) < 0.01 }
        let pants = avatar.layers[1].mesh.positions.filter { abs($0.y - (waistband - 0.03)) < 0.01 }
        let reach = { (ps: [Vec3]) in ps.map { ($0.x * $0.x + $0.z * $0.z).squareRoot() }.reduce(0, +) / Float(max(1, ps.count)) }
        #expect(reach(shirt) > reach(pants))
    }

    @Test func hemSwingsMoreThanShoulders() {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: false))
        fit.chestEase = 20; fit.waistEase = 24; fit.hipEase = 24
        let mesh = Avatar(me, garment: fit, detail: .preview).layers[0].mesh
        let top = mesh.positions.indices.filter { mesh.positions[$0].y > 1.4 }.map { mesh.sway[$0] }
        let hem = mesh.positions.indices.filter { mesh.positions[$0].y < mesh.minY + 0.05 }.map { mesh.sway[$0] }
        #expect(top.max()! < 0.05)
        #expect(hem.reduce(0, +) / Float(hem.count) > 0.3)
    }
}

extension Avatar { typealias Line = [Vec3] }
