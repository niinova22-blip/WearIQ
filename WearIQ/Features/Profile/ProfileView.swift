import AvatarEngine
import SwiftData
import SwiftUI
import WearIQCore

struct ProfileView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.openURL) private var openURL

    /// The language the app is shown in, in that language ("English", "Türkçe").
    static var languageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized(with: Locale(identifier: code)) ?? code
    }
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
        return purchases.filter { !$0.isPending && $0.personID == container.activePersonID && seen.insert($0.brand.lowercased()).inserted }
    }

    var body: some View {
        List {
            PeopleSection()
            Section {
                if let profile = profiles.of(container.activePersonID).first?.profile {
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
                NavigationLink("Size passport") { SizePassportView() }
                NavigationLink("Shopping memory") { ShoppingMemoryView() }
                NavigationLink("My 3D avatar") { AvatarEditorView() }
                Button("Scan again") { showRescan = true }
                NavigationLink("Measurement changes") { MeasurementTrackingView() }
                // Testers' tools: never in a store build.
                if TesterBuild.isActive {
                    NavigationLink("Measurement validation") { ValidationView() }
                    NavigationLink { TesterPanelView() } label: { Label("Test panel", systemImage: "testtube.2") }
                }
            } header: {
                Text("Measurements")
            } footer: {
                if let date = profiles.of(container.activePersonID).first?.createdAt {
                    Text("Last updated \(date.formatted(date: .abbreviated, time: .omitted))")
                }
            }
            FitRecordSection()
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
            HealthWeightSection()
            CloudBackupSection()
            Section("Sounds and reminders") {
                Toggle("Interface sounds", isOn: $soundsEnabled)
                Toggle("Morning outfit reminder", isOn: $outfitReminder)
                    .onChange(of: outfitReminder) { _, on in Task { await OutfitReminder.set(on) } }
            }
            SizeRegionSection()
            Section {
                // iOS keeps a language per app (English or Turkish) in the app's own
                // settings page; the voice guidance follows it too.
                LabeledContent("Language", value: Self.languageName)
                Button("Change language") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("WearIQ is in English and Turkish. The language is chosen in the app's settings.")
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
                Link("Privacy policy", destination: URL(string: "https://niinova22-blip.github.io/WearIQ/privacy.html")!)
                Label("Your measurements are never shared with advertisers.", systemImage: "hand.raised")
                if container.ads.privacyOptionsRequired && !container.isPremium {
                    Button {
                        Task { await container.ads.presentPrivacyOptions() }
                    } label: {
                        Label("Ad privacy choices", systemImage: "slider.horizontal.3")
                    }
                }
            }
            Section {
                NavigationLink("Acknowledgements") { AcknowledgementsView() }
            }
            Section {
                Button("Delete all my data", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("Removes your body profile, saved analyses and wardrobe from this device.")
            }
        }
        .navigationTitle("Profile")
        #if DEBUG
        .navigationDestination(isPresented: .constant(DemoMode.opensPassport)) { SizePassportView() }
        // Its rows link on, which a constantly presented destination doesn't survive.
        .fullScreenCover(isPresented: .constant(DemoMode.opensMemory)) { NavigationStack { ShoppingMemoryView() } }
        .fullScreenCover(isPresented: .constant(DemoMode.opensBody)) { NavigationStack { AvatarEditorView() } }
        #endif
        .navigationDestination(item: $editing) { profile in
            MeasurementReviewView(profile: profile) { editing = nil }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .fullScreenCover(isPresented: $showRescan) {
            ProfileSetupFlow(personID: container.activePersonID) { showRescan = false }
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

/// Open-source work and public data the app is built on, with the licences that ask to
/// travel with it.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                Text("The 3D body is shaped with NVIDIA's SOMA-X body model, learned from thousands of body scans. Copyright NVIDIA Corporation, Apache License 2.0.")
                if let text = AvatarNotices.somaLicense {
                    NavigationLink("Apache License 2.0") {
                        ScrollView { Text(text).font(.caption.monospaced()).padding() }
                            .navigationTitle("Apache License 2.0")
                    }
                }
            } header: {
                Text("SOMA-X")
            }
            Section {
                Text("Measurement estimates use the public ANSUR II anthropometric survey (US Army) and NHANES (US CDC).")
            } header: {
                Text("Body measurement data")
            }
            Section {
                Text("The scan's voice was recorded with the open Chatterbox speech model (Resemble AI, MIT License).")
            } header: {
                Text("Voice")
            }
        }
        .navigationTitle("Acknowledgements")
    }
}
