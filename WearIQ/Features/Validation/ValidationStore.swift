import ARKit
import BodyMeasurementEngine
import Foundation
import Observation

/// The measurement-validation records: every scan made while validation mode is on,
/// measured by both engines, waiting for (or holding) tape values. A JSON file next to
/// the app's store, under the same file protection. Nothing leaves the device unless
/// the user exports it.
@MainActor
@Observable
final class ValidationStore {
    static let shared = ValidationStore()

    /// Validation mode: scans are also measured by the experimental engine and kept here.
    /// Production measurements never change because of it.
    /// Only in test builds: a store build never records a second engine's reading.
    static var isEnabled: Bool {
        get { TesterBuild.isActive && UserDefaults.standard.bool(forKey: "validationMode") }
        set { UserDefaults.standard.set(newValue, forKey: "validationMode") }
    }

    private(set) var records: [ValidationRecord] = []

    private init() { load() }

    func upsert(_ record: ValidationRecord) {
        if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = record } else { records.insert(record, at: 0) }
        save()
    }

    func delete(_ ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        save()
    }

    /// "Delete all my data": every validation record, tape values included.
    static func eraseAll() {
        shared.records = []
        try? FileManager.default.removeItem(at: url)
    }

    /// The next free participant code, "P01", "P02"…
    var nextParticipant: String {
        let used = Set(records.map(\.participant))
        var n = 1
        while used.contains(String(format: "P%02d", n)) { n += 1 }
        return String(format: "P%02d", n)
    }

    // MARK: File

    private static var url: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "WearIQ", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return dir.appending(path: "validation.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        records = (try? JSONDecoder.validation.decode([ValidationRecord].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder.validation.encode(records) else { return }
        try? data.write(to: Self.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// A file with every record, for sharing: JSON (everything, stop profiles included)
    /// or CSV (one row per measurement).
    func export(csv: Bool) -> URL? {
        let name = "weariq-validation-\(Date().formatted(.iso8601.year().month().day()))." + (csv ? "csv" : "json")
        let url = URL.temporaryDirectory.appending(path: name)
        let data = csv ? Data(ValidationRecord.csv(records).utf8) : (try? JSONEncoder.validation.encode(records))
        guard let data, (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }
}

extension JSONEncoder {
    static var validation: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var validation: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// The device the scan ran on.
enum DeviceInfo {
    /// The model identifier, e.g. "iPhone12,1" (an iPhone 11).
    static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Whether ARKit can read LiDAR depth here.
    static var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// The app's memory footprint, MB, as the system counts it.
    static var memoryFootprintMB: Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }
}
