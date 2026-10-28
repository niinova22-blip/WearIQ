import SwiftUI
import UIKit

/// Virtual try-on renders a garment onto a photo of the user.
///
/// Status: NOT AVAILABLE. Realistic try-on needs an image-generation model (diffusion
/// based, several GB) that can't run acceptably on-device today, so it would require
/// uploading body photos to a server. That conflicts with the app's on-device privacy
/// promise and needs explicit opt-in consent, a data processing agreement, a server
/// budget and an accuracy evaluation before it can ship. Until then the only
/// implementation is `UnavailableTryOnService`, and the UI says so plainly.
protocol VirtualTryOnServicing {
    var availability: TryOnAvailability { get }
    func render(person: UIImage, garmentImageURL: URL) async throws -> UIImage
}

enum TryOnAvailability: Equatable {
    case available
    case unavailable(reason: String)
}

enum TryOnError: Error {
    case notAvailable
}

struct UnavailableTryOnService: VirtualTryOnServicing {
    var availability: TryOnAvailability {
        .unavailable(reason: String(localized: "Virtual try-on is in development. It will only ever process your photo with your explicit permission."))
    }

    func render(person: UIImage, garmentImageURL: URL) async throws -> UIImage {
        throw TryOnError.notAvailable
    }
}

struct VirtualTryOnView: View {
    var service: VirtualTryOnServicing = UnavailableTryOnService()

    var body: some View {
        switch service.availability {
        case .available:
            // Intentionally unreachable until a real backend exists.
            EmptyView()
        case let .unavailable(reason):
            ContentUnavailableView {
                Label("Virtual try-on", systemImage: "person.crop.rectangle")
            } description: {
                Text(reason)
            }
        }
    }
}
