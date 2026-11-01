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
        // Where the seam sits is its line and label; the fabric round it isn't coloured loose.
        #expect(share(wide.mesh, .loose) <= share(regular.mesh, .loose) + 0.02)
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

    /// The size-chart verdict wins over the drape's own reading: a tee whose length is
    /// 8 cm past the middle of the usual range but only 2 cm past its end says 2 cm, and
    /// a waist the verdict calls fine isn't drawn tight.
    @Test func linesSayWhatTheVerdictSays() {
        var tee = Avatar.GarmentFit(kind: .top(longSleeves: false))
        tee.chestEase = 10; tee.waistEase = 12; tee.hipEase = 12; tee.lengthDelta = 8; tee.shoulderDelta = 4
        tee.judged = .init(length: 2, shoulderPerSide: 0)
        let top = Avatar(me, garment: tee, detail: .preview).layers[0]
        let hem = top.fitLines.first { $0.kind == .hem }!
        #expect(hem.tone == .long && hem.deltaCm == 2)
        #expect(top.fitLines.first { $0.kind == .shoulderSeam }?.tone == .fits)
        // The dropped shoulder isn't coloured loose when the verdict says it fits.
        var unjudged = tee
        unjudged.judged = .init()
        #expect(share(top.mesh, .loose) <= share(Avatar(me, garment: unjudged, detail: .preview).layers[0].mesh, .loose) + 0.01)
        tee.judged = .init(length: 0)
        #expect(Avatar(me, garment: tee, detail: .preview).layers[0].fitLines.first { $0.kind == .hem }?.tone == .fits)

        var trousers = Avatar.GarmentFit(kind: .trousers)
        trousers.waistEase = -4; trousers.hipEase = 7; trousers.thighEase = 9
        trousers.judged = .init(waist: .fits)
        let pants = Avatar(me, garment: trousers, detail: .preview).layers[0]
        #expect(pants.fitLines.first { $0.kind == .waistband }?.tone == .fits)
    }

    /// Wide trouser legs hang off the body: whatever they stretch under their own weight
    /// isn't tightness.
    @Test func hangingLegsAreNotTight() {
        var trousers = Avatar.GarmentFit(kind: .trousers)
        trousers.waistEase = 3; trousers.hipEase = 12; trousers.thighEase = 20; trousers.fabric = .woven
        let report = Avatar(me, garment: trousers, detail: .preview).fitReport
        for zone in [FitZone.knee, .hem] {
            #expect((report[zone]?.tension ?? ZoneTension.comfortable) <= ZoneTension.comfortable, "\(zone)")
        }
    }
    /// The map says what the size chart says where it judged: a waist called tight shows
    /// purple where the fabric touches, one called fine doesn't (short of the fabric
    /// being stretched past its limit), and the zone report agrees.
    @Test func mapFollowsTheVerdictWhereThereIsOne() {
        var trousers = Avatar.GarmentFit(kind: .trousers)
        trousers.waistEase = 1; trousers.hipEase = 7; trousers.thighEase = 9
        trousers.judged = .init(zones: [.waist: .tight], tensions: [.waist: .slightlyTight])
        let tight = Avatar(me, garment: trousers, detail: .preview)
        #expect(share(tight.layers[0].mesh, .tight) > 0.03)
        #expect(tight.fitReport[.waist]?.tension == .slightlyTight)
        trousers.judged = .init(zones: [.waist: .fits, .hip: .fits, .thigh: .fits],
                                tensions: [.waist: .comfortable, .hip: .comfortable, .thigh: .comfortable])
        let fine = Avatar(me, garment: trousers, detail: .preview)
        #expect(share(fine.layers[0].mesh, .tight) < 0.01)
        #expect(share(fine.layers[0].mesh, .loose) < 0.01)
        #expect(fine.fitReport[.waist]?.tension == .comfortable)
    }

    /// Regular trousers: nothing loose round the knees or hems (they hang as cut), and
    /// their own weight doesn't make anything read tight.
    @Test func regularTrousersReadFine() {
        var trousers = Avatar.GarmentFit(kind: .trousers)
        trousers.waistEase = 2; trousers.hipEase = 7; trousers.thighEase = 9
        let a = Avatar(me, garment: trousers, detail: .preview)
        for zone in [FitZone.waist, .hip, .thigh, .knee, .hem] {
            #expect(a.fitReport[zone]?.tension == .comfortable, "\(zone): \(String(describing: a.fitReport[zone]))")
        }
        #expect(share(a.layers[0].mesh, .loose) < 0.01 && share(a.layers[0].mesh, .tight) < 0.01)
    }
}

extension Avatar { typealias Line = [Vec3] }
