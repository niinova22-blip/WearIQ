import Foundation

extension Avatar {
    /// Where an edge of the garment ends on this body, against the nearest place a
    /// shopper would judge it by: a top's or coat's hem against the hips, thighs and
    /// knees, a skirt's against the knee, trouser legs against the ankle, sleeves against
    /// the wrist (tailors' rules: a sleeve ends at the wrist bone, trousers just reach
    /// the shoe, a jacket covers the seat, a coat the jacket).
    public struct Placement: Sendable, Equatable {
        public enum Edge: String, Sendable {
            case hem, sleeve, legs
        }

        public enum Landmark: String, Sendable, CaseIterable {
            case waist, hips, crotch, midThigh, knee, midCalf, ankle, floor
            case midUpperArm, elbow, wrist
        }

        public var edge: Edge
        public var landmark: Landmark
        /// Centimetres past it: + below (or further down the arm), − above, 0 at it.
        public var offsetCm: Double
        /// Whether the length is the chart's or estimated (no length on the chart: the
        /// garment's usual length for its kind and size).
        public var estimated: Bool
        /// Within the usual range for this kind of garment.
        public var usual: Bool
    }
}

extension BodyModel {
    /// Heights of the places a hem is judged against, top to bottom.
    var hemLandmarks: [(Avatar.Placement.Landmark, Float)] {
        [(.waist, waistY), (.hips, hipY), (.crotch, crotchY), (.midThigh, (crotchY + kneeY) / 2),
         (.knee, kneeY), (.midCalf, (kneeY + ankleY) / 2), (.ankle, ankleY)]
    }

    /// The landmark nearest to a height, with how far below it the height is (cm).
    func nearestLandmark(to y: Float) -> (Avatar.Placement.Landmark, Double) {
        let best = hemLandmarks.min { abs($0.1 - y) < abs($1.1 - y) } ?? (.hips, hipY)
        return (best.0, Double((best.1 - y) * 100))
    }

    /// Where the garment's edges end. `lengthKnown` / `sleeveKnown`: the chart gave them.
    func placements(_ shape: GarmentShape, lengthKnown: Bool, sleeveKnown: Bool) -> [Avatar.Placement] {
        let fit = shape.fit
        var out: [Avatar.Placement] = []
        let length = fit.shownLength
        let usualLength = abs(length.delta) < length.threshold
        switch fit.kind {
        case .trousers:
            // The leg's end against the ankle bone: longer reaches the shoe and then the floor.
            let extra = fit.lengthDelta + fit.hemOffset
            let floorAt = Double((ankleY - 0.012 * h) * 100)
            if extra < -12 {
                // Shorts or cropped legs: against the thigh, knee or calf.
                let (landmark, offset) = nearestLandmark(to: shape.hemY)
                out.append(.init(edge: .legs, landmark: landmark, offsetCm: offset, estimated: !lengthKnown, usual: usualLength))
            } else if extra >= floorAt {
                out.append(.init(edge: .legs, landmark: .floor, offsetCm: extra - floorAt, estimated: !lengthKnown, usual: false))
            } else {
                out.append(.init(edge: .legs, landmark: .ankle, offsetCm: extra, estimated: !lengthKnown, usual: usualLength))
            }
        case .skirt, .top:
            let (landmark, offset) = nearestLandmark(to: shape.hemY)
            out.append(.init(edge: .hem, landmark: landmark, offsetCm: offset, estimated: !lengthKnown, usual: usualLength))
        }
        if case .top = fit.kind {
            let reach = Double(shape.sleeveReach * 100), arm = Double(armLength * 100)
            if shape.longSleeves {
                let sleeve = fit.shownSleeve
                out.append(.init(edge: .sleeve, landmark: .wrist, offsetCm: reach - arm, estimated: !sleeveKnown,
                                 usual: abs(sleeve.delta) < sleeve.threshold))
            } else {
                // Short sleeves: half-way down the upper arm, or at the elbow.
                let elbow = 0.45 * arm
                let (mark, at) = abs(reach - elbow) < abs(reach - elbow / 2)
                    ? (Avatar.Placement.Landmark.elbow, elbow) : (.midUpperArm, elbow / 2)
                out.append(.init(edge: .sleeve, landmark: mark, offsetCm: reach - at, estimated: true, usual: true))
            }
        }
        return out
    }
}
