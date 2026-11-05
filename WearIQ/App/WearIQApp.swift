import SwiftData
import SwiftUI
import UserNotifications

@main
struct WearIQApp: App {
    @State private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        NavigationHaptics.install()
        let container = AppContainer.live()
        _container = State(initialValue: container)
        ProductTracker.registerBackgroundTask(container: container.modelContainer)
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        NotificationRouter.shared.onPurchase = { [container] token in container.pendingPurchaseToken = token }
        AppShortcuts.container = container
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .task { container.subscriptions.start() }
                .task { await ProductTracker.refreshAll(in: container.modelContainer.mainContext) }
                .onOpenURL { container.handle($0) }
                .task {
                    SavedAnalysisRepair.run(container.modelContainer.mainContext)
                    WidgetPublisher.publish(container.modelContainer.mainContext)
                    ShoppingMemory.publishShopper(container.modelContainer.mainContext)
                    ShoppingMemory.importInbox(container.modelContainer.mainContext)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            let context = container.modelContainer.mainContext
            // Back in the app: what the Safari extension saw meanwhile.
            if phase == .active { ShoppingMemory.importInbox(context) }
            // Leaving the app: back up (when on), refresh the widget, and leave the latest
            // body for the Safari extension.
            guard phase == .background else { return }
            ShoppingMemory.publishShopper(context)
            CloudBackup.backUp(container.modelContainer.mainContext)
            WidgetPublisher.publish(container.modelContainer.mainContext)
        }
        .modelContainer(container.modelContainer)
    }
}
