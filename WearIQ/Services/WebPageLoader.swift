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
        /// Seconds since loading started.
        var elapsed: TimeInterval
        /// Size guide controls found on the page so far.
        var sizeGuideControls: Int
        /// Visible text, for size guides drawn with layout boxes instead of a table.
        var text: String = ""
        /// Image of the opened size guide, for guides that are only readable visually.
        var snapshot: UIImage?
        /// Texts of clickable elements that mention sizes, for diagnostics.
        var sizeRelatedControls: [String] = []
    }

    private var webView: WKWebView?
    private var host: UIView?

    /// Many stores only add the size chart to the page when its button is pressed
    /// ("Ürün boyutları", "Beden tablosu", "Size guide"). This presses such buttons once.
    /// Only buttons and in-page links: nothing that navigates away or adds to the basket.
    /// Returns how many such controls the page has.
    static let openSizeGuides = #"""
    (() => {
      const re = /(beden tablosu|beden rehberi|ürün boyutları|ürün ölçüleri|ölçü tablosu|size guide|size chart|product measurements|measurements)/i;
      for (const el of document.querySelectorAll('button, [role="button"], summary, a')) {
        if (el.dataset.wqOpened) continue;
        const text = (el.innerText || el.getAttribute('aria-label') || '').trim();
        if (!text || text.length > 40 || !re.test(text)) continue;
        const href = el.getAttribute('href');
        if (el.tagName === 'A' && href && !href.startsWith('#') && !href.startsWith('javascript')) continue;
        el.dataset.wqOpened = '1';
        try { el.click(); } catch (e) {}
      }
      return document.querySelectorAll('[data-wq-opened]').length;
    })()
    """#

    /// Polls the rendered page until `isComplete` accepts it or the timeout passes, then
    /// returns the last HTML seen. Size guide buttons are pressed as they appear.
    static func load(_ url: URL, timeout: TimeInterval = 15, isComplete: @escaping (Page) -> Bool) async -> Page? {
        let loader = WebPageLoader()
        defer { loader.tearDown() }
        return await loader.run(url, timeout: timeout, isComplete: isComplete)
    }

    private func run(_ url: URL, timeout: TimeInterval, isComplete: (Page) -> Bool) async -> Page? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        // Tall viewport so an opened size guide is likely to be fully rendered for the snapshot.
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 2000), configuration: config)
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

        let start = Date()
        var last: Page?
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            let controls = (try? await webView.evaluateJavaScript(Self.openSizeGuides) as? Int) ?? 0
            guard let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String else { continue }
            let page = Page(html: html, url: webView.url ?? url, elapsed: Date().timeIntervalSince(start),
                            sizeGuideControls: controls)
            last = page
            if isComplete(page) { break }
        }
        guard var page = last else { return nil }
        page.text = (try? await webView.evaluateJavaScript("document.body.innerText") as? String) ?? ""
        page.sizeRelatedControls = (try? await webView.evaluateJavaScript(Self.listSizeControls) as? [String]) ?? []
        if page.sizeGuideControls > 0 {
            // Bring the opened guide into view, then photograph it.
            _ = try? await webView.evaluateJavaScript(Self.scrollToSizeGuide)
            try? await Task.sleep(for: .milliseconds(600))
            page.snapshot = try? await webView.takeSnapshot(configuration: nil)
        }
        return page
    }

    static let listSizeControls = #"""
    [...document.querySelectorAll('button, [role="button"], summary, a, [data-qa-action], [class*="size-guide"], [class*="sizeGuide"]')]
      .map(e => ((e.innerText || e.getAttribute('aria-label') || '') + ' <' + e.tagName + ' ' + (e.getAttribute('data-qa-action') || e.className || '').toString().slice(0, 60) + '>').replace(/\s+/g, ' ').trim())
      .filter(t => /boyut|beden|ölç|olcu|size|guide|measure/i.test(t)).slice(0, 25)
    """#

    /// Scrolls to the largest visible block that looks like a size table (many numbers).
    static let scrollToSizeGuide = #"""
    (() => {
      let best = null, bestScore = 0;
      for (const el of document.querySelectorAll('table, [class*="size"], [class*="guide"], [role="dialog"], dialog')) {
        const r = el.getBoundingClientRect();
        if (r.width < 100 || r.height < 60) continue;
        const nums = ((el.innerText || '').match(/\b\d{2,3}([.,]\d)?\b/g) || []).length;
        if (nums > bestScore) { best = el; bestScore = nums; }
      }
      if (best) best.scrollIntoView({block: 'start'});
      return bestScore;
    })()
    """#

    private func tearDown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        host = nil
    }
}
