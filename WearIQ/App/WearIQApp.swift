import SwiftData
import SwiftUI

@main
struct WearIQApp: App {
    @State private var container = AppContainer.live()

    init() {
        NavigationHaptics.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .task { container.subscriptions.start() }
        }
        .modelContainer(container.modelContainer)
    }
}
