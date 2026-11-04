import Foundation
import WearIQCore

/// Measures a garment from one photo of it laid flat next to an A4 sheet of paper.
///
/// The paper gives the scale and the plane: its four corners in the photo fix a
/// homography to centimetres on the table, so the photo needn't be taken straight from
/// above. The garment's outline (a foreground mask from the photo) is resampled onto a
/// grid of centimetres on the table and measured the way a tailor measures a flat
/// garment: chest a little under the armpits, waist at the narrowest, hem, length from
/// the top; trousers at the waistband, the seat, the thigh under the crotch, the inseam.
/// Girths are full circumferences (twice the flat width), as in size charts.
public enum FlatLay {
    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    /// A4 in centimetres.
    public static let paperSize = (short: 21.0, long: 29.7)

    /// A binary image, row-major, `true` where the garment is.
    public struct Mask: Sendable {
        public var width: Int
        public var height: Int
        public var pixels: [Bool]

        public init(width: Int, height: Int, pixels: [Bool]) {
            precondition(pixels.count == width * height)
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        public init(width: Int, height: Int, _ inside: (Int, Int) -> Bool) {
            self.width = width
            self.height = height
            var p = [Bool](repeating: false, count: width * height)
            for y in 0..<height { for x in 0..<width { p[y * width + x] = inside(x, y) } }
            pixels = p
        }

        public subscript(x: Int, y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && pixels[y * width + x]
        }
    }

    // MARK: Plane

    /// A 3×3 projective map, row-major.
    public struct Homography: Sendable {
        public var m: [Double]

        public func apply(_ p: Point) -> Point {
            let w = m[6] * p.x + m[7] * p.y + m[8]
            return Point((m[0] * p.x + m[1] * p.y + m[2]) / w, (m[3] * p.x + m[4] * p.y + m[5]) / w)
        }

        /// The map taking four points to four others (no three on a line).
        public static func mapping(_ from: [Point], to: [Point]) -> Homography? {
            guard from.count == 4, to.count == 4 else { return nil }
            // A·h = b with h33 = 1.
            var a = [[Double]](), b = [Double]()
            for i in 0..<4 {
                let (x, y, u, v) = (from[i].x, from[i].y, to[i].x, to[i].y)
                a.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.append(u)
                a.append([0, 0, 0, x, y, 1, -v * x, -v * y]); b.append(v)
            }
            guard let h = solve(a, b) else { return nil }
            return Homography(m: h + [1])
        }

        public var inverse: Homography? {
            let (a, b, c, d, e, f, g, h, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
            let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
            guard abs(det) > 1e-12 else { return nil }
            return Homography(m: [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
                                  (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
                                  (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det])
        }

        /// Gaussian elimination with partial pivoting.
        static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
            let n = b.count
            var m = a.enumerated().map { $1 + [b[$0]] }
            for col in 0..<n {
                guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else { return nil }
                m.swapAt(col, pivot)
                for row in 0..<n where row != col {
                    let f = m[row][col] / m[col][col]
                    if f != 0 { for k in col...n { m[row][k] -= f * m[col][k] } }
                }
            }
            return (0..<n).map { m[$0][n] / m[$0][$0] }
        }
    }

    /// The map from photo pixels (origin top left) to table centimetres, from the
    /// paper's corners in the photo in order round the sheet (either direction, any
    /// start). The longer sides are taken as A4's long ones. The result is turned so the
    /// photo's up is the table's up: the garment is laid with its collar or waistband
    /// towards the top of the photo, wherever the paper lies.
    public static func tableMap(paperCorners c: [Point], imageWidth: Double, imageHeight: Double) -> Homography? {
        guard c.count == 4 else { return nil }
        func dist(_ a: Point, _ b: Point) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
        let first = dist(c[0], c[1]) + dist(c[2], c[3]), second = dist(c[1], c[2]) + dist(c[3], c[0])
        let (w, h) = first >= second ? (paperSize.long, paperSize.short) : (paperSize.short, paperSize.long)
        guard let map = Homography.mapping(c, to: [Point(0, 0), Point(w, 0), Point(w, h), Point(0, h)]) else { return nil }
        let centre = map.apply(Point(imageWidth / 2, imageHeight / 2))
        let up = map.apply(Point(imageWidth / 2, imageHeight * 0.4))
        let phi = atan2(up.y - centre.y, up.x - centre.x)
        let alpha = -Double.pi / 2 - phi
        let r = [cos(alpha), -sin(alpha), 0, sin(alpha), cos(alpha), 0, 0, 0, 1]
        return Homography(m: multiply(r, map.m))
    }

    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        (0..<3).flatMap { i in (0..<3).map { j in (0..<3).reduce(0.0) { $0 + a[i * 3 + $1] * b[$1 * 3 + j] } } }
    }

