import SwiftData
import SwiftUI

@main
struct WearIQApp: App {
    @State private var container: AppContainer

    init() {
        NavigationHaptics.install()
        let container = AppContainer.live()
        _container = State(initialValue: container)
        ProductTracker.registerBackgroundTask(container: container.modelContainer)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .task { container.subscriptions.start() }
                .task { await ProductTracker.refreshAll(in: container.modelContainer.mainContext) }
                .onOpenURL { container.handle($0) }
        }
        .modelContainer(container.modelContainer)
    }
}
