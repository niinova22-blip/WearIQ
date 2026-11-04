import Foundation
import SwiftData
import WearIQCore

/// A saved body profile. Measurements are stored as JSON so the domain model in
/// WearIQKit stays free of persistence concerns.
@Model
final class StoredBodyProfile {
    var createdAt: Date
    var profileData: Data
    /// Whose body this is: nil for the app's own user, otherwise a `Person`.
    var personID: UUID?

    init(profile: BodyProfile, personID: UUID? = nil) throws {
        createdAt = profile.createdAt
        profileData = try JSONEncoder().encode(profile)
        self.personID = personID
    }

    var profile: BodyProfile? {
        try? JSONDecoder().decode(BodyProfile.self, from: profileData)
    }
}

extension Array where Element == StoredBodyProfile {
    /// The profiles of one person (nil: the app's own user), newest first as queried.
    func of(_ person: UUID?) -> [StoredBodyProfile] { filter { $0.personID == person } }
}

enum PersistenceController {
    static func makeContainer(inMemory: Bool) -> ModelContainer {
        let schema = Schema([StoredBodyProfile.self, SavedAnalysis.self, WardrobeEntry.self,
                             PurchaseRecord.self, TrackedProduct.self, Person.self])
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            config = ModelConfiguration(schema: schema, url: protectedStoreURL())
        }
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not open the WearIQ data store: \(error)")
        }
    }

    /// Body measurements are sensitive: keep the store in a file-protected directory
    /// (encrypted at rest and unreadable until the device is first unlocked).
    private static func protectedStoreURL() -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "WearIQ", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return dir.appending(path: "WearIQ.store")
    }
}
