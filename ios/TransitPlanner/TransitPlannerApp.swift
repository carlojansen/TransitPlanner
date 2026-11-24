import MetricKit
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
        center.setNotificationCategories([SystemNotifier.category, SystemNotifier.replanCategory])
        TripRefreshHandler.run = { [flow] in await flow.refreshFromActivity() }
        // Vor der ersten Fahrt: sonst verwirft das Protokoll in TestFlight alles, bis die Einstellungen offen waren.
        Task { [flow] in await flow.detectTestFlight() }
        MXMetricManager.shared.add(self)
        return true
    }

    /// Auch im Vordergrund zeigen: wer die App offen hat, soll das Losgehen nicht verpassen. Vorschlaege nur still
    /// (`SystemNotifier.foregroundPresentation`).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        SystemNotifier.foregroundPresentation(category: notification.request.content.categoryIdentifier)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let action = response.actionIdentifier
        // Zuerst die Kategorie: ein Vorschlag geht nie an die Erinnerungen. Gueltig nur zum aktuellen Vorschlag (`showProposal`).
        let proposal = SystemNotifier.proposalID(of: response.notification)
        let id = SystemNotifier.tripID(of: response.notification)
        Task { @MainActor in
            if let proposal {
                switch action {
                case UNNotificationDefaultActionIdentifier: flow.showProposal(proposal)
                case UNNotificationDismissActionIdentifier: flow.declineReplan(proposal)
                default: break
                }
            } else if let id {
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

/// MetricKit liefert einmal am Tag Effizienzwerte und Abstuerze (auch aus vorherigen Laeufen). Nur Zahlen ins Protokoll;
/// Stacks und Geraeteangaben bleiben bei MetricKit, symbolisierte Abstuerze liefert TestFlight.
extension AppDelegate: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        let events = payloads.map { p in
            let s = { (m: Measurement<UnitDuration>?) in m.map { Int($0.converted(to: .seconds).value) } }
            let kb = { (m: Measurement<UnitInformationStorage>?) in m.map { Int($0.converted(to: .kilobytes).value) } }
            let gps = p.locationActivityMetrics
            let fg = p.applicationExitMetrics?.foregroundExitData
            let bg = p.applicationExitMetrics?.backgroundExitData
            let numbers: [String: Int?] = [
                "cpu": s(p.cpuMetrics?.cumulativeCPUTime),
                "memoryPeakKB": kb(p.memoryMetrics?.peakMemoryUsage),
                "foreground": s(p.applicationTimeMetrics?.cumulativeForegroundTime),
                "background": s(p.applicationTimeMetrics?.cumulativeBackgroundTime),
                "backgroundLocation": s(p.applicationTimeMetrics?.cumulativeBackgroundLocationTime),
                "gpsBest": s(gps.map { $0.cumulativeBestAccuracyForNavigationTime + $0.cumulativeBestAccuracyTime }),
                "cellularKB": kb(p.networkTransferMetrics.map { $0.cumulativeCellularDownload + $0.cumulativeCellularUpload }),
                "exitsForegroundAbnormal": fg.map { $0.cumulativeAbnormalExitCount + $0.cumulativeBadAccessExitCount
                    + $0.cumulativeIllegalInstructionExitCount + $0.cumulativeAppWatchdogExitCount + $0.cumulativeMemoryResourceLimitExitCount },
                "exitsBackgroundAbnormal": bg.map { $0.cumulativeAbnormalExitCount + $0.cumulativeBadAccessExitCount
                    + $0.cumulativeIllegalInstructionExitCount + $0.cumulativeAppWatchdogExitCount + $0.cumulativeMemoryResourceLimitExitCount
                    + $0.cumulativeCPUResourceLimitExitCount + $0.cumulativeBackgroundTaskAssertionTimeoutExitCount },
                "exitsBackgroundMemoryPressure": bg?.cumulativeMemoryPressureExitCount,
            ]
            return CaseEvent(kind: .metrics, time: p.timeStampEnd, numbers: numbers.compactMapValues { $0 })
        }
        // Diagnosen kommen direkt beim Start: erst die TestFlight-Erkennung abwarten, sonst verwirft das Protokoll sie.
        Task { @MainActor in await flow.detectTestFlight(); flow.recordMetrics(events) }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let events = payloads.map { p in
            var numbers = ["crashes": p.crashDiagnostics?.count ?? 0, "hangs": p.hangDiagnostics?.count ?? 0,
                           "cpuExceptions": p.cpuExceptionDiagnostics?.count ?? 0,
                           "diskWriteExceptions": p.diskWriteExceptionDiagnostics?.count ?? 0]
            numbers["signal"] = p.crashDiagnostics?.first?.signal?.intValue
            numbers["exceptionType"] = p.crashDiagnostics?.first?.exceptionType?.intValue
            return CaseEvent(kind: .diagnostics, time: p.timeStampEnd, numbers: numbers)
        }
        // Diagnosen kommen direkt beim Start: erst die TestFlight-Erkennung abwarten, sonst verwirft das Protokoll sie.
        Task { @MainActor in await flow.detectTestFlight(); flow.recordMetrics(events) }
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
