import SwiftUI
import UserNotifications

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @WKApplicationDelegateAdaptor(AIRequestWatchAppDelegate.self) private var appDelegate

    init() {
        AIRequestWatchCenter.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            if newScenePhase == .background {
                Task {
                    await WatchLogger.shared.flushPersistedLogs()
                }
            }
        }
    }
}
