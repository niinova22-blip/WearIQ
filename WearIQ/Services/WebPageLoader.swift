import UIKit
import WebKit

/// Loads a page the way Safari would, for stores that render product data with
/// JavaScript or show a browser check to plain HTTP clients. The web view is invisible,
/// keeps no cookies after it's done (non-persistent store) and is torn down after use.
@MainActor
final class WebPageLoader: NSObject, WKNavigationDelegate {
    struct Page {
        var html: String
        var url: URL
    }

    private var webView: WKWebView?
    private var host: UIView?

    /// Polls the rendered page until `isComplete` accepts it or the timeout passes, then
    /// returns the last HTML seen.
    static func load(_ url: URL, timeout: TimeInterval = 15, isComplete: @escaping (Page) -> Bool) async -> Page? {
        let loader = WebPageLoader()
        defer { loader.tearDown() }
        return await loader.run(url, timeout: timeout, isComplete: isComplete)
    }

    private func run(_ url: URL, timeout: TimeInterval, isComplete: (Page) -> Bool) async -> Page? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        // Pages throttle timers in views that aren't in a window, so attach it invisibly.
        if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            window.insertSubview(webView, at: 0)
            host = window
        }
        self.webView = webView
        webView.load(URLRequest(url: url, timeoutInterval: timeout))

        let deadline = Date().addingTimeInterval(timeout)
        var last: Page?
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            guard let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String else { continue }
            let page = Page(html: html, url: webView.url ?? url)
            last = page
            if isComplete(page) { break }
        }
        return last
    }

    private func tearDown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        host = nil
    }
}
