import GoogleMobileAds
import SwiftUI

/// Adaptive banner for free users on browsing screens. Renders nothing for premium
/// users or before consent allows ads.
struct BannerAdSlot: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        if container.ads.showsBanner(isPremium: container.isPremium) {
            GeometryReader { proxy in
                BannerAdView(width: proxy.size.width)
            }
            .frame(height: 60)
            .accessibilityLabel(Text("Advertisement"))
        }
    }
}

private struct BannerAdView: UIViewRepresentable {
    let width: CGFloat

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: currentOrientationAnchoredAdaptiveBanner(width: max(width, 320)))
        banner.adUnitID = AdUnits.banner
        banner.rootViewController = AdvertisingService.topViewController()
        banner.load(Request())
        return banner
    }

    func updateUIView(_ banner: BannerView, context: Context) {}
}
