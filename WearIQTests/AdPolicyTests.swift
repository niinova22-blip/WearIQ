import Foundation
import Testing
@testable import WearIQ

@Suite struct AdPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Free plan: every garment check is followed by an ad before its result.
    @Test func everyCheckShowsAnAd() {
        var p = AdPolicy()
        #expect(!p.shouldShowInterstitial(now: t0, isPremium: false, canRequestAds: true))
        p.analysisCompleted()
        #expect(p.shouldShowInterstitial(now: t0, isPremium: false, canRequestAds: true))
        p.interstitialShown(at: t0)
        #expect(!p.shouldShowInterstitial(now: t0, isPremium: false, canRequestAds: true))
        p.analysisCompleted()
        #expect(p.shouldShowInterstitial(now: t0.addingTimeInterval(5), isPremium: false, canRequestAds: true))
    }

    @Test func premiumAndNoConsentNeverSeeAds() {
        var p = AdPolicy()
        p.analysisCompleted()
        #expect(!p.shouldShowInterstitial(now: t0, isPremium: true, canRequestAds: true))
        #expect(!p.shouldShowInterstitial(now: t0, isPremium: false, canRequestAds: false))
        #expect(!AdPolicy.shouldShowBanner(isPremium: true, canRequestAds: true))
        #expect(!AdPolicy.shouldShowBanner(isPremium: false, canRequestAds: false))
        #expect(AdPolicy.shouldShowBanner(isPremium: false, canRequestAds: true))
    }
}
