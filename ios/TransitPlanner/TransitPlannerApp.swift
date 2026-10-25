import SwiftUI
import TransitCore

@main
struct TransitPlannerApp: App {
    @State private var flow = AppFlow(.forLaunch())

    #if DEBUG
    private static var forcedScheme: ColorScheme? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uiTestDark") { return .dark }
        if args.contains("-uiTestLight") { return .light }
        return nil
    }
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(flow)
                #if DEBUG
                // Screenshot-Tour: Hell/Dunkel per Launch-Argument, nur in Debug-Builds.
                .preferredColorScheme(Self.forcedScheme)
                #endif
        }
    }
}
