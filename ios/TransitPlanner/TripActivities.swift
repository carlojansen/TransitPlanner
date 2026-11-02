import ActivityKit
import Foundation
import Synchronization
import TransitCore
import UIKit

/// ActivityKit hinter einem Protokoll: Entscheidungen fallen in `TripActivityPlanner`, hier wird nur ausgefuehrt.
protocol TripActivityControlling: Sendable {
    /// Nur im Vordergrund und wenn der Nutzer Live Activities erlaubt; sonst bleibt alles still, ohne Fehlerbanner.
    @MainActor var canStart: Bool { get }
    @MainActor func running() -> [TripActivityRunning]
    /// Weggewischt oder vom System beendet (8 h), ohne dass die App es wollte: fuer diese Fahrt kein neuer Start.
    @MainActor func rejected() -> Set<String>
    /// Bewusster Start der Fahrt hebt die Ablehnung auf; Wegwischen danach gilt wieder.
    @MainActor func forgive(_ key: String)
    /// Fuehrt alles aus; ein gescheiterter Start wird am Ende gemeldet.
    @MainActor func apply(_ actions: [TripActivityAction]) throws(TransitError)
}

struct NoTripActivities: TripActivityControlling {
    @MainActor var canStart: Bool { false }
    @MainActor func running() -> [TripActivityRunning] { [] }
    @MainActor func rejected() -> Set<String> { [] }
    @MainActor func forgive(_ key: String) {}
    @MainActor func apply(_ actions: [TripActivityAction]) throws(TransitError) {}
}

final class SystemTripActivities: TripActivityControlling {
    private typealias TripActivity = Activity<TripActivityAttributes>

    /// Von der App beendet: zaehlt nie wieder als laufend, sonst saehe der naechste Abgleich zwei je Fahrt, und hinkt
    /// `activityState` nach dem `end` nach, gaelte sie als abgelehnt. Bleibt darum bis zum Prozessende.
    private let ending = Mutex<Set<String>>([])
    private let backgroundTasks = Mutex<[String: UIBackgroundTaskIdentifier]>([:])
    /// In UserDefaults, nur lokale IDs: eine geplante Activity wird oft weggewischt, waehrend die App gar nicht laeuft.
    private static let seenKey = "liveActivitySeen"
    private static let rejectedKey = "liveActivityRejected"

    private var activities: [TripActivity] {
        let ending = ending.withLock { $0 }
        return TripActivity.activities.filter { [.active, .pending, .stale].contains($0.activityState) && !ending.contains($0.id) }
    }

