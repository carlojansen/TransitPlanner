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
    @MainActor func apply(_ actions: [TripActivityAction])
}

struct NoTripActivities: TripActivityControlling {
    @MainActor var canStart: Bool { false }
    @MainActor func running() -> [TripActivityRunning] { [] }
    @MainActor func apply(_ actions: [TripActivityAction]) {}
}

final class SystemTripActivities: TripActivityControlling {
    private typealias TripActivity = Activity<TripActivityAttributes>

    /// `end` laeuft asynchron: bis dahin zaehlt eine beendete Activity nicht mehr, sonst saehe der naechste Abgleich zwei je Fahrt.
    private let ending = Mutex<Set<String>>([])

    private var activities: [TripActivity] {
        let ending = ending.withLock { $0 }
        return TripActivity.activities.filter { [.active, .pending, .stale].contains($0.activityState) && !ending.contains($0.id) }
    }

    @MainActor var canStart: Bool {
        UIApplication.shared.applicationState == .active && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    @MainActor func running() -> [TripActivityRunning] {
        activities.map {
            TripActivityRunning(key: $0.attributes.key, state: $0.content.state, startAt: $0.attributes.startAt,
                                isPending: $0.activityState == .pending)
        }
    }

    @MainActor func apply(_ actions: [TripActivityAction]) {
        for action in actions {
            switch action {
            case .end(let key):
                for id in activities.filter({ $0.attributes.key == key }).map(\.id) {
                    ending.withLock { _ = $0.insert(id) }
                    Task { await Self.end(id) }
                }
            case .update(let wish):
                for id in activities.filter({ $0.attributes.key == wish.key }).map(\.id) { Task { await Self.update(id, wish) } }
            case .start(let wish):
                // Schlaegt der Start fehl (abgeschaltet, Limit), versucht es der naechste Abgleich; Rueckfall sind die Mitteilungen.
                _ = try? request(wish)
            }
        }
    }

    // Ueber die ID: `Activity` ist nicht Sendable, und ein gleichzeitiger Neustart nach dem Ersetzen traegt denselben `key`.
    private static func end(_ id: String) async {
        guard let activity = TripActivity.activities.first(where: { $0.id == id }) else { return }
        // Ankunft bleibt als Endstand stehen, alles andere verschwindet sofort.
        await activity.end(nil, dismissalPolicy: activity.content.state.phase == .arrived ? .default : .immediate)
    }

    private static func update(_ id: String, _ wish: TripActivityDesire) async {
        guard let activity = TripActivity.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: wish.state, staleDate: wish.staleDate))
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
