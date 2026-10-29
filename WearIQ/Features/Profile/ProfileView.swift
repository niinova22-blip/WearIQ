import SwiftData
import SwiftUI
import WearIQCore

struct ProfileView: View {
    @Environment(AppContainer.self) private var container
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @State private var confirmDelete = false
    @State private var deleteError: String?
    @State private var showRescan = false
    @State private var editing: BodyProfile?
    @State private var showPaywall = false
    @Query(sort: \PurchaseRecord.createdAt, order: .reverse) private var purchases: [PurchaseRecord]
    @AppStorage("soundsEnabled") private var soundsEnabled = true
    @AppStorage("outfitReminder") private var outfitReminder = false

    /// The latest purchase per brand.
    private var brandSizes: [PurchaseRecord] {
        var seen = Set<String>()
        return purchases.filter { seen.insert($0.brand.lowercased()).inserted }
    }

    var body: some View {
        List {
            Section {
                if let profile = profiles.first?.profile {
                    ForEach(MeasurementReviewModel.order, id: \.self) { d in
                        if let v = profile[d] {
                            LabeledContent(d.title, value: v.formatted)
                        }
                    }
                    Button("Edit measurements") { editing = profile }
                } else {
                    Text("No body profile yet.")
                        .foregroundStyle(.secondary)
                }
                NavigationLink("My 3D avatar") { AvatarEditorView() }
                Button("Scan again") { showRescan = true }
                NavigationLink("Measurement changes") { MeasurementTrackingView() }
            } header: {
                Text("Measurements")
            } footer: {
                if let date = profiles.first?.createdAt {
                    Text("Last updated \(date.formatted(date: .abbreviated, time: .omitted))")
                }
            }
            if !brandSizes.isEmpty {
                Section {
                    ForEach(brandSizes) { record in
                        LabeledContent(record.brand, value: "\(record.size) · \(record.feel.title)")
                    }
                } header: {
                    Text("Your sizes by brand")
                } footer: {
                    Text("From the purchases you told WearIQ about; advice for these brands is adjusted.")
                }
            }
            Section("Sounds and reminders") {
                Toggle("Interface sounds", isOn: $soundsEnabled)
                Toggle("Morning outfit reminder", isOn: $outfitReminder)
                    .onChange(of: outfitReminder) { _, on in Task { await OutfitReminder.set(on) } }
            }
            Section("Subscription") {
                if container.isPremium {
                    Label("Premium is active", systemImage: "crown.fill")
                    Link("Manage subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                } else {
                    Button("Get Premium") { showPaywall = true }
                }
                Button("Restore purchases") { Task { await container.subscriptions.restore() } }
            }
            Section("Privacy") {
                Label("Photos are processed on this device and are not uploaded.", systemImage: "lock.shield")
                Label("Your measurements are never shared with advertisers.", systemImage: "hand.raised")
            }
            Section {
                Button("Delete all my data", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("Removes your body profile, saved analyses and wardrobe from this device.")
            }
        }
        .navigationTitle("Profile")
        .navigationDestination(item: $editing) { profile in
            MeasurementReviewView(profile: profile) { editing = nil }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .fullScreenCover(isPresented: $showRescan) {
            ProfileSetupFlow { showRescan = false }
        }
        .confirmationDialog("Delete all your data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do { try container.deleteAllPersonalData() } catch { deleteError = error.localizedDescription }
            }
        } message: {
            Text("This can't be undone.")
        }
        .alert("Couldn't delete data", isPresented: .constant(deleteError != nil)) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }
}

#Preview {
    NavigationStack { ProfileView() }
        .environment(AppContainer.preview())
}