    @MainActor var canStart: Bool {
        UIApplication.shared.applicationState == .active && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    @MainActor func running() -> [TripActivityRunning] {
        let live = activities
        noteGone(Dictionary(live.map { ($0.attributes.key, $0.attributes.startAt ?? .distantPast) }) { first, _ in first })
        return live.map {
            TripActivityRunning(key: $0.attributes.key, state: $0.content.state, startAt: $0.attributes.startAt,
                                isPending: $0.activityState == .pending)
        }
    }

    @MainActor func rejected() -> Set<String> { Set(Self.stored(Self.rejectedKey)) }

    @MainActor func forgive(_ key: String) {
        Self.seen[key] = nil
        UserDefaults.standard.set(Self.stored(Self.rejectedKey).filter { $0 != key }, forKey: Self.rejectedKey)
    }

    private static func stored(_ name: String) -> [String] { UserDefaults.standard.stringArray(forKey: name) ?? [] }

    /// Key und geplanter Start, sofort gestartet `.distantPast` (`TripActivityPlanner.dismissed`).
    private static var seen: [String: Date] {
        get { UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Date] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    private func noteGone(_ live: [String: Date]) {
        let seen = Self.seen
        guard live != seen else { return }
        let gone = TripActivityPlanner.dismissed(seen: seen, live: Set(live.keys), now: .now)
        // ponytail: feste Obergrenze statt Aufraeumen je Fahrt; mehr als zwei Activities laufen nie gleichzeitig.
        UserDefaults.standard.set(Array((Self.stored(Self.rejectedKey) + gone).suffix(20)), forKey: Self.rejectedKey)
        Self.seen = live
    }

    @MainActor func apply(_ actions: [TripActivityAction]) throws(TransitError) {
        var failure: TransitError?
        for action in actions {
            switch action {
            case .end(let key): end(key, final: nil)
            case .finish(let wish): end(wish.key, final: wish)
            case .update(let wish, let alert):
                for id in activities.filter({ $0.attributes.key == wish.key }).map(\.id) { Task { await Self.update(id, wish, alert: alert) } }
            case .start(let wish):
                // Abgeschaltet oder Limit erreicht; Rueckfall sind die Mitteilungen.
                do {
                    _ = try request(wish)
                    // Sofort: bis zum naechsten Abgleich kann die App schon beendet sein.
                    Self.seen[wish.key] = wish.startAt ?? .distantPast
                } catch { failure = .internal }
            }
        }
        if let failure { throw failure }
    }

    @MainActor private func end(_ key: String, final wish: TripActivityDesire?) {
        Self.seen[key] = nil
        for id in activities.filter({ $0.attributes.key == key }).map(\.id) {
            ending.withLock { _ = $0.insert(id) }
            // Im Hintergrund (BG-Lauf, Ankunft, Obergrenze) friert iOS den Prozess sonst vor dem Ende ein.
            let background = UIApplication.shared.beginBackgroundTask(withName: "TripActivityEnd") { self.release(id) }
            backgroundTasks.withLock { $0[id] = background }
            Task {
                await Self.end(id, final: wish)
                release(id)
            }
        }
    }

    /// Ablauf und Ende des Tasks kommen beide hierher: wer die ID herausnimmt, beendet ihn, also nie doppelt.
    @MainActor private func release(_ id: String) {
        guard let background = backgroundTasks.withLock({ $0.removeValue(forKey: id) }) else { return }
        UIApplication.shared.endBackgroundTask(background)
    }

    // Ueber die ID: `Activity` ist nicht Sendable, und ein gleichzeitiger Neustart nach dem Ersetzen traegt denselben `key`.
    private static func end(_ id: String, final wish: TripActivityDesire?) async {
        guard let activity = TripActivity.activities.first(where: { $0.id == id }) else { return }
        // Ankunft bleibt als Endstand stehen, alles andere verschwindet sofort.
        if let wish {
            await activity.end(ActivityContent(state: wish.state, staleDate: nil),
                               dismissalPolicy: .after(.now.addingTimeInterval(TripActivityPlanner.finishLinger)))
        } else {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func update(_ id: String, _ wish: TripActivityDesire, alert: Bool) async {
        guard let activity = TripActivity.activities.first(where: { $0.id == id }) else { return }
        let content = ActivityContent(state: wish.state, staleDate: wish.staleDate)
        guard alert else { return await activity.update(content) }
        // Fertige Texte aus TransitCore; ohne Halte, sie stehen auch auf der Uhr.
        let title = LocalizedStringResource(String.LocalizationValue(wish.state.title(stale: false)))
        let body = LocalizedStringResource(String.LocalizationValue(wish.state.ride?.line ?? ""))
        await activity.update(content, alertConfiguration: AlertConfiguration(title: title, body: body, sound: .default))
    }

    private func request(_ wish: TripActivityDesire) throws -> TripActivity {
        let attributes = TripActivityAttributes(key: wish.key, startAt: wish.startAt)
        let content = ActivityContent(state: wish.state, staleDate: wish.staleDate)
        guard let start = wish.startAt else { return try TripActivity.request(attributes: attributes, content: content, pushType: nil) }
        // Pflichtangabe beim geplanten Start. T-15 ist eine stille Vorschau (SPEZIFIKATION 4.3), die Mitteilungen melden sich selbst.
        let alert = AlertConfiguration(title: "Fahrt beginnt bald", body: "In 15 Min. losgehen", sound: .named(""))
        return try TripActivity.request(attributes: attributes, content: content, pushType: nil, style: .standard,
                                        alertConfiguration: alert, start: start)
    }
}
