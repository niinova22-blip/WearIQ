import Foundation

/// When ads may appear. Kept free of SDK types so the rules are unit-testable.
///
/// - Never before a scan, never for premium users.
/// - Interstitial only after leaving a result screen, at most every
///   `analysesPerInterstitial` analyses and never within `minimumInterval`.
/// - Banners only on browsing screens (home, history), never on camera/scan screens.
struct AdPolicy {
    var analysesPerInterstitial = 2
    var minimumInterval: TimeInterval = 180

    private(set) var analysesSinceInterstitial = 0
    private(set) var lastInterstitial: Date?

    mutating func analysisCompleted() {
        analysesSinceInterstitial += 1
    }

    func shouldShowInterstitial(now: Date, isPremium: Bool, canRequestAds: Bool) -> Bool {
        guard !isPremium, canRequestAds, analysesSinceInterstitial >= analysesPerInterstitial else { return false }
        if let last = lastInterstitial, now.timeIntervalSince(last) < minimumInterval { return false }
        return true
    }

    mutating func interstitialShown(at date: Date) {
        lastInterstitial = date
        analysesSinceInterstitial = 0
    }

    static func shouldShowBanner(isPremium: Bool, canRequestAds: Bool) -> Bool {
        !isPremium && canRequestAds
    }
}
