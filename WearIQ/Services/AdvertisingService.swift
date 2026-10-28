import AppTrackingTransparency
import Foundation
import GoogleMobileAds
import Observation
import UIKit
import UserMessagingPlatform

/// AdMob ad unit IDs. Debug builds always use Google's public test units so real ads
/// are never clicked during development. Release IDs come from Info.plist.
enum AdUnits {
    static var banner: String {
        #if DEBUG
        "ca-app-pub-3940256099942544/2435281174"
        #else
        Bundle.main.object(forInfoDictionaryKey: "WQBannerAdUnitID") as? String ?? ""
        #endif
    }

    static var interstitial: String {
        #if DEBUG
        "ca-app-pub-3940256099942544/4411468910"
        #else
        Bundle.main.object(forInfoDictionaryKey: "WQInterstitialAdUnitID") as? String ?? ""
        #endif
    }
}

/// Consent (UMP) → App Tracking Transparency → Mobile Ads SDK start, then serves ads
/// according to `AdPolicy`. No custom targeting is ever attached to ad requests, so
/// body measurements and analyses cannot reach the ad network.
@MainActor
@Observable
final class AdvertisingService {
    private(set) var canRequestAds = false
    private var policy = AdPolicy()
    private var interstitial: InterstitialAd?
    private var started = false

    /// Call once the user has finished onboarding (not on first launch, so the
    /// permission prompts don't stack on top of the introduction).
    func prepare(isPremium: Bool) async {
        guard !started, !isPremium else { return }
        started = true

        await requestConsentIfNeeded()
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            _ = await ATTrackingManager.requestTrackingAuthorization()
        }
        canRequestAds = ConsentInformation.shared.canRequestAds
        guard canRequestAds else { return }
        await MobileAds.shared.start()
        await loadInterstitial()
    }

    func analysisCompleted() {
        policy.analysisCompleted()
    }

    /// Called when the user leaves a result screen.
    func showInterstitialIfDue(isPremium: Bool) {
        guard policy.shouldShowInterstitial(now: Date(), isPremium: isPremium, canRequestAds: canRequestAds),
              let ad = interstitial, let root = Self.topViewController() else { return }
        ad.present(from: root)
        policy.interstitialShown(at: Date())
        interstitial = nil
        Task { await loadInterstitial() }
    }

    func showsBanner(isPremium: Bool) -> Bool {
        AdPolicy.shouldShowBanner(isPremium: isPremium, canRequestAds: canRequestAds)
    }

    private func loadInterstitial() async {
        interstitial = try? await InterstitialAd.load(with: AdUnits.interstitial, request: Request())
    }

    private func requestConsentIfNeeded() async {
        do {
            try await ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters())
            if let root = Self.topViewController() {
                try await ConsentForm.loadAndPresentIfRequired(from: root)
            }
        } catch {
            // Without consent information we fall back to whatever UMP allows (canRequestAds).
        }
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
