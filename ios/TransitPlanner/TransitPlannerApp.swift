import SwiftUI
import TransitCore

/// Einstiegspunkt. Die Oberflaeche folgt in Meilenstein 3; bis dahin nur ein leerer Systemhintergrund.
@main
struct TransitPlannerApp: App {
    var body: some Scene {
        WindowGroup {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
        }
    }
}
