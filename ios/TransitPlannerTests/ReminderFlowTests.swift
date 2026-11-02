#if DEBUG
import Foundation
import Synchronization
import Testing
import TransitCore
import UIKit
import UserNotifications
@testable import TransitPlanner

private func iso(_ time: String) -> Date {
    (try? Date.ISO8601FormatStyle().parse("2026-10-24T\(time)Z")) ?? .distantPast
}

/// Verbindung 0: STR 704 ab 06:08, Token "ZmFrZQ==". Verbindung 1: RE 1 ab 06:20. Gehzeiten kommen aus `FakeWalking`.
@MainActor @Suite struct ReminderFlowTests {
    typealias Clock = NavigationFlowTests.Clock

    final class Env: Sendable {
        let clock = Clock()
        let secrets = InMemorySecretStore(token: String(repeating: "k", count: 40))
        let store = MemoryReminders()
        let notifier = FakeNotifier()
        let refresher = FakeRefresher()
        let checks = Mutex<[Date?]>([])
        /// Geschriebene Snapshots; der letzte ist "die Datei".
        let snapshots = Mutex<[TripSnapshot]>([])
        let activities = FakeTripActivities()
        let backgroundSessions = Mutex(0)
        let endedSessions = Mutex(0)

        func deps(onboarding: OnboardingChoice? = .withLocation, blockedUntil: Date? = nil) -> AppDependencies {
            var deps = AppDependencies.fakes(secrets: secrets, onboarding: onboarding, blockedUntil: blockedUntil,
                                             debounce: .milliseconds(10), refresher: refresher, reminders: store, notifier: notifier)
            deps.now = { self.clock.now }
            deps.undoWindow = .milliseconds(30)
            deps.scheduleBackgroundCheck = { date in self.checks.withLock { $0.append(date) } }
            deps.loadSnapshot = { self.snapshots.withLock { $0.last ?? .empty } }
            deps.saveSnapshot = { snapshot in self.snapshots.withLock { $0.append(snapshot) } }
            deps.activities = activities
            deps.beginBackgroundLocation = {
                self.backgroundSessions.withLock { $0 += 1 }
                return { self.endedSessions.withLock { $0 += 1 } }
            }
            return deps
        }
    }

    func planned(_ env: Env) async -> AppFlow {
        env.clock.set("05:00:00")
        let f = AppFlow(env.deps())
        f.send(.editEndpoint(.destination))
        f.choose(NavigationFlowTests.stop)
        await f.waitForWork()
        return f
    }

    func armed(_ env: Env, earlier: Int = 0, warn: Int = 0) async throws -> (AppFlow, UUID) {
        let f = await planned(env)
        try await f.setReminder(forJourney: 0, earlierMinutes: earlier, warnMinutes: warn)
        return (f, try #require(f.reminders.rows.first).id)
    }

    /// Veraenderter Stand wie vom Refresh, ueber JSON (Modelle haben keinen oeffentlichen Init).
    func changed(_ edit: (inout [String: Any]) -> Void) throws -> Journey {
        let journey = try #require(FakeData.routes?.journeys.first)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(journey)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(Journey.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func delayed(by seconds: TimeInterval) throws -> Journey {
        try changed { object in
            guard var legs = object["legs"] as? [[String: Any]], let departure = legs[1]["departure"] as? Double else { return }
            legs[1]["departure"] = departure + seconds
            object["legs"] = legs
        }
    }

    // MARK: Persistenz, IDs

    @Test func severalRemindersWithOwnIDsSurviveNewPlanning() async throws {
        let env = Env()
        let (f, first) = try await armed(env, earlier: 10, warn: 5)
        #expect(try env.secrets.read(.refreshToken(tripID: first)) == Data("ZmFrZQ==".utf8))
        #expect(env.store.all().first?.plan.calibrated.journey.refreshToken == nil)
        #expect(env.notifier.alerts.map(\.kind) == [.warn, .leave])
        #expect(f.reminderTime(forJourney: 0) == f.reminders.rows.first?.plan.firstAlarm)
        #expect(f.reminderTime(forJourney: 1) == nil)

        try await f.setReminder(forJourney: 1, earlierMinutes: 0, warnMinutes: 0)
        #expect(f.reminders.rows.count == 2)
        #expect(Set(env.notifier.alerts.map(\.tripID)).count == 2)

        // Neue Suche laesst Erinnerungen stehen; ein neuer Lauf der App liest sie wieder.
        f.send(.back)
        f.send(.planTapped)
        await f.waitForWork()
        #expect(f.reminders.rows.count == 2 && env.notifier.alerts.count == 3)
        #expect(f.reminderTime(forJourney: 1) != nil)
        #expect(AppFlow(env.deps()).reminders.rows.count == 2)
    }

    @Test func sameTripIsReplacedNotDuplicated() async throws {
        let env = Env()
        let (f, id) = try await armed(env, earlier: 10, warn: 5)
        try await f.setReminder(forJourney: 0, earlierMinutes: 0, warnMinutes: 0)
        #expect(f.reminders.rows.map(\.id) == [id])
        #expect(f.reminders.rows.first?.plan.earlierMinutes == 0)
        #expect(env.notifier.alerts.map(\.kind) == [.leave])
    }

    /// D1: Merken nur bei Erfolg; die gespeicherte Erinnerung derselben Fahrt geht vor, sonst gilt der Wert des Ziels.
    @Test func earlierMinutesAreRememberedPerDestination() async throws {
        let env = Env()
        let places = MemoryPlaces()
        var deps = env.deps()
        deps.places = places
        env.clock.set("05:00:00")
        func flow(to destination: TripEndpoint) async -> AppFlow {
            let f = AppFlow(deps)
            f.send(.editEndpoint(.destination))
            f.choose(destination)
            await f.waitForWork()
            return f
        }
        let f = await flow(to: NavigationFlowTests.stop)
        #expect(f.suggestedEarlierMinutes(forJourney: 0) == 0)

        env.store.failing.withLock { $0 = true }
        await #expect(throws: TransitError.storageUnavailable) { try await f.setReminder(forJourney: 0, earlierMinutes: 5, warnMinutes: 0) }
        #expect(f.suggestedEarlierMinutes(forJourney: 0) == 0)
        env.store.failing.withLock { $0 = false }

        try await f.setReminder(forJourney: 0, earlierMinutes: 10, warnMinutes: 0)
        try await f.setReminder(forJourney: 1, earlierMinutes: 20, warnMinutes: 0)
        #expect(f.suggestedEarlierMinutes(forJourney: 0) == 10)
        f.reminders.purge(try #require(f.reminders.rows.first { $0.plan.earlierMinutes == 10 }).id)
        #expect(f.suggestedEarlierMinutes(forJourney: 0) == 20)

        let other = await flow(to: .stop(id: "woanders", label: "Woanders"))
        #expect(other.suggestedEarlierMinutes(forJourney: 0) == 0)
    }

    /// Review: der gemerkte Wert darf das Losgehen nicht in die Vergangenheit schieben. 15 Min. vor dem Losgehen passt 10 noch
    /// (5 Min. Rest), 20 und 15 nicht; passt nichts, bleibt 0. Eine gespeicherte Erinnerung behaelt ihren Wert.
    @Test func rememberedValueNeverMovesLeavingIntoThePast() async throws {
        let env = Env()
        let f = await planned(env)
        try await f.setReminder(forJourney: 0, earlierMinutes: 20, warnMinutes: 0)
        let row = try #require(f.reminders.rows.first)
        let leave = row.plan.scheduled.leaveAt
        func clock(_ minutesBefore: TimeInterval) { env.clock.value.withLock { $0 = leave.addingTimeInterval(-minutesBefore * 60) } }
        clock(10)
        #expect(f.suggestedEarlierMinutes(forJourney: 0) == 20) // Erinnerung derselben Fahrt
        f.reminders.purge(row.id)

        clock(40)
        #expect(f.suggestedEarlierMinutes(forJourney: 0) == 20)
        clock(15)
        #expect(f.suggestedEarlierMinutes(forJourney: 0) == 10)
        clock(5)
        #expect(f.suggestedEarlierMinutes(forJourney: 0) == 0)
    }

    /// Review: ein Sprung aus der Mitteilung laesst keine alte Ankunftssuche stehen.
    @Test func openingAReminderResetsArrivalTime() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        f.isArrivalTime = true
        f.openReminder(id)
        #expect(!f.isArrivalTime)
    }

    /// Review: "Wechseln" in den Alternativen beendet den Wecker der laufenden Fahrt; dieselbe Fahrt behaelt ihn.
    @Test func switchingToAnAlternativeRetiresTheOldReminder() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        f.send(.startNavigation(0))
        f.openAlternatives()
        await f.waitForPeek()
        f.chooseAlternative(0)
        #expect(f.reminders.reminder(id: id) != nil)

        f.openAlternatives()
        await f.waitForPeek()
        f.chooseAlternative(1)
        #expect(f.reminders.reminder(id: id) == nil)
        #expect(env.notifier.alerts.isEmpty)
    }

