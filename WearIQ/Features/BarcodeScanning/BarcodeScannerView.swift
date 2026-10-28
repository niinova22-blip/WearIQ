import SwiftUI
import VisionKit

/// Live EAN/UPC scanning. Returns the first retail barcode recognised.
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128, .itf14])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

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

/// Looks up a barcode in a product catalogue. No catalogue with garment measurements
/// is freely available, so the default implementation finds nothing and the UI moves
/// on to the size chart photo / manual route with the barcode attached.
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
