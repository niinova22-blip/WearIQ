import Foundation

/// What happened to one purchase the shopper told WearIQ about.
public struct PurchaseOutcome: Sendable, Equatable {
    public enum Fit: String, Sendable {
        case tight, right, loose
    }

    /// The size WearIQ recommended for this garment, when it was checked first.
    public var recommended: String?
    /// The size bought.
    public var taken: String
    /// The size the shopper took before for this brand and kind of garment, if any.
    public var usual: String?
    /// How it fit; nil until they say.
    public var fit: Fit?
    /// They sent it back.
    public var returned: Bool

    public init(recommended: String?, taken: String, usual: String? = nil, fit: Fit?, returned: Bool = false) {
        self.recommended = recommended
        self.taken = taken
        self.usual = usual
        self.fit = fit
        self.returned = returned
    }
}

/// The running tally on the profile: how often WearIQ's size fit first time, and how
/// many returns it likely saved. Only counts what the shopper reported; a purchase with
/// no answer yet counts for nothing.
public struct FitOutcomeSummary: Sendable, Equatable {
    /// Purchases with an answer.
    public var rated: Int
    /// Rated purchases in the size WearIQ recommended.
    public var followedAdvice: Int
    /// Of those, the ones that fit and stayed.
    public var adviceFitFirstTime: Int
    /// Fitted, kept purchases in WearIQ's size where the shopper's usual size for that
    /// brand was a different one: the order that would otherwise likely have gone back.
    public var likelyReturnsAvoided: Int
    /// Purchases still waiting for an answer.
    public var pending: Int

    /// Share of followed advice that fit first time, nil below three answers (too few
    /// to say anything).
    public var adviceHitRate: Double? {
        followedAdvice >= 3 ? Double(adviceFitFirstTime) / Double(followedAdvice) : nil
    }

    public init(_ outcomes: [PurchaseOutcome]) {
        let rated = outcomes.filter { $0.fit != nil || $0.returned }
        self.rated = rated.count
        pending = outcomes.count - rated.count
        let followed = rated.filter { $0.recommended != nil && Self.same($0.recommended, $0.taken) }
        followedAdvice = followed.count
        let fitted = followed.filter { $0.fit == .right && !$0.returned }
        adviceFitFirstTime = fitted.count
        likelyReturnsAvoided = fitted.filter { o in o.usual.map { !Self.same($0, o.taken) } ?? false }.count
    }

    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.trimmingCharacters(in: .whitespaces).uppercased() == b.trimmingCharacters(in: .whitespaces).uppercased()
    }
}