    /// Review: scheitert das Ersetzen der Mitteilungen, bleibt der neue Stand; der naechste Lauf ersetzt sie auch ohne neue Aenderung.
    @Test func failedAlertReplacementIsRetriedByTheNextCheck() async throws {
        let env = Env()
        let n = StepNotifier()
        let (f, id) = try await armedFlow(env, n, warn: 0)
        let before = try #require(f.reminders.rows.first?.plan.leaveAt)
        let identifier = ReminderAlert.identifier(id, .leave)
        env.refresher.set(.success(try delayed(by: 300)))
        n.failing.withLock { $0 = true }
        env.clock.set("05:35:00")
        await f.reminders.checkDue()
        let moved = before.addingTimeInterval(300)
        #expect(f.reminders.rows.first?.plan.leaveAt == moved)
        #expect(f.reminders.rows.first?.plan.alertsPending == true)
        #expect(env.store.all().first?.plan.alertsPending == true)
        #expect(n.pending.withLock { $0[identifier]?.fireAt } == before)

        n.failing.withLock { $0 = false }
        env.clock.set("05:40:00")
        await f.reminders.checkDue()
        #expect(f.reminders.rows.first?.plan.leaveAt == moved)
        #expect(f.reminders.rows.first?.plan.alertsPending == nil)
        #expect(env.store.all().first?.plan.alertsPending == nil)
        #expect(n.pending.withLock { $0[identifier]?.fireAt } == moved)
    }

    /// Mitteilungen in iOS aus, die Bahn faellt aus: der Hinweis Kritisch kommt trotzdem, und Wiederholen schreibt keinen Snapshot.
    @Test func failedAlertReplacementStillShowsLostConnection() async throws {
        let env = Env()
        let n = StepNotifier()
        let (f, id) = try await armedFlow(env, n, warn: 0)
        env.refresher.set(.success(try changed { $0["cancelled"] = true }))
        n.failing.withLock { $0 = true }
        env.clock.set("05:35:00")
        await f.reminders.checkDue()
        #expect(f.reminders.lost?.id == id)
        #expect(f.reminders.rows.first?.plan.alertsPending == true)
        let written = env.snapshots.withLock { $0.count }
        #expect(env.snapshots.withLock { $0.last?.trips.first?.status } == .lost)

        env.clock.set("05:40:00")
        await f.reminders.checkDue()
        env.clock.set("05:45:00")
        await f.reminders.checkDue()
        #expect(env.refresher.callCount == 3)
        #expect(f.reminders.lost?.id == id)
        #expect(env.snapshots.withLock { $0.count } == written)

        n.failing.withLock { $0 = false }
        env.clock.set("05:50:00")
        await f.reminders.checkDue()
        #expect(f.reminders.rows.first?.plan.alertsPending == nil)
        #expect(n.pending.withLock { $0[ReminderAlert.identifier(id, .leave)]?.title } == "Verbindung fällt aus")
        #expect(env.snapshots.withLock { $0.count } == written)
    }

    /// Einstellung "Am Gleis sein vorher": gespeichert, in neuen Erinnerungen und beim Refresh bestehender.
    @Test func stationBufferReachesNewAndExistingReminders() async throws {
        let env = Env()
        let (f, _) = try await armed(env)
        let before = try #require(f.reminders.rows.first?.plan)
        #expect(before.scheduled.bufferSeconds == 120)

        f.reminders.stationBufferMinutes = 5
        let stored = DepartureScheduler.storedBufferMinutes
        UserDefaults.standard.removeObject(forKey: DepartureScheduler.bufferMinutesKey)
        #expect(stored == 5)

        env.clock.set("05:40:00")
        await f.reminders.checkDue()
        let after = try #require(f.reminders.rows.first?.plan)
        #expect(after.scheduled.bufferSeconds == 300)
        #expect(after.leaveAt == before.leaveAt.addingTimeInterval(-180))
        #expect(env.notifier.alerts.first { $0.kind == .leave }?.fireAt == after.leaveAt)

        try await f.setReminder(forJourney: 1, earlierMinutes: 0, warnMinutes: 0)
        #expect(f.reminders.rows.allSatisfy { $0.plan.scheduled.bufferSeconds == 300 })
    }

    @Test func storedRequestNeverContainsTheLiveLocation() async throws {
        let env = Env()
        let (f, _) = try await armed(env)
        #expect(f.origin == .currentLocation)
        #expect(f.reminders.rows.first?.request.origin == .stop(id: "a", label: "Düsseldorf Hbf"))
        #expect(f.reminders.rows.first?.request.destination == NavigationFlowTests.stop)
    }

