import SwiftUI

@main
struct CompanionApp: App {
    @State private var model = CompanionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CompanionView(model: model)
                .preferredColorScheme(.dark)
                .task { model.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Keep the screen on while the compass is visible.
                    UIApplication.shared.isIdleTimerDisabled = phase == .active
                }
        }
    }
}
