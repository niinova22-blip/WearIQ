import BodyMeasurementEngine
import FitEngine
import SwiftData
import SwiftUI
import WearIQCore

extension Person.Relation {
    var title: String {
        switch self {
        case .partner: String(localized: "Partner")
        case .child: String(localized: "Child")
        case .parent: String(localized: "Parent")
        case .friend: String(localized: "Friend")
        case .other: String(localized: "Someone else")
        }
    }
}

/// "For Ayşe": shown where a check or a screen is about someone else's body.
struct PersonBadge: View {
    let personID: UUID
    @Query private var people: [Person]

    var body: some View {
        if let person = people.first(where: { $0.id == personID }) {
            Label(String(localized: "For \(person.name)"), systemImage: "person.2.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Whom the app is shopping for: the user or someone they added. Everything (checks,
/// the avatar, brand sizes) follows the choice.
struct PeopleSection: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Person.createdAt) private var people: [Person]
    @State private var adding = false
    @State private var showPaywall = false
    @State private var scanning: UUID?

    var body: some View {
        Section {
            row(name: String(localized: "Me"), symbol: "person.crop.circle.fill", id: nil)
            ForEach(people) { person in
                row(name: person.name, symbol: "person.crop.circle", id: person.id, detail: person.relation.title)
                    .swipeActions {
                        Button("Delete", role: .destructive) { delete(person) }
                    }
            }
            Button {
                if container.isPremium { adding = true } else { showPaywall = true }
            } label: {
                Label("Add someone you shop for", systemImage: container.isPremium ? "person.badge.plus" : "crown.fill")
            }
        } header: {
            Text("Shopping for")
        } footer: {
            Text("A partner, a child or a gift: each person has their own measurements, checks and brand sizes.")
        }
        .sheet(isPresented: $adding) {
            AddPersonView { person in
                container.activePersonID = person.id
                scanning = person.id
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .fullScreenCover(item: $scanning) { id in
            ProfileSetupFlow(personID: id) { scanning = nil }
        }
    }

    private func row(name: String, symbol: String, id: UUID?, detail: String? = nil) -> some View {
        Button {
            container.activePersonID = id
        } label: {
            HStack {
                Label(name, systemImage: symbol)
                if let detail { Text(detail).foregroundStyle(.secondary) }
                Spacer()
                if container.activePersonID == id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .foregroundStyle(.primary)
        .accessibilityAddTraits(container.activePersonID == id ? .isSelected : [])
    }

    private func delete(_ person: Person) {
        let id = person.id
        if container.activePersonID == id { container.activePersonID = nil }
        let profiles = (try? modelContext.fetch(FetchDescriptor<StoredBodyProfile>())) ?? []
        profiles.filter { $0.personID == id }.forEach(modelContext.delete)
        modelContext.delete(person)
        try? modelContext.save()
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

struct AddPersonView: View {
    let onAdded: (Person) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var relation: Person.Relation = .partner

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Who", selection: $relation) {
                    ForEach(Person.Relation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Section {
                    Text("Next: their height, weight and gender, then a scan (they turn in front of the phone) or measurements typed in from a tape.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        let person = Person(name: name.trimmingCharacters(in: .whitespaces), relation: relation)
                        modelContext.insert(person)
                        try? modelContext.save()
                        dismiss()
                        onAdded(person)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// How WearIQ's sizes have worked out, from what the user reported.
struct FitRecordSection: View {
    @Query(sort: \PurchaseRecord.createdAt, order: .reverse) private var purchases: [PurchaseRecord]
    @State private var answering: PurchaseRecord?

    var body: some View {
        if !purchases.isEmpty {
            let summary = PurchaseFollowUp.summary(purchases)
            Section {
                if summary.followedAdvice > 0 {
                    LabeledContent("Fit first time in WearIQ's size",
                                   value: "\(summary.adviceFitFirstTime)/\(summary.followedAdvice)")
                }
                if summary.likelyReturnsAvoided > 0 {
                    LabeledContent("Returns likely avoided", value: "\(summary.likelyReturnsAvoided)")
                }
                ForEach(purchases.filter(\.isPending)) { record in
                    Button {
                        answering = record
                    } label: {
                        Label(String(localized: "How does \(record.productName ?? record.brand) fit?"), systemImage: "shippingbox")
                    }
                }
            } header: {
                Text("Your fit record")
            } footer: {
                Text("Counts only what you told WearIQ. \"Likely avoided\": WearIQ's size differed from the size you usually took in that brand, and it fit.")
            }
            .sheet(item: $answering) { PurchaseOutcomeSheet(record: $0) }
        }
    }
}

/// Opt-in: compare the weight in Apple Health with the weight the measurements were
/// taken at.
struct HealthWeightSection: View {
    @AppStorage("healthWeight") private var enabled = false

    var body: some View {
        if HealthWeight.isAvailable {
            Section {
                Toggle("Watch my weight in Apple Health", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        guard on else { return }
                        Task { if await !HealthWeight.requestAccess() { enabled = false } }
                    }
            } footer: {
                Text("When your weight has changed by 3 kg or more since your scan, WearIQ suggests scanning again. Only read, never written; it stays on this phone.")
            }
        }
    }
}

/// Opt-in iCloud backup of the numbers (never photos).
struct CloudBackupSection: View {
    @AppStorage(CloudBackup.enabledKey) private var enabled = false
    @Environment(\.modelContext) private var modelContext
    @State private var restored = false

    var body: some View {
        Section {
            Toggle("Back up to iCloud", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    // Off: the copy in iCloud goes too.
                    if on { CloudBackup.backUp(modelContext) } else { CloudBackup.erase() }
                }
            if !enabled, let date = CloudBackup.lastBackup {
                LabeledContent("Last backup", value: date.formatted(date: .abbreviated, time: .shortened))
                Button(restored ? String(localized: "Restored") : String(localized: "Restore from iCloud")) {
                    restored = CloudBackup.restore(into: modelContext)
                }
                .disabled(restored)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Your measurements, checks, brand sizes and wardrobe list are kept in your own iCloud for a new phone. Photos and scans are never uploaded.")
        }
    }
}