    @Test func deletingRemovesEverythingAndUndoRestoresIt() async throws {
        let env = Env()
        let (f, id) = try await armed(env, warn: 5)
        f.reminders.delete(id)
        #expect(f.reminders.rows.isEmpty && env.store.all().isEmpty && env.notifier.alerts.isEmpty)
        #expect(try env.secrets.read(.refreshToken(tripID: id)) == nil)

        await f.reminders.undoDelete()
        #expect(f.reminders.rows.map(\.id) == [id] && env.store.all().count == 1)
        #expect(try env.secrets.read(.refreshToken(tripID: id)) == Data("ZmFrZQ==".utf8))
        #expect(env.notifier.alerts.map(\.kind) == [.warn, .leave])
        #expect(f.reminders.undo == nil)

        // Nach Ablauf gibt es nichts mehr zurueckzuholen, auch den Token nicht im RAM
        f.reminders.delete(id)
        for _ in 0..<50 where f.reminders.undo != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.reminders.undo == nil)
        await f.reminders.undoDelete()
        #expect(f.reminders.rows.isEmpty)
    }

    @Test func pastRemindersAreCleanedUp() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        env.clock.set("06:43:00")
        await f.reminders.checkDue()
        #expect(f.reminders.rows.isEmpty && env.store.all().isEmpty)
        #expect(try env.secrets.read(.refreshToken(tripID: id)) == nil)
        #expect(env.refresher.callCount == 0)
    }

    @Test func badgeOnlyWhileActiveToday() async throws {
        let env = Env()
        let (f, _) = try await armed(env)
        #expect(f.reminders.activeToday)
        env.clock.set("06:09:00")
        #expect(!f.reminders.activeToday) // abgefahren, noch nicht aufgeraeumt
    }

    // MARK: Neuberechnung

    @Test func noRequestsFarAheadThenThrottled() async throws {
        let env = Env()
        let (f, _) = try await armed(env, earlier: 10)
        await f.reminders.checkDue() // 05:00, Losgehen gegen 05:5x
        #expect(env.refresher.callCount == 0)
        let earliest = try #require(env.checks.withLock { $0.last } ?? nil)
        #expect(earliest == f.reminders.rows.first?.plan.leaveAt.addingTimeInterval(-ReminderPlan.checkLead))

        env.clock.set("05:40:00")
        await f.reminders.checkDue()
        #expect(env.refresher.callCount == 1)
        #expect(f.reminders.rows.first?.plan.isEstimated == false)
        await f.reminders.checkDue()
        #expect(env.refresher.callCount == 1)
        env.clock.set("05:45:00")
        await f.reminders.checkDue()
        #expect(env.refresher.callCount == 2)
    }

    @Test func retryAfterStopsTheChecks() async throws {
        let env = Env()
        let (_, _) = try await armed(env)
        env.clock.set("05:40:00")
        let blocked = AppFlow(env.deps(blockedUntil: iso("06:00:00")))
        await blocked.reminders.checkDue()
        #expect(env.refresher.callCount == 0)
    }

    @Test func snapshotFollowsSetDeleteAndUndo() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        #expect(env.snapshots.withLock { $0.map(\.trips.count) } == [1])
        f.reminders.delete(id)
        await f.reminders.undoDelete()
        #expect(env.snapshots.withLock { $0.map(\.trips.count) } == [1, 0, 1])
        #expect(env.snapshots.withLock { $0.last } == TripSnapshot(plans: f.reminders.rows.map(\.plan)))
    }

    @Test func snapshotFollowsRefreshAndCleanup() async throws {
        let env = Env()
        let (f, _) = try await armed(env)
        env.refresher.set(.success(try delayed(by: 300)))
        env.clock.set("05:40:00")
        await f.reminders.checkDue()
        #expect(env.refresher.callCount == 1)
        #expect(env.snapshots.withLock { $0.count } == 2)
        #expect(env.snapshots.withLock { $0.last?.trips.first?.leaveAt } == f.reminders.rows.first?.plan.leaveAt)
        env.clock.set("06:43:00")
        await f.reminders.checkDue()
        #expect(env.snapshots.withLock { $0.map(\.trips.count) } == [1, 1, 0])
    }

    /// Fehlversuch aendert die Zeile (`attemptedAt`), aber nichts, was Widgets sehen.
    @Test func sameContentWritesNothing() async throws {
        let env = Env()
        let (f, _) = try await armed(env)
        env.refresher.set(.failure(.offline))
        env.clock.set("05:35:00")
        await f.reminders.checkDue()
        #expect(env.refresher.callCount == 1)
        #expect(env.snapshots.withLock { $0.count } == 1)
        _ = ReminderCenter(env.deps())
        #expect(env.snapshots.withLock { $0.count } == 1)
    }

    /// Start gleicht ab: Datei fehlt (neu installiert) oder der letzte Schreibversuch ging verloren.
    @Test func launchRepublishesAStaleFile() async throws {
        let env = Env()
        _ = try await armed(env)
        env.snapshots.withLock { $0 = [] }
        _ = ReminderCenter(env.deps())
        #expect(env.snapshots.withLock { $0.map(\.trips.count) } == [1])
    }

    /// Greift die Signatur: ohne App Group im Host-Profil fehlt der Container.
    @Test func appGroupContainerResolves() {
        #expect(TripSnapshotFile.sharedURL != nil)
    }

    @Test func noRemindersNoFile() {
        let env = Env()
        _ = ReminderCenter(env.deps())
        #expect(env.snapshots.withLock { $0.isEmpty })
    }

    // MARK: Live Activity

    @Test func reminderPlansOneActivityAtT15AndDeleteEndsIt() async throws {
        let env = Env()
        let (f, id) = try await armed(env, warn: 5)
        let plan = try #require(f.reminders.rows.first?.plan)
        let running = env.activities.running()
        #expect(running.map(\.key) == [id.uuidString])
        #expect(running.first?.startAt == plan.leaveAt.addingTimeInterval(-TripActivityPlanner.startLead))
        f.syncActivities()
        #expect(env.activities.log.withLock { $0.count } == 1) // gleicher Stand: nichts Neues

        f.reminders.delete(id)
        #expect(env.activities.running().isEmpty)
        await f.reminders.undoDelete()
        #expect(env.activities.running().map(\.key) == [id.uuidString])
    }

    @Test func changedReminderReplacesThePlannedActivity() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        try await f.setReminder(forJourney: 0, earlierMinutes: 10, warnMinutes: 0)
        #expect(env.activities.running().count == 1)
        let plan = try #require(f.reminders.reminder(id: id)?.plan)
        #expect(env.activities.running().first?.startAt == plan.leaveAt.addingTimeInterval(-TripActivityPlanner.startLead))
    }

    @Test func navigationKeepsTheSameActivityAndAbortEndsIt() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        env.clock.set("05:58:00")
        f.openReminder(id)
        #expect(env.activities.running().map(\.key) == [id.uuidString])
        #expect(env.activities.running().first?.state.phase == .walk)
        #expect(env.activities.running().first?.startAt == nil) // Rueckfall: laeuft jetzt, nicht geplant
        f.send(.back)
        #expect(env.activities.running().first?.state.phase == .leave) // Erinnerung steht weiter, dieselbe Activity
        env.clock.set("06:43:00")
        await f.reminders.checkDue()
        #expect(env.activities.running().isEmpty)
    }

    @Test func navigationWithoutReminderHasItsOwnKeyAndEnds() async throws {
        let env = Env()
        let f = await planned(env)
        env.clock.set("05:58:00")
        f.send(.startNavigation(0))
        let key = try #require(env.activities.running().first?.key)
        #expect(env.activities.running().count == 1 && UUID(uuidString: key) != nil)
        f.send(.back)
        #expect(env.activities.running().isEmpty)
        // Eine weggewischte Fahrt sperrt die naechste nicht.
        env.activities.dismissed.withLock { _ = $0.insert(key) }
        f.send(.startNavigation(0))
        #expect(env.activities.running().count == 1 && env.activities.running().first?.key != key)
    }

    @Test func navigationWhileWaitingStartsAtOnce() async throws {
        let env = Env()
        let f = await planned(env)
        f.send(.startNavigation(0))
        #expect(f.navStep == .waitingToLeave(vehicle: 1))
        #expect(env.activities.running().first?.isPending == false)
        #expect(env.activities.running().first?.state.phase == .leave)
    }

    // MARK: Obergrenze fuer GPS und Polling

    func missed(_ env: Env) async -> AppFlow {
        let f = await planned(env)
        f.send(.startNavigation(0))
        env.clock.set("05:58:00")
        f.navigationUpdate(position: nil, now: env.clock.now)
        env.clock.set("06:09:00")
        f.navigationUpdate(position: NavigationFlowTests.destination, accuracy: 5, now: env.clock.now)
        return f
    }

    @Test func missedInTheBackgroundStopsTrackingAfterTheGrace() async throws {
        let env = Env()
        let f = await missed(env)
        #expect(f.navStep == .missedDeparture(vehicle: 1))
        f.movedToBackground()
        f.navigationUpdate(position: nil, now: env.clock.now)
        env.clock.value.withLock { $0 = $0.addingTimeInterval(NavigationEngine.missedGrace - 1) }
        f.navigationUpdate(position: nil, now: env.clock.now)
        #expect(f.navStep == .missedDeparture(vehicle: 1) && env.endedSessions.withLock { $0 } == 0)
        env.clock.value.withLock { $0 = $0.addingTimeInterval(1) }
        f.navigationUpdate(position: nil, now: env.clock.now)
        #expect(f.phase == .routeSelection && f.navStep == nil && f.navPosition == nil)
        #expect(env.endedSessions.withLock { $0 } == 1)
        #expect(env.activities.running().isEmpty)
        await f.refreshNavigation()
        #expect(env.refresher.callCount == 0)
    }

    /// Im Vordergrund entscheidet der Nutzer; zurueck in der App beginnt die Frist im Hintergrund neu.
    @Test func missedInTheForegroundStaysOnScreen() async throws {
        let env = Env()
        let f = await missed(env)
        f.movedToBackground()
        f.navigationUpdate(position: nil, now: env.clock.now)
        env.clock.value.withLock { $0 = $0.addingTimeInterval(60) }
        f.becameActive()
        f.navigationUpdate(position: nil, now: env.clock.now)
        env.clock.value.withLock { $0 = $0.addingTimeInterval(NavigationEngine.missedGrace) }
        f.navigationUpdate(position: nil, now: env.clock.now)
        #expect(f.navStep == .missedDeparture(vehicle: 1))
        f.movedToBackground()
        f.navigationUpdate(position: nil, now: env.clock.now)
        #expect(f.navStep == .missedDeparture(vehicle: 1))
    }

    @Test func destinationNeverReachedEndsTrackingAfterTheGrace() async throws {
        let env = Env()
        let f = await planned(env)
        f.send(.startNavigation(0))
        env.clock.set("05:58:00")
        f.navigationUpdate(position: nil, now: env.clock.now)
        f.movedToBackground()
        env.clock.set("06:43:00")
        f.navigationUpdate(position: nil, now: env.clock.now)
        #expect(f.navStep == .finalWalkToDestination)
        env.clock.set("07:11:59") // Ankunft 06:42 plus 30 Min.
        f.navigationUpdate(position: nil, now: env.clock.now)
        #expect(f.navStep == .finalWalkToDestination && env.endedSessions.withLock { $0 } == 0)
        env.clock.set("07:12:00")
        f.navigationUpdate(position: nil, now: env.clock.now)
        #expect(f.phase == .routeSelection && env.endedSessions.withLock { $0 } == 1)
        #expect(env.activities.running().isEmpty)
    }

    /// Im Vordergrund verschwindet die Navigation nie ohne Hinweis, auch nicht nach 410.
    @Test func foregroundKeepsNavigationPastTheGrace() async throws {
        let env = Env()
        let f = await planned(env)
        f.send(.startNavigation(0))
        env.clock.set("05:58:00")
        f.navigationUpdate(position: nil, now: env.clock.now)
        env.refresher.set(.failure(.refreshExpired))
        await f.refreshNavigation()
        env.clock.set("07:30:00")
        f.navigationUpdate(position: nil, now: env.clock.now)
        #expect(f.phase == .navigation(0) && f.navExpired)
        #expect(f.navStep == .finalWalkToDestination && env.endedSessions.withLock { $0 } == 0)
    }

    /// Ziel erst nach Ablauf der Nachfrist erreicht: das ist eine Ankunft, kein Abbruch.
    @Test func reachingTheDestinationLateIsStillAnArrival() async throws {
        let env = Env()
        let f = await planned(env)
        f.send(.startNavigation(0))
        env.clock.set("05:58:00")
        f.navigationUpdate(position: nil, now: env.clock.now)
        f.movedToBackground()
        env.clock.set("07:30:00")
        f.navigationUpdate(position: NavigationFlowTests.destination, now: env.clock.now)
        #expect(f.phase == .arrival)
    }

    @Test func expiredTripStopsPolling() async throws {
        let env = Env()
        let f = await planned(env)
        f.send(.startNavigation(0))
        env.refresher.set(.failure(.refreshExpired))
        await f.refreshNavigation()
        #expect(f.navExpired && env.refresher.callCount == 1)
        await f.refreshNavigation()
        await f.refreshFromActivity()
        #expect(env.refresher.callCount == 1)
    }

    // MARK: Live Activity: Ablehnen, Ende, Knopf

    @Test func dismissedActivityDoesNotComeBack() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        env.clock.set("05:50:00")
        f.becameActive()
        await f.waitForReminderCheck()
        #expect(env.activities.running().first?.isPending == false)
        env.activities.dismiss(id.uuidString)
        let starts = env.activities.log.withLock { $0 }.count
        f.syncActivities()
        f.becameActive()
        await f.waitForReminderCheck()
        #expect(env.activities.running().isEmpty)
        #expect(!env.activities.log.withLock { Array($0[starts...]) }.contains { if case .start = $0 { true } else { false } })

        f.openReminder(id) // Bewusster Start hebt die Ablehnung auf
        #expect(env.activities.running().map(\.key) == [id.uuidString])
        env.activities.dismiss(id.uuidString) // Wegwischen waehrend der Navigation gilt wieder
        f.navigationUpdate(position: nil, now: env.clock.now)
        #expect(env.activities.running().isEmpty)
    }

    /// Die Erinnerung wird nach der Ankunft aufgeraeumt: der Key bleibt, es entsteht keine zweite Activity.
    @Test func arrivalEndsTheActivityAndPurgeKeepsTheKey() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        env.clock.set("05:58:00")
        f.openReminder(id)
        env.clock.set("06:41:00")
        f.navigationUpdate(position: NavigationFlowTests.destination, now: env.clock.now)
        #expect(f.phase == .arrival)
        #expect(env.activities.running().isEmpty)
        let finished = env.activities.log.withLock { $0 }.compactMap { action -> TripActivityDesire? in
            if case .finish(let wish) = action { wish } else { nil }
        }
        #expect(finished.map(\.key) == [id.uuidString] && finished.first?.state.phase == .arrived)

        let before = env.activities.log.withLock { $0.count }
        f.reminders.purge(id)
        f.syncActivities()
        #expect(env.activities.log.withLock { $0.count } == before)
        #expect(env.activities.running().isEmpty)
    }

    /// Faellt die Erinnerung unterwegs weg, bleibt es dieselbe Activity.
    @Test func purgeDuringNavigationKeepsTheActivity() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        env.clock.set("05:58:00")
        f.openReminder(id)
        #expect(env.activities.running().map(\.key) == [id.uuidString])
        env.activities.log.withLock { $0 = [] }
        f.reminders.purge(id)
        f.syncActivities()
        #expect(env.activities.running().map(\.key) == [id.uuidString])
        #expect(env.activities.log.withLock { $0 }.isEmpty)
    }

    @Test func missedBufferShowsAsProblem() async throws {
        let env = Env()
        let f = await planned(env)
        f.send(.startNavigation(0))
        env.clock.set("05:58:00")
        f.navigationUpdate(position: nil, now: env.clock.now)
        #expect(env.activities.running().first?.state.problem == nil)
        env.clock.set("06:07:30")
        f.navigationUpdate(position: nil, now: env.clock.now)
        #expect(f.currentBuffer?.status == .missed)
        #expect(env.activities.running().first?.state.problem == .connection)
    }

    /// GPS-Spruenge um Puffer 0: der Ausfall meldet sich einmal und bleibt bis zum neuen Stand.
    @Test func flippingBufferAlertsOnce() async throws {
        let env = Env()
        let f = await planned(env)
        f.send(.startNavigation(0))
        env.clock.set("06:05:00")
        let far = GeoCoordinate(latitude: 51.2201, longitude: 6.7905), near = GeoCoordinate(latitude: 51.22003, longitude: 6.79241)
        f.navigationUpdate(position: near, accuracy: 5, now: env.clock.now)
        #expect(f.currentBuffer?.status != .missed)
        #expect(env.activities.running().first?.state.problem == nil)
        for position in [far, near, far, near, far, near] {
            f.navigationUpdate(position: position, accuracy: 5, now: env.clock.now)
        }
        #expect(f.navStep == .approachingFirstStop(vehicle: 1))
        #expect(f.currentBuffer?.status != .missed) // zuletzt reicht es wieder, die Meldung bleibt
        #expect(env.activities.running().first?.state.problem == .connection)
        let alerts = env.activities.log.withLock { $0 }.filter { if case .update(_, alert: true) = $0 { true } else { false } }
        #expect(alerts.count == 1)

        env.refresher.set(.success(try delayed(by: 300)))
        await f.refreshNavigation()
        #expect(env.activities.running().first?.state.problem == nil)
    }

    func flip(_ f: AppFlow, _ env: Env, times: Int = 3) {
        let far = GeoCoordinate(latitude: 51.2201, longitude: 6.7905), near = GeoCoordinate(latitude: 51.22003, longitude: 6.79241)
        for _ in 0..<times {
            f.navigationUpdate(position: far, accuracy: 5, now: env.clock.now)
            f.navigationUpdate(position: near, accuracy: 5, now: env.clock.now)
        }
    }

    func alertCount(_ env: Env) -> Int {
        env.activities.log.withLock { $0 }.filter { if case .update(_, alert: true) = $0 { true } else { false } }.count
    }

    /// Ein Refresh, der am Anschluss nichts verbessert, hebt das Einrasten nicht auf.
    @Test func refreshWithoutBetterBufferKeepsTheSingleAlert() async throws {
        let env = Env()
        let f = await planned(env)
        f.send(.startNavigation(0))
        env.clock.set("06:05:00")
        flip(f, env)
        #expect(alertCount(env) == 1)
        env.refresher.set(.success(try changed { $0["durationSeconds"] = 1 }))
        await f.refreshNavigation()
        flip(f, env)
        env.refresher.set(.success(try changed { $0["durationSeconds"] = 2 }))
        await f.refreshNavigation()
        flip(f, env)
        #expect(alertCount(env) == 1)
        #expect(env.activities.running().first?.state.problem == .connection)
    }

    /// Ohne Fix rechnet der Puffer mit dem ganzen Fussweg: das darf den ersten echten Fix nicht ueberleben.
    @Test func startWithoutFixDoesNotLatch() async throws {
        let env = Env()
        let f = await planned(env)
        env.clock.set("06:06:00")
        f.send(.startNavigation(0))
        #expect(env.activities.running().first?.state.problem == .connection)
        f.navigationUpdate(position: GeoCoordinate(latitude: 51.22003, longitude: 6.79241), accuracy: 5, now: env.clock.now)
        #expect(f.navStep == .approachingFirstStop(vehicle: 1))
        #expect(f.currentBuffer?.status != .missed)
        #expect(env.activities.running().first?.state.problem == nil)
    }

    /// Am Gleis ist das Fahrzeug erreicht, auch wenn der Puffer vorher nicht reichte.
    @Test func reachingThePlatformClearsTheMissedBuffer() async throws {
        let env = Env()
        let f = await planned(env)
        f.send(.startNavigation(0))
        env.clock.set("06:05:00")
        flip(f, env, times: 1)
        #expect(env.activities.running().first?.state.problem == .connection)
        f.navigationUpdate(position: NavigationFlowTests.hbf, accuracy: 5, now: env.clock.now)
        #expect(f.navStep == .waitingAtPlatform(vehicle: 1))
        #expect(env.activities.running().first?.state.problem == nil)
    }

    /// Im Umstieg zaehlt auch ein spaeterer Anschluss. Deutz: Tram ab Hansaring faehrt vor der Ankunft plus Fussweg.
    @Test func transferSeesALaterBrokenConnection() async throws {
        let env = Env()
        var deps = env.deps()
        deps.planner = FakeRoutePlanner(response: FakeData.deutz())
        env.clock.value.withLock { $0 = (try? Date.ISO8601FormatStyle().parse("2026-10-26T07:00:00Z")) ?? .distantPast }
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(NavigationFlowTests.stop)
        await f.waitForWork()
        f.send(.startNavigation(0))
        let journey = try #require(FakeData.deutz()?.journeys.first)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(journey)) as? [String: Any])
        var legs = try #require(object["legs"] as? [[String: Any]])
        legs[4]["departure"] = try #require(legs[4]["departure"] as? Double) - 170
        object["legs"] = legs
        env.refresher.set(.success(try JSONDecoder().decode(Journey.self, from: JSONSerialization.data(withJSONObject: object))))
        env.clock.value.withLock { $0 = (try? Date.ISO8601FormatStyle().parse("2026-10-26T07:31:00Z")) ?? .distantPast }
        await f.refreshNavigation()
        #expect(f.navStep == .transferRouting(from: 0, to: 2))
        #expect(f.currentBuffer?.status != .missed)
        #expect(env.activities.running().first?.state.problem == .connection)
    }

    @Test func activityButtonIsThrottledDuringNavigation() async throws {
        let env = Env()
        let f = await planned(env)
        f.send(.startNavigation(0))
        env.clock.set("05:58:00")
        await f.refreshFromActivity()
        #expect(env.refresher.callCount == 1)
        env.clock.value.withLock { $0 = $0.addingTimeInterval(AppFlow.activityRefreshGap - 1) }
        await f.refreshFromActivity()
        #expect(env.refresher.callCount == 1)
        env.clock.value.withLock { $0 = $0.addingTimeInterval(1) }
        await f.refreshFromActivity()
        #expect(env.refresher.callCount == 2)
    }

    @Test func activityButtonWaitsForARunningRefresh() async throws {
        let env = Env()
        let (gate, release) = AsyncStream<Void>.makeStream()
        var deps = env.deps()
        let calls = Mutex(0)
        deps.refresh = { token throws(TransitError) in
            calls.withLock { $0 += 1 }
            for await _ in gate { break }
            guard let journey = FakeData.routes?.journeys.first(where: { $0.refreshToken == token }) else { throw .internal }
            return journey
        }
        env.clock.set("05:00:00")
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(NavigationFlowTests.stop)
        await f.waitForWork()
        f.send(.startNavigation(0))
        let running = Task { await f.refreshNavigation() }
        for _ in 0..<50 where calls.withLock({ $0 }) == 0 { await Task.yield() }
        env.clock.set("05:10:00") // Abstand reicht, die laufende Anfrage entscheidet
        let button = Task { await f.refreshFromActivity() }
        for _ in 0..<50 { await Task.yield() }
        #expect(calls.withLock { $0 } == 1)
        release.finish()
        await running.value
        await button.value
    }

    @Test func activityButtonChecksRemindersWithTheirOwnThrottle() async throws {
        let env = Env()
        let (f, _) = try await armed(env)
        env.clock.set("05:40:00")
        await f.refreshFromActivity()
        await f.refreshFromActivity()
        #expect(env.refresher.callCount == 1)
        #expect(env.activities.running().first?.state.phase == .leave)
    }

    /// Prozess war weg: die Activity gehoert zu einer Navigation, die es nicht mehr gibt.
    @Test func coldStartFromTheButtonEndsAStrandedActivity() async throws {
        let env = Env()
        let (first, id) = try await armed(env)
        env.clock.set("05:58:00")
        first.openReminder(id)
        #expect(env.activities.running().first?.state.phase == .walk)
        env.activities.log.withLock { $0 = [] }
        env.activities.enabled.withLock { $0 = false } // Knopf: App im Hintergrund
        let f = AppFlow(env.deps())
        await f.refreshFromActivity()
        #expect(env.activities.running().isEmpty)
        #expect(env.activities.log.withLock { $0 } == [.end(key: id.uuidString)])
    }

    @Test func failedStartWaitsForTheNextActivation() async throws {
        let env = Env()
        env.activities.failing.withLock { $0 = true }
        let (f, _) = try await armed(env)
        func starts() -> Int { env.activities.log.withLock { $0.filter { if case .start = $0 { true } else { false } }.count } }
        #expect(starts() == 1) // beim Scharfschalten
        f.syncActivities()
        f.syncActivities()
        #expect(starts() == 1)
        f.becameActive()
        #expect(starts() == 2)
        await f.waitForReminderCheck()
    }

    @Test func foregroundEndsTheActivityAtDeparture() async throws {
        let env = Env()
        let (_, _) = try await armed(env)
        let departure = try #require(env.store.all().first?.plan.scheduled.firstDeparture)
        env.clock.value.withLock { $0 = departure.addingTimeInterval(-0.05) }
        let f = AppFlow(env.deps())
        f.syncActivities()
        #expect(env.activities.running().count == 1)
        env.clock.value.withLock { $0 = departure }
        for _ in 0..<200 where !env.activities.running().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(env.activities.running().isEmpty)
    }

    @Test func backgroundRunAtDepartureEndsTheActivity() async throws {
        let env = Env()
        let (f, _) = try await armed(env)
        let departure = try #require(f.reminders.rows.first?.plan.scheduled.firstDeparture)
        await f.reminders.checkDue()
        #expect(try #require(env.checks.withLock { $0.last } ?? nil) <= departure)
        env.clock.value.withLock { $0 = departure }
        await f.reminders.checkDue()
        #expect(env.activities.running().isEmpty)
    }

    @Test func withdrawnPermissionEndsTheBackgroundSession() async throws {
        let env = Env()
        let allowed = Mutex(true)
        var deps = env.deps()
        deps.authorization = { allowed.withLock { $0 } ? .allowed : .denied }
        env.clock.set("05:00:00")
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(NavigationFlowTests.stop)
        await f.waitForWork()
        env.clock.set("05:58:00")
        f.send(.startNavigation(0))
        #expect(env.backgroundSessions.withLock { $0 } == 1)
        allowed.withLock { $0 = false }
        f.becameActive()
        #expect(env.endedSessions.withLock { $0 } == 1)
    }

    @Test func orphanEndsWhenTheAppBecomesActive() async throws {
        let env = Env()
        let f = await planned(env)
        let state = try #require(f.reminders.rows.isEmpty ? TripActivityState(plan: try reminderPlan(f)) : nil)
        env.activities.list.withLock { $0 = [TripActivityRunning(key: "alt", state: state, startAt: nil, isPending: false)] }
        f.becameActive()
        #expect(env.activities.running().isEmpty)
        #expect(env.activities.log.withLock { $0 } == [.end(key: "alt")])
    }

    private func reminderPlan(_ f: AppFlow) throws -> ReminderPlan {
        let calibrated = try #require(f.calibratedJourney(at: 0))
        return try ReminderPlan(calibrated: calibrated, earlierMinutes: 0, warnMinutes: 0, attribution: try #require(f.routes?.attribution))
    }

    /// Abgeschaltet oder im Hintergrund: still, kein Banner, und die Erinnerung gilt trotzdem.
    @Test func disabledActivitiesStayQuiet() async throws {
        let env = Env()
        env.activities.enabled.withLock { $0 = false }
        let (f, _) = try await armed(env)
        #expect(env.activities.running().isEmpty && f.banner == nil)
        #expect(f.reminders.rows.count == 1 && !env.notifier.alerts.isEmpty)
    }

    @Test func backgroundLocationOnlyFromTheWalkAndEndsWithTheTrip() async throws {
        let env = Env()
        let f = await planned(env)
        f.send(.startNavigation(0))
        #expect(env.backgroundSessions.withLock { $0 } == 0) // Wartezustand 05:00, weit vor dem Losgehen
        env.clock.set("05:58:00")
        f.navigationUpdate(position: nil, now: env.clock.now)
        f.navigationUpdate(position: nil, now: env.clock.now)
        #expect(env.backgroundSessions.withLock { $0 } == 1)
        f.send(.back)
        #expect(env.endedSessions.withLock { $0 } == 1)
    }

    @Test func noBackgroundSessionWithoutLocationPermission() async throws {
        let env = Env()
        var deps = env.deps()
        let location = FakeLocation(status: .denied)
        deps.location = location
        deps.authorization = { location.status }
        env.clock.set("05:00:00")
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(NavigationFlowTests.stop)
        await f.waitForWork()
        env.clock.set("05:58:00")
        f.send(.startNavigation(0))
        #expect(env.backgroundSessions.withLock { $0 } == 0)
    }

    @Test func delayMovesAlarmAndKeepsChoices() async throws {
        let env = Env()
        let (f, id) = try await armed(env, earlier: 10, warn: 5)
        let before = try #require(f.reminders.rows.first?.plan.leaveAt)
        env.refresher.set(.success(try delayed(by: 300)))
        env.clock.set("05:30:00")
        await f.reminders.checkDue()
        let plan = try #require(f.reminders.rows.first?.plan)
        #expect(plan.leaveAt == before.addingTimeInterval(300))
        #expect(plan.earlierMinutes == 10 && plan.warnMinutes == 5)
        #expect(env.notifier.alerts.map(\.fireAt) == [plan.firstAlarm, plan.leaveAt])
        #expect(env.notifier.alerts.allSatisfy { $0.tripID == id })
        // Geometrie und Wegschritte bleiben trotz Refresh ohne Polylines erhalten
        #expect(plan.calibrated.journey.legs[0].steps.isEmpty == false)
        #expect(env.store.all().first?.plan == plan)
    }

    @Test func connectionLostLeavesAlarmAndOffersNextConnection() async throws {
        let env = Env()
        let planner = FakeRoutePlanner()
        var deps = env.deps()
        deps.planner = planner
        env.clock.set("05:00:00")
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(NavigationFlowTests.stop)
        await f.waitForWork()
        try await f.setReminder(forJourney: 0, earlierMinutes: 5, warnMinutes: 5)
        let alarms = env.notifier.alerts
        f.send(.back)
        f.send(.back)
        #expect(f.phase == .start)

        env.refresher.set(.success(try changed { $0["cancelled"] = true }))
        env.clock.set("05:35:00")
        await f.reminders.checkDue()
        #expect(env.notifier.alerts.map(\.fireAt) == alarms.map(\.fireAt)) // Wecker steht, nichts umgestellt
        #expect(env.notifier.alerts.allSatisfy { $0.title == "Verbindung fällt aus" })
        #expect(f.banner == nil)
        let lost = try #require(f.reminders.lost)
        #expect(lost.plan.status == .lost)
        let searches = planner.callCount

        f.nextConnection(for: lost)
        await f.waitForWork()
        #expect(f.phase == .routeSelection && planner.callCount == searches + 1)
        #expect(f.destination == .place(NavigationFlowTests.stop))
        #expect(env.notifier.alerts.map(\.fireAt) == alarms.map(\.fireAt)) // neue Suche stellt den Wecker nicht um
        #expect(f.reminders.rows.count == 1)
    }

    @Test func expiredShowsEstimateWithoutErrorOrFurtherRequests() async throws {
        let env = Env()
        let (f, _) = try await armed(env)
        let alarms = env.notifier.alerts
        env.refresher.set(.failure(.refreshExpired))
        env.clock.set("05:35:00")
        await f.reminders.checkDue()
        #expect(f.reminders.rows.first?.plan.isEstimated == true)
        #expect(f.reminders.rows.first?.plan.status == .expired)
        #expect(f.banner == nil && env.notifier.alerts == alarms)
        env.clock.set("05:45:00")
        await f.reminders.checkDue()
        #expect(env.refresher.callCount == 1)
    }

    @Test func offlineKeepsAlarmAndThrottles() async throws {
        let env = Env()
        let (f, _) = try await armed(env)
        let alarms = env.notifier.alerts
        env.refresher.set(.failure(.offline))
        env.clock.set("05:35:00")
        await f.reminders.checkDue()
        await f.reminders.checkDue()
        #expect(env.refresher.callCount == 1)
        #expect(f.reminders.rows.first?.plan.isEstimated == true && f.banner == nil)
        #expect(env.notifier.alerts == alarms)
    }

    @Test func deletedDuringRefreshStaysDeleted() async throws {
        let env = Env()
        let center = Mutex<ReminderCenter?>(nil)
        var deps = env.deps()
        deps.refresh = { _ throws(TransitError) in
            guard let journey = FakeData.routes?.journeys.first else { throw .internal }
            let reminders = center.withLock { $0 }
            await MainActor.run {
                if let id = reminders?.rows.first?.id { reminders?.delete(id) }
            }
            return journey
        }
        env.clock.set("05:00:00")
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(NavigationFlowTests.stop)
        await f.waitForWork()
        try await f.setReminder(forJourney: 0, earlierMinutes: 0, warnMinutes: 0)
        center.withLock { $0 = f.reminders }
        env.clock.set("05:35:00")
        await f.reminders.checkDue()
        #expect(f.reminders.rows.isEmpty && env.store.all().isEmpty && env.notifier.alerts.isEmpty)
    }

    @Test func becomingActiveChecksEvenWithoutLocationPermission() async throws {
        let env = Env()
        let (_, _) = try await armed(env)
        env.clock.set("05:40:00")
        var deps = env.deps()
        deps.authorization = { .denied }
        let f = AppFlow(deps)
        f.becameActive()
        await f.waitForReminderCheck()
        #expect(env.refresher.callCount == 1)
    }

    @Test func snoozeStopsAtTheLastUsefulMoment() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        let plan = try #require(f.reminders.rows.first?.plan)
        env.clock.value.withLock { $0 = plan.leaveAt }
        await f.reminders.snooze(id)
        let snooze = try #require(env.notifier.alerts.first { $0.kind == .snooze })
        #expect(snooze.fireAt == plan.snoozeTime(now: plan.leaveAt))
        #expect(snooze.fireAt < plan.scheduled.firstDeparture)
    }

    // MARK: Sprung aus der Mitteilung

    @Test func coldStartOpensNavigationOfTheRightTrip() async throws {
        let env = Env()
        let (first, id) = try await armed(env, earlier: 60)
        try await first.setReminder(forJourney: 1, earlierMinutes: 0, warnMinutes: 0)
        env.refresher.set(.success(try delayed(by: 120)))

        // Neuer Prozess: nur Speicher, Keychain und die Fake-Uhr bleiben. Der Sprung kommt, bevor irgendetwas angezeigt wird.
        let f = AppFlow(env.deps())
        #expect(f.routes == nil)
        f.openReminder(id)
        #expect(f.phase == .navigation(0))
        #expect(f.navStep == .approachingFirstStop(vehicle: 1)) // nicht die Wartekarte
        #expect(f.navJourney?.refreshToken == "ZmFrZQ==")
        #expect(f.journey(at: 0)?.legs.first { !$0.isWalk }?.line?.name == "STR 704")
        #expect(f.destination == .place(NavigationFlowTests.stop))
        #expect(f.navWalks.isEmpty == false)
        #expect(f.navGeometry?.legs[0].steps.isEmpty == false)
        await f.waitForWork()
    }

    @Test func jumpWaitsForOnboarding() async throws {
        let env = Env()
        let (_, id) = try await armed(env)
        let f = AppFlow(env.deps(onboarding: nil))
        #expect(f.onboarding == .welcome)
        f.openReminder(id)
        #expect(f.phase == .start)
        await f.finishWelcome(allowLocation: false)
        #expect(f.phase == .navigation(0))
    }

    @Test func missingTripStartsNormally() {
        let env = Env()
        let f = AppFlow(env.deps())
        f.openReminder(UUID())
        #expect(f.phase == .start)
    }

    @Test func tappingFromOtherSheetsClosesThem() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        f.showsReminders = true
        f.reminderJourneyIndex = 0
        f.openReminder(id)
        #expect(!f.showsReminders && f.reminderJourneyIndex == nil)
        #expect(f.phase == .navigation(0))
    }

    @Test func tappingTheRunningTripKeepsProgress() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        f.openReminder(id)
        let started = f.navStartedAt
        env.clock.set("05:10:00")
        f.openReminder(id)
        #expect(f.navStartedAt == started)
    }

    // MARK: System

    @Test func swiftDataRoundTrip() async throws {
        let store = SwiftDataReminders(container: try TransitStore.makeContainer(inMemory: true),
                                       sealer: LocalSealer(secrets: InMemorySecretStore()))
        let env = Env()
        let (f, id) = try await armed(env, earlier: 5, warn: 10)
        var reminder = try #require(f.reminders.rows.first)
        try store.save(reminder)
        #expect(store.all() == [reminder])
        reminder.plan.attemptedAt = iso("05:30:00")
        try store.save(reminder)
        #expect(store.all() == [reminder])
        store.remove(id)
        #expect(store.all().isEmpty)
    }

    @Test func notificationRequestCarriesLevelCategoryAndTrip() async throws {
        let env = Env()
        let (f, id) = try await armed(env, warn: 5)
        let alerts = try #require(f.reminders.rows.first).plan.alerts(tripID: id, now: env.clock.now)
        let requests = alerts.map { SystemNotifier.request(for: $0, now: env.clock.now) }
        #expect(requests.map(\.content.interruptionLevel) == [.active, .timeSensitive])
        #expect(requests.allSatisfy { $0.content.categoryIdentifier == SystemNotifier.category.identifier })
        #expect(requests.allSatisfy { $0.content.userInfo["tripID"] as? String == id.uuidString })
        #expect(requests.map(\.identifier) == alerts.map(\.identifier))
        #expect(SystemNotifier.category.actions.map(\.options) == [.foreground, []])
        // Label "Köln Hbf" ist hier zufaellig auch Haltestelle; ein Favoriten-Label wie "Zuhause" kaeme nur aus dem Request.
        #expect(requests.allSatisfy { !$0.content.body.contains("Mein Standort") })
    }

    /// Hosted: der echte Start hat den Delegate gesetzt, und die optionalen Methoden treffen die Selektoren.
    @Test func appDelegateAnswersNotifications() throws {
        let delegate = try #require(UNUserNotificationCenter.current().delegate as? AppDelegate)
        #expect(delegate.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))))
        #expect(delegate.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))))
    }

    // MARK: Review-Befunde

    final class StepNotifier: ReminderNotifying, @unchecked Sendable {
        let pending = Mutex<[String: ReminderAlert]>([:])
        let failing = Mutex(false)
        nonisolated(unsafe) var afterFirst: (@Sendable () async -> Void)?
        func requestAuthorization() async -> Bool { true }
        func add(_ alerts: [ReminderAlert]) async throws(TransitError) {
            if failing.withLock({ $0 }) { throw .internal }
            for (i, alert) in alerts.enumerated() {
                pending.withLock { $0[alert.identifier] = alert }
                if i == 0, let hook = afterFirst { await hook() }
            }
        }
        func remove(_ identifiers: [String]) { pending.withLock { for id in identifiers { $0[id] = nil } } }
    }

    func armedFlow(_ env: Env, _ notifier: StepNotifier, warn: Int) async throws -> (AppFlow, UUID) {
        var deps = env.deps()
        deps.notifier = notifier
        env.clock.set("05:00:00")
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(NavigationFlowTests.stop)
        await f.waitForWork()
        try await f.setReminder(forJourney: 0, earlierMinutes: 0, warnMinutes: warn)
        return (f, try #require(f.reminders.rows.first).id)
    }

    @Test func pocDelayedTapStaysOnFoot() async throws {
        let env = Env()
        let (first, id) = try await armed(env)
        env.refresher.set(.success(try delayed(by: 1800)))
        env.clock.set("05:45:00")
        await first.reminders.checkDue()
        let plan = try #require(first.reminders.rows.first?.plan)
        #expect(plan.scheduled.firstDeparture == iso("06:38:00"))
        env.clock.set("06:10:00") // nach der alten, vor der neuen Abfahrt
        let f = AppFlow(env.deps())
        f.openReminder(id)
        #expect(f.navStep == .approachingFirstStop(vehicle: 1))
    }

    @Test func pocFailedUpdateKeepsOldReminder() async throws {
        let env = Env()
        let n = StepNotifier()
        let (f, id) = try await armedFlow(env, n, warn: 5)
        n.failing.withLock { $0 = true }
        await #expect(throws: TransitError.internal) { try await f.setReminder(forJourney: 0, earlierMinutes: 10, warnMinutes: 5) }
        #expect(f.reminders.rows.map(\.id) == [id])
        #expect(env.store.all().count == 1)
        #expect(try env.secrets.read(.refreshToken(tripID: id)) != nil)
    }

    @Test func pocDeleteDuringAddLeavesNoAlert() async throws {
        let env = Env()
        let n = StepNotifier()
        let (f, id) = try await armedFlow(env, n, warn: 5)
        env.refresher.set(.success(try delayed(by: 300)))
        env.clock.set("05:35:00")
        let reminders = f.reminders
        n.afterFirst = { await MainActor.run { reminders.delete(id) } }
        await f.reminders.checkDue()
        #expect(f.reminders.rows.isEmpty)
        #expect(n.pending.withLock { $0.isEmpty })
    }

    @Test func pocUpdateKeepsNewRequest() async throws {
        let store = SwiftDataReminders(container: try TransitStore.makeContainer(inMemory: true),
                                       sealer: LocalSealer(secrets: InMemorySecretStore()))
        let env = Env()
        let (f, _) = try await armed(env)
        var reminder = try #require(f.reminders.rows.first)
        try store.save(reminder)
        reminder.request = ManualTripRequest(origin: .stop(id: "x", label: "X"), destination: .stop(id: "y", label: "Neu"), targetTime: iso("05:00:00"))
        try store.save(reminder)
        #expect(store.all().first?.request.destination.label == "Neu")
    }

    /// Gleicher Ablauf wie oben bis zum Hinweis; `start` waehlt danach aus den neuen Verbindungen.
    func lostAndSearched(_ env: Env) async throws -> (AppFlow, UUID) {
        let (f, id) = try await armed(env, warn: 5)
        f.send(.back)
        f.send(.back)
        env.refresher.set(.success(try changed { $0["cancelled"] = true }))
        env.clock.set("05:35:00")
        await f.reminders.checkDue()
        f.nextConnection(for: try #require(f.reminders.lost))
        await f.waitForWork()
        return (f, id)
    }

    @Test func startingAnotherConnectionEndsTheLostAlarm() async throws {
        let env = Env()
        let (f, id) = try await lostAndSearched(env)
        f.send(.startNavigation(1))
        #expect(f.reminders.rows.isEmpty && env.store.all().isEmpty && env.notifier.alerts.isEmpty)
        #expect(try env.secrets.read(.refreshToken(tripID: id)) == nil)
    }

    @Test func armingAnotherConnectionEndsTheLostAlarm() async throws {
        let env = Env()
        let (f, id) = try await lostAndSearched(env)
        try await f.setReminder(forJourney: 1, earlierMinutes: 0, warnMinutes: 0)
        #expect(f.reminders.rows.map(\.id) != [id] && f.reminders.rows.count == 1)
        #expect(env.notifier.alerts.allSatisfy { $0.tripID != id })
    }

    @Test func sameTripOrAbandonedSearchKeepsTheAlarm() async throws {
        let env = Env()
        let (f, _) = try await lostAndSearched(env)
        f.send(.startNavigation(0))
        #expect(f.reminders.rows.count == 1)

        let other = Env()
        let (g, _) = try await lostAndSearched(other)
        g.send(.back) // Suche verlassen
        g.send(.planTapped)
        await g.waitForWork()
        g.send(.startNavigation(1))
        #expect(g.reminders.rows.count == 1)
    }

    /// Antwort der ersten Fahrt kommt, nachdem schon die zweite laeuft: sie darf nichts ueberschreiben.
    @Test func lateRefreshOfTheOldTripIsIgnored() async throws {
        let env = Env()
        let (planned, first) = try await armed(env)
        try await planned.setReminder(forJourney: 1, earlierMinutes: 0, warnMinutes: 0)
        let second = try #require(planned.reminders.rows.first { $0.id != first }).id
        let (gate, release) = AsyncStream<Void>.makeStream()
        var deps = env.deps()
        deps.refresh = { token throws(TransitError) in
            if token == "ZmFrZQ==" { for await _ in gate { break } }
            guard let journey = FakeData.routes?.journeys.first(where: { $0.refreshToken == token }) else { throw .internal }
            return journey
        }
        let f = AppFlow(deps)
        f.openReminder(first)
        f.openReminder(second)
        release.yield()
        for _ in 0..<20 { await Task.yield() }
        #expect(f.navJourney?.refreshToken == "ZmFrZTI=")
    }

    @Test func replacingDropsPendingSnooze() async throws {
        let env = Env()
        let (f, id) = try await armed(env, earlier: 10)
        let leave = try #require(f.reminders.rows.first?.plan.leaveAt)
        env.clock.value.withLock { $0 = leave.addingTimeInterval(60) }
        await f.reminders.snooze(id)
        #expect(env.notifier.alerts.contains { $0.kind == .snooze })
        env.refresher.set(.success(try delayed(by: 300)))
        await f.reminders.checkDue()
        // Neuer Stand, neuer Text: der Snooze wuerde das Alte sagen, T-0 traegt die Information.
        #expect(!env.notifier.alerts.contains { $0.kind == .snooze })
        #expect(env.notifier.alerts.map(\.kind) == [.leave])
    }

    @Test func listShowsLiveTimesWithOriginalGeometry() async throws {
        let env = Env()
        let (first, id) = try await armed(env)
        env.refresher.set(.success(try delayed(by: 300)))
        env.clock.set("05:45:00")
        await first.reminders.checkDue()
        let live = try #require(first.reminders.rows.first?.plan.live)
        let f = AppFlow(env.deps())
        f.openReminder(id)
        let shown = try #require(f.journey(at: 0))
        #expect(shown.legs[1].departure == live.legs[1].departure)
        #expect(shown.legs[0].steps.isEmpty == false)
        #expect(shown.refreshToken == "ZmFrZQ==")
    }

    @Test func pastWarningShowsTheLeaveTime() async throws {
        let env = Env()
        let (f, _) = try await armed(env, warn: 5)
        let plan = try #require(f.reminders.rows.first?.plan)
        #expect(f.reminderTime(forJourney: 0) == plan.firstAlarm)
        env.clock.value.withLock { $0 = plan.firstAlarm.addingTimeInterval(1) }
        #expect(f.reminderTime(forJourney: 0) == plan.leaveAt)
    }

    /// Suche startet nicht (hier: Start = Ziel, ohne Standort): nichts vormerken, eine spaetere Fahrt beendet keinen Wecker.
    @Test func blockedSearchDoesNotMarkTheReminderAsReplaced() async throws {
        let env = Env()
        let denied = Mutex(false)
        var deps = env.deps()
        deps.authorization = { denied.withLock { $0 } ? .denied : .allowed }
        env.clock.set("05:00:00")
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(NavigationFlowTests.stop)
        await f.waitForWork()
        try await f.setReminder(forJourney: 0, earlierMinutes: 0, warnMinutes: 0)
        var blocked = try #require(f.reminders.rows.first)
        blocked.request.origin = blocked.request.destination
        denied.withLock { $0 = true }
        f.becameActive()
        await f.waitForReminderCheck()
        #expect(f.phase == .routeSelection)
        f.nextConnection(for: blocked)
        #expect(!f.isPlanning)
        f.send(.startNavigation(1))
        #expect(f.reminders.reminder(id: blocked.id) != nil)
    }

    @Test func staleKindsLeaveAfterASuccessfulAdd() async throws {
        let env = Env()
        let (f, _) = try await armed(env, warn: 5)
        // Vorwarnung liegt nach der Verschiebung nach vorn in der Vergangenheit: sie geht, T-0 bleibt
        env.clock.set("05:58:30")
        env.refresher.set(.success(try delayed(by: -60)))
        await f.reminders.checkDue()
        #expect(env.notifier.alerts.map(\.kind) == [.leave])
    }

    @Test func snoozeAfterDeleteLeavesNoAlert() async throws {
        let env = Env()
        let n = StepNotifier()
        let (f, id) = try await armedFlow(env, n, warn: 0)
        let reminders = f.reminders
        n.afterFirst = { await MainActor.run { reminders.delete(id) } }
        await f.reminders.snooze(id)
        #expect(n.pending.withLock { $0.isEmpty })
    }

    @Test func failedUndoCleansUpAndShowsBanner() async throws {
        let env = Env()
        let (f, id) = try await armed(env, warn: 5)
        f.reminders.delete(id)
        env.store.failing.withLock { $0 = true }
        await f.reminders.undoDelete()
        #expect(f.reminders.failure == .storageUnavailable)
        #expect(f.reminders.rows.isEmpty && env.notifier.alerts.isEmpty)
        #expect(try env.secrets.read(.refreshToken(tripID: id)) == nil)
    }

    @Test func volatileStoreRefusesToArm() async throws {
        let env = Env()
        var deps = env.deps()
        deps.reminders = MemoryReminders(isDurable: false)
        env.clock.set("05:00:00")
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(NavigationFlowTests.stop)
        await f.waitForWork()
        await #expect(throws: TransitError.storageUnavailable) { try await f.setReminder(forJourney: 0, earlierMinutes: 0, warnMinutes: 0) }
        #expect(f.reminders.rows.isEmpty && env.notifier.alerts.isEmpty)
    }

    @Test func unreadableRowsLeaveWithTokenAndAlerts() async throws {
        let env = Env()
        let (f, id) = try await armed(env, warn: 5)
        let reminder = try #require(f.reminders.rows.first)
        let container = try TransitStore.makeContainer(inMemory: true)
        // Mit anderem Schluessel versiegelt: endgueltig unlesbar
        try SwiftDataReminders(container: container, sealer: LocalSealer(secrets: InMemorySecretStore())).save(reminder)
        var deps = env.deps()
        deps.reminders = SwiftDataReminders(container: container, sealer: LocalSealer(secrets: InMemorySecretStore()))
        let fresh = ReminderCenter(deps)
        #expect(fresh.rows.isEmpty)
        #expect(try env.secrets.read(.refreshToken(tripID: id)) == nil)
        #expect(env.notifier.alerts.isEmpty)
    }

    /// Keychain gerade nicht lesbar (z. B. vor dem ersten Entsperren): nichts wegwerfen.
    @Test func keychainHiccupKeepsRows() async throws {
        struct Locked: SecretStore {
            func read(_ key: SecretKey) throws(TransitError) -> Data? { throw .keychainFailure }
            func write(_ data: Data, for key: SecretKey) throws(TransitError) { throw .keychainFailure }
            func delete(_ key: SecretKey) throws(TransitError) {}
        }
        let env = Env()
        let (f, _) = try await armed(env)
        let reminder = try #require(f.reminders.rows.first)
        let container = try TransitStore.makeContainer(inMemory: true)
        let secrets = InMemorySecretStore()
        try SwiftDataReminders(container: container, sealer: LocalSealer(secrets: secrets)).save(reminder)
        #expect(SwiftDataReminders(container: container, sealer: LocalSealer(secrets: Locked())).removeUnreadable().isEmpty)
        #expect(SwiftDataReminders(container: container, sealer: LocalSealer(secrets: secrets)).all().count == 1)
    }

    // MARK: Re-Review-Befunde

    final class PocNotifier: ReminderNotifying, @unchecked Sendable {
        let pending = Mutex<[String: ReminderAlert]>([:])
        let failing = Mutex(false)
        let failAtSecond = Mutex(false)
        nonisolated(unsafe) var afterFirst: (@Sendable () async -> Void)?
        func requestAuthorization() async -> Bool { true }
        func add(_ alerts: [ReminderAlert]) async throws(TransitError) {
            if failing.withLock({ $0 }) { throw .internal }
            for (i, alert) in alerts.enumerated() {
                if i == 1, failAtSecond.withLock({ $0 }) { throw .internal }
                pending.withLock { $0[alert.identifier] = alert }
                if i == 0, let hook = afterFirst { await hook() }
            }
        }
        func remove(_ identifiers: [String]) { pending.withLock { for id in identifiers { $0[id] = nil } } }
    }

    func pocFlow(_ env: Env, _ n: PocNotifier, warn: Int) async throws -> (AppFlow, UUID) {
        var deps = env.deps()
        deps.notifier = n
        env.clock.set("05:00:00")
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(NavigationFlowTests.stop)
        await f.waitForWork()
        try await f.setReminder(forJourney: 0, earlierMinutes: 0, warnMinutes: warn)
        return (f, try #require(f.reminders.rows.first).id)
    }

    @Test func poc1DelayedTap() async throws {
        let env = Env()
        let (first, id) = try await armed(env)
        env.refresher.set(.success(try delayed(by: 1800)))
        env.clock.set("05:45:00")
        await first.reminders.checkDue()
        env.clock.set("06:10:00")
        let f = AppFlow(env.deps())
        f.openReminder(id)
        #expect(f.navStep == .approachingFirstStop(vehicle: 1))
        #expect(f.navGeometry?.legs[0].steps.isEmpty == false)
    }

    @Test func poc2FailedUpdate() async throws {
        let env = Env(); let n = PocNotifier()
        let (f, id) = try await pocFlow(env, n, warn: 5)
        n.failing.withLock { $0 = true }
        await #expect(throws: TransitError.internal) { try await f.setReminder(forJourney: 0, earlierMinutes: 10, warnMinutes: 5) }
        #expect(f.reminders.rows.map(\.id) == [id] && env.store.all().count == 1)
        #expect(try env.secrets.read(.refreshToken(tripID: id)) != nil)
        #expect(n.pending.withLock { $0.count } == 2)
    }

    @Test func poc3DeleteDuringAdd() async throws {
        let env = Env(); let n = PocNotifier()
        let (f, id) = try await pocFlow(env, n, warn: 5)
        env.refresher.set(.success(try delayed(by: 300)))
        env.clock.set("05:35:00")
        let r = f.reminders
        n.afterFirst = { await MainActor.run { r.delete(id) } }
        await f.reminders.checkDue()
        #expect(f.reminders.rows.isEmpty)
        #expect(n.pending.withLock { $0.isEmpty })
    }

    @Test func poc4Request() async throws {
        let store = SwiftDataReminders(container: try TransitStore.makeContainer(inMemory: true), sealer: LocalSealer(secrets: InMemorySecretStore()))
        let env = Env()
        let (f, _) = try await armed(env)
        var reminder = try #require(f.reminders.rows.first)
        try store.save(reminder)
        reminder.request = ManualTripRequest(origin: .stop(id: "x", label: "X"), destination: .stop(id: "y", label: "Neu"), targetTime: iso("05:00:00"))
        try store.save(reminder)
        #expect(store.all().first?.request.destination.label == "Neu")
    }

    /// Laufender Snooze nach Ausfall: Text darf nicht mehr "Jetzt losgehen" sagen.
    @Test func poc5SnoozeAfterLost() async throws {
        let env = Env(); let n = PocNotifier()
        let (f, id) = try await pocFlow(env, n, warn: 0)
        let plan = try #require(f.reminders.rows.first?.plan)
        env.clock.value.withLock { $0 = plan.leaveAt }
        await f.reminders.snooze(id)
        #expect(n.pending.withLock { $0[ReminderAlert.identifier(id, .snooze)] } != nil)
        env.refresher.set(.success(try changed { $0["cancelled"] = true }))
        await f.reminders.checkDue()
        #expect(f.reminders.rows.first?.plan.status == .lost)
        let snooze = n.pending.withLock { $0[ReminderAlert.identifier(id, .snooze)] }
        #expect(snooze == nil || snooze?.title == "Verbindung fällt aus")
    }

    /// Sprung in eine andere Erinnerung beendet den "Nächste Verbindung"-Kontext.
    @Test func poc6ResumeClearsReplaced() async throws {
        let env = Env()
        let (f, r1) = try await armed(env)
        try await f.setReminder(forJourney: 1, earlierMinutes: 0, warnMinutes: 0)
        let r2 = try #require(f.reminders.rows.first { $0.id != r1 }).id
        env.refresher.set(.success(try changed { $0["cancelled"] = true }))
        env.clock.set("05:35:00")
        await f.reminders.checkDue()
        let lost = try #require(f.reminders.reminder(id: r1))
        f.send(.back); f.send(.back)
        f.nextConnection(for: lost)
        await f.waitForWork()
        f.openReminder(r2)
        #expect(f.phase == .navigation(0))
        f.send(.back)
        f.send(.startNavigation(0))
        #expect(f.reminders.reminder(id: r1) != nil)
    }

    /// "Nächste Verbindung" aus der Navigation der Erinnerungsfahrt: andere Fahrt starten beendet den alten Wecker.
    @Test func poc7ReplanInNavigation() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        f.openReminder(id)
        #expect(f.phase == .navigation(0))
        f.nextConnection()
        await f.waitForWork()
        #expect(f.phase == .routeSelection)
        let other = try #require(f.routes?.journeys.indices.first { i in f.journey(at: i).map { !$0.isSameTrip(as: f.reminders.reminder(id: id)?.plan.calibrated.journey ?? $0) } ?? false })
        f.send(.startNavigation(other))
        #expect(f.reminders.reminder(id: id) == nil)
    }

    /// Teilweises add beim Aendern: keine Mitteilung des verworfenen Stands bleibt.
    @Test func poc8PartialAddRestoresOld() async throws {
        let env = Env(); let n = PocNotifier()
        let (f, id) = try await pocFlow(env, n, warn: 0)
        n.failAtSecond.withLock { $0 = true }
        await #expect(throws: TransitError.internal) { try await f.setReminder(forJourney: 0, earlierMinutes: 0, warnMinutes: 5) }
        n.failAtSecond.withLock { $0 = false }
        #expect(n.pending.withLock { $0[ReminderAlert.identifier(id, .warn)] } == nil)
    }

    /// Banner aus Rueckgaengig bleibt nicht fuer immer.
    @Test func poc9FailureClears() async throws {
        let env = Env()
        let (f, id) = try await armed(env)
        f.reminders.delete(id)
        env.store.failing.withLock { $0 = true }
        await f.reminders.undoDelete()
        #expect(f.reminders.failure == .storageUnavailable)
        env.store.failing.withLock { $0 = false }
        try await f.setReminder(forJourney: 0, earlierMinutes: 0, warnMinutes: 0)
        #expect(f.reminders.failure == nil)
    }
}
#endif