    /// The garment on a grid of `cellCm` squares in table coordinates. Pixels inside the
    /// paper (and a 1 cm margin) are dropped, and only the largest connected piece is kept.
    public static func rectify(_ mask: Mask, map: Homography, paperCorners: [Point], cellCm: Double = 0.5) -> Mask? {
        guard let back = map.inverse else { return nil }
        // Bounds of the garment in table coordinates.
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        let step = max(1, min(mask.width, mask.height) / 200)
        for y in stride(from: 0, to: mask.height, by: step) {
            for x in stride(from: 0, to: mask.width, by: step) where mask[x, y] {
                let p = map.apply(Point(Double(x), Double(y)))
                guard p.x.isFinite, p.y.isFinite else { continue }
                minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        guard minX < maxX, minY < maxY, maxX - minX < 400, maxY - minY < 400 else { return nil }
        let paper = paperCorners.map { map.apply($0) }
        let w = Int(((maxX - minX) / cellCm).rounded(.up)) + 3, h = Int(((maxY - minY) / cellCm).rounded(.up)) + 3
        let grid = Mask(width: w, height: h) { gx, gy in
            let t = Point(minX + (Double(gx) - 1) * cellCm, minY + (Double(gy) - 1) * cellCm)
            if nearQuad(t, paper, margin: 1) { return false }
            let s = back.apply(t)
            return mask[Int(s.x.rounded()), Int(s.y.rounded())]
        }
        return largestPiece(grid)
    }

    /// Inside a convex quadrilateral or within `margin` of its edges.
    static func nearQuad(_ p: Point, _ q: [Point], margin: Double) -> Bool {
        var sign = 0.0, inside = true
        for i in 0..<q.count {
            let a = q[i], b = q[(i + 1) % q.count]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if cross != 0 {
                if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { inside = false }
            }
            // Distance to the edge segment.
            let dx = b.x - a.x, dy = b.y - a.y
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(1e-9, dx * dx + dy * dy)))
            let ex = a.x + t * dx - p.x, ey = a.y + t * dy - p.y
            if ex * ex + ey * ey <= margin * margin { return true }
        }
        return inside
    }

    /// The biggest 4-connected region.
    static func largestPiece(_ mask: Mask) -> Mask {
        var label = [Int](repeating: 0, count: mask.pixels.count)
        var best = 0, bestSize = 0, next = 0
        for start in mask.pixels.indices where mask.pixels[start] && label[start] == 0 {
            next += 1
            var stack = [start], size = 0
            label[start] = next
            while let i = stack.popLast() {
                size += 1
                let x = i % mask.width, y = i / mask.width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where mask[nx, ny] {
                    let j = ny * mask.width + nx
                    if label[j] == 0 { label[j] = next; stack.append(j) }
                }
            }
            if size > bestSize { bestSize = size; best = next }
        }
        return Mask(width: mask.width, height: mask.height, pixels: label.map { $0 == best && best > 0 })
    }

    // MARK: Measuring

