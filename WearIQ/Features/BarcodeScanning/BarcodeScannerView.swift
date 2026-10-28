import SwiftUI
import VisionKit

/// Live EAN/UPC scanning. Returns the first retail barcode recognised.
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    /// The device can scan at all. `isAvailable` additionally needs camera permission,
    /// so it is checked after asking (see `requestAccess`).
    static var isSupported: Bool { DataScannerViewController.isSupported }

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    /// Asks for the camera if needed; true when scanning can start.
    static func requestAccess() async -> Bool {
        if CameraController.authorizationStatus == .notDetermined {
            _ = await CameraController.requestAccess()
        }
        return isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128, .itf14])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    /// Scanning must start once the scanner is on screen; starting it while the view is
    /// being created can fail silently and leave a frozen camera.
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard !controller.isScanning else { return }
        DispatchQueue.main.async { try? controller.startScanning() }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for case let .barcode(code) in items {
                guard let value = code.payloadStringValue, value.allSatisfy(\.isNumber), (8...14).contains(value.count) else { continue }
                delivered = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCode(value)
                return
            }
        }
    }
}

/// Looks up a barcode in a product catalogue to name the product. No catalogue has
/// garment measurements, so the size chart still comes from a photo, link or by hand.
protocol BarcodeLookupServicing {
    func product(forGTIN gtin: String) async -> ProductInfoLookupResult
}

enum ProductInfoLookupResult {
    case found(name: String?, brand: String?, imageURL: URL?)
    case notFound
}

struct NoCatalogBarcodeLookup: BarcodeLookupServicing {
    func product(forGTIN gtin: String) async -> ProductInfoLookupResult { .notFound }
}

/// UPCitemdb's free lookup (no key, about 100 requests a day per IP). Only the barcode
/// number is sent. Codes starting with 2 are store-internal numbers that no public
/// catalogue knows, so they aren't sent at all.
struct UPCItemDBLookup: BarcodeLookupServicing {
    var session: URLSession = .shared

    func product(forGTIN gtin: String) async -> ProductInfoLookupResult {
        guard !Self.isStoreInternal(gtin),
              let url = URL(string: "https://api.upcitemdb.com/prod/trial/lookup?upc=\(gtin)") else { return .notFound }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = (json["items"] as? [[String: Any]])?.first,
              let title = (item["title"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return .notFound }
        let brand = (item["brand"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let image = (item["images"] as? [String])?.lazy.compactMap { URL(string: $0) }.first { $0.scheme == "https" }
        return .found(name: title, brand: brand, imageURL: image)
    }

    /// EAN-13 prefixes 20–29 are reserved for in-store use (price/weight labels, shop codes).
    static func isStoreInternal(_ gtin: String) -> Bool {
        gtin.count == 13 && gtin.hasPrefix("2")
    }
}
