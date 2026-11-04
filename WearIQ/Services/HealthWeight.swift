import Foundation
import HealthKit

/// Reads the latest body weight from Apple Health, only when the user turns it on in the
/// profile. Nothing is written to Health and nothing leaves the phone: the weight is only
/// compared with the weight the body profile was measured at (`WeightChange`).
@MainActor
enum HealthWeight {
    struct Reading: Equatable {
        var kg: Double
        var date: Date
    }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private static let store = HKHealthStore()
    private static var bodyMass: HKQuantityType { HKQuantityType(.bodyMass) }

    /// Asks for read access to body weight. False when Health isn't there or the request
    /// failed (Health doesn't say whether reading was allowed: a refusal just reads nothing).
    static func requestAccess() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: [bodyMass])
            return true
        } catch {
            return false
        }
    }

    /// The newest weight sample, if any can be read.
    static func latest() async -> Reading? {
        guard isAvailable else { return nil }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: bodyMass)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1)
        guard let sample = try? await descriptor.result(for: store).first else { return nil }
        return Reading(kg: sample.quantity.doubleValue(for: .gramUnit(with: .kilo)), date: sample.endDate)
    }
}