    /// Measurements of a garment on a table grid of `cellCm` squares, with its top (collar
    /// or waistband) towards row 0. Empty when the outline doesn't look like the category.
    public static func measure(_ mask: Mask, cellCm: Double, category: GarmentCategory) -> [GarmentDimension: Double] {
        let rows = (0..<mask.height).map { y in runs(mask, row: y) }
        guard let top = rows.firstIndex(where: { !$0.isEmpty }), let bottom = rows.lastIndex(where: { !$0.isEmpty }),
              bottom - top >= 10 else { return [:] }
        func cm(_ cells: Int) -> Double { Double(cells) * cellCm }
        func span(_ y: Int) -> Int { rows[y].map { $0.upperBound - $0.lowerBound + 1 }.reduce(0, +) }
        func outer(_ y: Int) -> Int { rows[y].isEmpty ? 0 : rows[y].last!.upperBound - rows[y].first!.lowerBound + 1 }
        let length = bottom - top + 1
        var result: [GarmentDimension: Double] = [:]

        if category.isBottom {
            // Waistband: a little under the top edge.
            let waistRow = min(bottom, top + max(1, Int(2 / cellCm)))
            result[.waist] = 2 * cm(span(waistRow))
            if category == .skirt {
                // Seat: widest in the upper 40%.
                let seat = (top...(top + length * 2 / 5)).max { span($0) < span($1) } ?? waistRow
                result[.hip] = 2 * cm(span(seat))
                result[.outseam] = cm(length)
                return result
            }
            // Crotch: the first row (below the top fifth) where the outline splits into legs.
            guard let crotch = ((top + length / 5)...bottom).first(where: { rows[$0].count >= 2 }) else {
                return category == .shorts || category == .pants ? result : [:]
            }
            let seat = (waistRow...crotch).max { outer($0) < outer($1) } ?? crotch
            result[.hip] = 2 * cm(outer(seat))
            let thighRow = min(bottom, crotch + Int(2.5 / cellCm))
            if let leg = rows[thighRow].max(by: { $0.count < $1.count }) {
                result[.thigh] = 2 * cm(leg.count)
            }
            result[.inseam] = cm(bottom - crotch + 1)
            result[.outseam] = cm(length)
            return result
        }

        // Tops. The body's width low down (the hem quarter) is the torso; going up, the
        // armpit is where the outline widens sharply into the sleeves.
        let lowBand = (top + length * 3 / 4)...bottom
        let widths = lowBand.map(span).sorted()
        let torso = widths[widths.count / 2]
        // A torso is about as wide all the way down its lower part.
        guard torso > 0, Double(widths[widths.count * 3 / 4]) <= Double(max(1, widths[widths.count / 4])) * 1.3 else { return [:] }
        var armpit: Int?
        for y in stride(from: bottom, through: top, by: -1) where outer(y) > Int(Double(torso) * 1.25) + 2 {
            armpit = y
            break
        }
        guard let armpit, armpit > top + 2, armpit - top <= length * 11 / 20 else { return [:] }
        let chestRow = min(bottom, armpit + Int(2.5 / cellCm))
        // Only the torso piece of that row (the run spanning the centre).
        let centre = rows[chestRow].isEmpty ? 0 : (rows[chestRow].first!.lowerBound + rows[chestRow].last!.upperBound) / 2
        let chestRun = rows[chestRow].first { $0.contains(centre) } ?? rows[chestRow].max { $0.count < $1.count }
        guard let chestRun else { return [:] }
        result[.chest] = 2 * cm(chestRun.count)
        if chestRow < bottom - 4 {
            let waist = ((chestRow + 2)...(bottom - 2)).min { span($0) < span($1) } ?? chestRow
            if waist < bottom - 2 { result[.waist] = 2 * cm(span(waist)) }
        }
        result[.bodyLength] = cm(bottomOfCentre(mask, column: centre, rows: rows) - top + 1)
        return result
    }

    /// The lowest garment row in the centre column (a curved hem's middle).
    private static func bottomOfCentre(_ mask: Mask, column: Int, rows: [[ClosedRange<Int>]]) -> Int {
        (0..<mask.height).last { mask[column, $0] } ?? rows.lastIndex { !$0.isEmpty } ?? 0
    }

    /// Runs of garment cells along a row, ignoring gaps of a cell or two (mask noise).
    static func runs(_ mask: Mask, row y: Int) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        var start: Int?
        for x in 0...mask.width {
            if x < mask.width && mask[x, y] {
                if start == nil { start = x }
            } else if let s = start {
                if let last = result.last, s - last.upperBound <= 2 {
                    result[result.count - 1] = last.lowerBound...(x - 1)
                } else {
                    result.append(s...(x - 1))
                }
                start = nil
            }
        }
        return result
    }
}
