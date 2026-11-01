import SwiftUI
import TransitCore
import UserNotifications

/// Mitteilungen brauchen den Delegate vor dem Ende des Starts, sonst geht der Tipp beim Kaltstart verloren. Darum haelt der
/// Delegate auch den Flow: er existiert ab dem ersten Moment, `AppFlow` merkt sich einen Sprung, bis er ausfuehrbar ist.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let flow = AppFlow(.forLaunch())

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([SystemNotifier.category])
        TripRefreshHandler.run = { [flow] in await flow.refreshFromActivity() }
        return true
    }

    /// Auch im Vordergrund zeigen: wer die App offen hat, soll das Losgehen nicht verpassen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let action = response.actionIdentifier
        let id = SystemNotifier.tripID(of: response.notification)
        Task { @MainActor in
            if let id {
                switch action {
                case UNNotificationDefaultActionIdentifier, SystemNotifier.startAction: flow.openReminder(id)
                case SystemNotifier.snoozeAction: await flow.reminders.snooze(id)
                default: break
                }
            }
            completionHandler()
        }
    }
}

@main
struct TransitPlannerApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

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
                .environment(delegate.flow)
                #if DEBUG
                // Screenshot-Tour: Hell/Dunkel per Launch-Argument, nur in Debug-Builds.
                .preferredColorScheme(Self.forcedScheme)
                #endif
        }
        // SwiftUI registriert den Task und beendet ihn; laeuft die Zeit ab, wird der Lauf abgebrochen.
        .backgroundTask(.appRefresh(ReminderCenter.backgroundTaskID)) { [flow = delegate.flow] in
            await flow.reminders.checkDue()
        }
    }
}
