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

        func deps(onboarding: OnboardingChoice? = .withLocation, blockedUntil: Date? = nil) -> AppDependencies {
            var deps = AppDependencies.fakes(secrets: secrets, onboarding: onboarding, blockedUntil: blockedUntil,
                                             debounce: .milliseconds(10), refresher: refresher, reminders: store, notifier: notifier)
            deps.now = { self.clock.now }
            deps.undoWindow = .milliseconds(30)
            deps.scheduleBackgroundCheck = { date in self.checks.withLock { $0.append(date) } }
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
