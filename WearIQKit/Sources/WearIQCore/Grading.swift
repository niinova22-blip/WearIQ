/// How a pattern grows from one size to the next. A size up is bigger everywhere, not
/// only where the chart measures it: if the chart gives the chest, the waist, sleeves,
/// length and shoulders grow with it; if it gives the waist and seat of trousers, the
/// thighs and knees grow too. Unless a garment is cut otherwise (that is its cut, see
/// `FitStyle` and `LegCut`), "roomy at the top, fitted in the middle" is never a size.
///
/// Ratios are cm of the dimension per cm of the size's primary girth, from common
/// grading rules (ISO 8559-style 4 cm chest/waist steps; high-street letter sizes step
/// 6–8 cm with body length +2–3 cm and sleeves +1.2–1.6 cm). Both the size-chart check
/// and the avatar use these, so the two never grade a size differently.
public enum Grading {
    /// Top body length per cm of chest.
    public static let lengthPerChest = 0.3
    /// Sleeve length (shoulder point to cuff) per cm of chest.
    public static let sleevePerChest = 0.2
    /// Across-the-back shoulder width per cm of chest.
    public static let shoulderPerChest = 0.27
    /// Top waist and hip per cm of chest.
    public static let waistPerChest = 1.0
    /// Trouser seat per cm of waist.
    public static let hipPerWaist = 1.0
    /// Trouser thigh per cm of seat.
    public static let thighPerHip = 0.6
}
