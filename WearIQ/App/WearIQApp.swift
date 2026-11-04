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
                .task { WidgetPublisher.publish(container.modelContainer.mainContext) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app: back up (when on) and refresh the widget.
            guard phase == .background else { return }
            CloudBackup.backUp(container.modelContainer.mainContext)
            WidgetPublisher.publish(container.modelContainer.mainContext)
        }
        .modelContainer(container.modelContainer)
    }
}
