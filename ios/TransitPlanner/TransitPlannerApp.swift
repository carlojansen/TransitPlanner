import SwiftUI
import TransitCore

@main
struct TransitPlannerApp: App {
    @State private var flow = AppFlow(.forLaunch())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(flow)
        }
    }
}
