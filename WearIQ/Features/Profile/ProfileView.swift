import SwiftUI

struct ProfileView: View {
    @Environment(AppContainer.self) private var container
    @State private var confirmDelete = false
    @State private var deleteError: String?

    var body: some View {
        List {
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
