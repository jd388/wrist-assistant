import SwiftUI

@main
struct WatchBrowserPhoneApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = PhoneSessionController()

    var body: some Scene {
        WindowGroup {
            PhoneContentView()
                .environmentObject(controller)
                .onAppear {
                    controller.setApplicationSceneActive(scenePhase == .active)
#if DEBUG
                    controller.startBrowserAcceptanceProbeIfRequested()
#endif
                }
                .onChange(of: scenePhase) { _, phase in
                    controller.setApplicationSceneActive(phase == .active)
                }
        }
    }
}
