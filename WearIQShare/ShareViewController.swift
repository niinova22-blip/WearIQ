import UIKit
import UniformTypeIdentifiers

/// "Share → WearIQ" from a store's app or Safari: takes the shared link and opens WearIQ
/// on it (weariq://check?url=…), where the product is read and checked like a pasted link.
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.text = String(localized: "Opening WearIQ…")
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
        ])
        Task { await handle() }
    }

    private func handle() async {
        guard let link = await sharedLink(),
              var components = URLComponents(string: "weariq://check") else { return finish() }
        components.queryItems = [URLQueryItem(name: "url", value: link.absoluteString)]
        guard let url = components.url, openContainingApp(url) else {
            // Couldn't hand over: leave the link on the clipboard for pasting in WearIQ.
            UIPasteboard.general.url = link
            label.text = String(localized: "The link is copied. Open WearIQ and paste it.")
            try? await Task.sleep(for: .seconds(2))
            return finish()
        }
        finish()
    }

    /// The first web link among the shared items: a URL, or text that contains one.
    private func sharedLink() async -> URL? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
               url.scheme?.hasPrefix("http") == true { return url }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let match = text.range(of: #"https?://[^\s]+"#, options: .regularExpression) {
                return URL(string: String(text[match]))
            }
        }
        return nil
    }

    /// Share extensions can't open apps directly; the app object is reached through the
    /// responder chain.
    private func openContainingApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
