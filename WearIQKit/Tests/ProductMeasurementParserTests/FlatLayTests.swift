import Foundation
import Testing
@testable import ProductMeasurementParser
import WearIQCore

/// A garment drawn on a table in centimetres, photographed through a tilted camera
/// (a known homography), then measured back from the photo.
@Suite struct FlatLayTests {
    typealias P = FlatLay.Point

    /// A tee seen flat, collar up: body 54 cm wide (108 round), 70 cm long from the
    /// shoulder, sleeves 20 cm out each side from 0 to 18 cm below the top.
    static func tee(_ x: Double, _ y: Double) -> Bool {
        let cx = 60.0, top = 20.0
        let dy = y - top
        guard dy >= 0, dy <= 70 else { return false }
        if abs(x - cx) <= 27 { return true }
        if dy <= 18, abs(x - cx) <= 47 { return dy >= Double(abs(x - cx) - 27) * 0.4 }
        return false
    }

    /// Trousers: waist 40 flat (80 round), seat 50 flat at 20 cm, crotch at 28 cm, legs 22
    /// cm wide, 100 cm long.
    static func trousers(_ x: Double, _ y: Double) -> Bool {
        let cx = 60.0, top = 10.0
        let dy = y - top
        guard dy >= 0, dy <= 100 else { return false }
        let half = dy < 20 ? 20 + dy / 20 * 5 : 25.0 - max(0, dy - 28) * 0.05
        guard abs(x - cx) <= half else { return false }
        if dy >= 28 { return abs(x - cx) >= 2.5 }
        return true
    }

    /// The paper, 21 × 29.7, beside the garment, in table cm.
    static let paper = [P(112, 30), P(133, 30), P(133, 59.7), P(112, 59.7)]

    /// A camera looking down at an angle: table cm → photo pixels.
    static let camera = FlatLay.Homography(m: [9.0, 1.2, 80, -0.4, 7.2, 60, 0.0004, 0.0021, 1])

    static func photo(_ inside: (Double, Double) -> Bool) -> (FlatLay.Mask, [P]) {
        let back = camera.inverse!
        let mask = FlatLay.Mask(width: 1400, height: 1100) { x, y in
            let t = back.apply(P(Double(x), Double(y)))
            return inside(t.x, t.y) || (t.x >= 112 && t.x <= 133 && t.y >= 30 && t.y <= 59.7)
        }
        return (mask, paper.map(camera.apply))
    }

    @Test func homographyRoundTrip() throws {
        let from = [P(0, 0), P(10, 0), P(10, 5), P(0, 5)]
        let to = from.map(Self.camera.apply)
        let h = try #require(FlatLay.Homography.mapping(from, to: to))
        let p = h.apply(P(3, 4)), q = Self.camera.apply(P(3, 4))
        #expect(abs(p.x - q.x) < 1e-6 && abs(p.y - q.y) < 1e-6)
    }

    @Test func measuresATeeFromATiltedPhoto() throws {
        let (mask, corners) = Self.photo(Self.tee)
        let map = try #require(FlatLay.tableMap(paperCorners: corners, imageWidth: 1400, imageHeight: 1100))
        let grid = try #require(FlatLay.rectify(mask, map: map, paperCorners: corners))
        let result = FlatLay.measure(grid, cellCm: 0.5, category: .tshirt)
        let chest = try #require(result[.chest])
        #expect(abs(chest - 108) <= 3)
        let length = try #require(result[.bodyLength])
        #expect(abs(length - 70) <= 2.5)
    }

    @Test func measuresTrousers() throws {
        let (mask, corners) = Self.photo(Self.trousers)
        let map = try #require(FlatLay.tableMap(paperCorners: corners, imageWidth: 1400, imageHeight: 1100))
        let grid = try #require(FlatLay.rectify(mask, map: map, paperCorners: corners))
        let result = FlatLay.measure(grid, cellCm: 0.5, category: .pants)
        #expect(abs((result[.waist] ?? 0) - 80) <= 4)
        #expect(abs((result[.hip] ?? 0) - 100) <= 4)
        #expect(abs((result[.inseam] ?? 0) - 72) <= 3)
        #expect(abs((result[.outseam] ?? 0) - 100) <= 2.5)
        #expect(abs((result[.thigh] ?? 0) - 45) <= 4)
    }

    @Test func paperTurnedSidewaysStillReadsUp() throws {
        // The same paper with its corners listed from another corner.
        let (mask, corners) = Self.photo(Self.tee)
        let rotated = Array(corners[1...] + corners[..<1])
        let map = try #require(FlatLay.tableMap(paperCorners: rotated, imageWidth: 1400, imageHeight: 1100))
        let grid = try #require(FlatLay.rectify(mask, map: map, paperCorners: rotated))
        let result = FlatLay.measure(grid, cellCm: 0.5, category: .tshirt)
        #expect(abs((result[.chest] ?? 0) - 108) <= 3)
    }

    @Test func blobIsNotATee() {
        let mask = FlatLay.Mask(width: 100, height: 100) { x, y in (x - 50) * (x - 50) + (y - 50) * (y - 50) < 900 }
        #expect(FlatLay.measure(mask, cellCm: 0.5, category: .tshirt).isEmpty)
    }
}
