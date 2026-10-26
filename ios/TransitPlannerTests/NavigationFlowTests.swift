#if DEBUG
import Foundation
import Synchronization
import Testing
import TransitCore
@testable import TransitPlanner

private func iso(_ time: String) -> Date {
    (try? Date.ISO8601FormatStyle().parse("2026-10-24T\(time)Z")) ?? .distantPast
}

/// Fake-Verbindung 0: Fussweg > STR 704 (06:08, Gleis 2 statt 1) > Umstieg > SEV RE 5 (06:23-06:38) > Fussweg.
@MainActor @Suite struct NavigationFlowTests {
    static let hbf = GeoCoordinate(latitude: 51.21996, longitude: 6.79432)
    static let bilkBus = GeoCoordinate(latitude: 51.2049, longitude: 6.7761)
    static let destination = GeoCoordinate(latitude: 50.9413, longitude: 6.9583)
    static let stop = TripEndpoint.stop(id: "de-DELFI_de:05315:11201", label: "Köln Hbf")

    final class Clock: Sendable {
        let value = Mutex(iso("06:01:00"))
        func set(_ time: String) { value.withLock { $0 = iso(time) } }
        var now: Date { value.withLock { $0 } }
    }

    func navigatingFlow(clock: Clock, planner: FakeRoutePlanner = FakeRoutePlanner(), refresher: FakeRefresher = FakeRefresher(),
                        blockedUntil: Date? = nil,
                        positions: (@Sendable () -> AsyncStream<LocationFix>)? = nil) async -> AppFlow {
        var deps = AppDependencies.fakes(planner: planner, onboarding: .withLocation, blockedUntil: blockedUntil,
                                         debounce: .milliseconds(10), refresher: refresher)
        deps.now = { clock.now }
        if let positions { deps.positions = positions }
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(Self.stop)
        await f.waitForWork()
        f.send(.startNavigation(0))
        return f
    }

    func card(_ f: AppFlow) throws -> NowCard {
        NavigationPresenter.card(try #require(f.navInput))
    }

    @Test func walkThroughAllStates() async throws {
        let clock = Clock()
        let f = await navigatingFlow(clock: clock)
        #expect(f.phase == .navigation(0))
        #expect(f.navStep == .approachingFirstStop(vehicle: 1))
        #expect(f.navWarnings == 1) // Gleiswechsel schon beim Start
        var c = try card(f)
        #expect(c.variant == .walk && c.eyebrow == "Zu Fuß zum Gleis")
        #expect(c.metrics.map(\.label) == ["Abfahrt", "Noch", "Puffer"])

        clock.set("06:05:00")
        f.navigationUpdate(position: Self.hbf, now: clock.now)
        #expect(f.navStep == .waitingAtPlatform(vehicle: 1))
        c = try card(f)
        #expect(c.eyebrow == "Am Gleis" && c.headline == "Gleis 2")
        // DESIGN.md 4b: eine Meldung (hier Umleitung) ersetzt den Gleis-Hinweis, mit "Nächste Verbindung"
        #expect(c.hint?.text == "Meldung des Betreibers: Umleitung")
        #expect(c.hint?.action == .nextConnection)
        #expect(c.metrics.map(\.label) == ["Abfahrt", "Noch", "Fahrt"])

        clock.set("06:12:00")
        f.navigationUpdate(position: nil, now: clock.now)
        c = try card(f)
        #expect(c.variant == .onBoard && c.headline == "Nächster Halt aussteigen")
        #expect(c.eyebrow == "Im STR 704 Richtung Derendorf")
        #expect(c.metrics.map(\.label) == ["Ankunft", "Noch", "Danach"])

        clock.set("06:17:00")
        f.navigationUpdate(position: nil, now: clock.now)
        c = try card(f)
        #expect(c.variant == .transfer && c.headline == "Bilk S → Bilk S Bus")
        #expect(c.eyebrow == "Umstieg in SEV RE 5")
        #expect(NavigationPresenter.spoken(c).contains("Bilk S nach Bilk S Bus"))
        #expect(c.context.contains("ca. 90 m"))

        clock.set("06:21:00")
        f.navigationUpdate(position: Self.bilkBus, now: clock.now)
        c = try card(f)
        #expect(c.variant == .replacement)
        #expect(c.eyebrow == "Ersatzverkehr statt RE 5" && c.headline == "Bus ab Bilk S Bus")

        clock.set("06:43:00")
        f.navigationUpdate(position: Self.destination, now: clock.now)
        #expect(f.phase == .arrival)
        #expect(f.navPosition == nil) // Live-Standort mit der Ankunft verworfen
        c = try card(f)
        #expect(c.variant == .arrived && c.headline == "Köln Hbf")
        #expect(c.metrics.map(\.label) == ["Unterwegs", "Zu Fuß", "Verspätung"])
        #expect(c.metrics.first?.value == .minutes(42))

        f.send(.reset)
        #expect(f.navPosition == nil && f.navJourney == nil && f.navStep == nil)
    }

    @Test func bufferWarningOnlyOncePerVehicleAndMissedOffersNextConnection() async throws {
        let clock = Clock()
        let f = await navigatingFlow(clock: clock)
        let start = f.navWarnings
        clock.set("06:06:30") // 90 s bis Abfahrt, Fussweg noch weit
        f.navigationUpdate(position: GeoCoordinate(latitude: 51.2201, longitude: 6.7905), now: clock.now)
        #expect(f.navWarnings == start + 1)
        f.navigationUpdate(position: nil, now: clock.now)
        #expect(f.navWarnings == start + 1)
        let c = try card(f)
        #expect(c.hint?.action == .nextConnection)
        guard case .buffer(_, let status) = c.metrics[2].value else { Issue.record("kein Puffer"); return }
        #expect(status == .missed)
    }

    @Test func refreshErrorsKeepLastStateAndExpiredOffersNextConnection() async throws {
        let clock = Clock()
        let refresher = FakeRefresher()
        let f = await navigatingFlow(clock: clock, refresher: refresher)
        await f.refreshNavigation()
        #expect(refresher.callCount == 1 && !f.navIsStale)

        refresher.set(.failure(.offline))
        await f.refreshNavigation()
        #expect(f.navIsStale)
        #expect(f.banner == .offline)
        #expect(f.navJourney != nil) // letzter Stand bleibt

        refresher.set(.failure(.refreshExpired))
        await f.refreshNavigation()
        #expect(f.navExpired)
        #expect(try card(f).hint?.action == .nextConnection)
    }

    @Test func nextConnectionReplansFromHereNow() async {
        let clock = Clock()
        let planner = FakeRoutePlanner()
        let f = await navigatingFlow(clock: clock, planner: planner)
        f.nextConnection()
        await f.waitForWork()
        #expect(f.phase == .routeSelection)
        #expect(f.origin == .currentLocation)
        #expect(planner.callCount == 2)
        #expect(f.navJourney == nil && f.navPosition == nil)
    }

    @Test func endingNavigationDropsLiveLocation() async {
        let clock = Clock()
        let f = await navigatingFlow(clock: clock)
        f.navigationUpdate(position: Self.hbf, now: clock.now)
        #expect(f.navPosition != nil)
        f.send(.back)
        #expect(f.phase == .tripDetails(0))
        #expect(f.navPosition == nil && f.navStep == nil)
    }

    @Test func livePositionsDriveTheState() async throws {
        let clock = Clock()
        clock.set("06:05:00")
        let fix = LocationFix(coordinate: Self.hbf, horizontalAccuracy: 5, timestamp: Date())
        let f = await navigatingFlow(clock: clock, positions: { AsyncStream { $0.yield(fix) } })
        for _ in 0..<20 where f.navStep != .waitingAtPlatform(vehicle: 1) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(f.navStep == .waitingAtPlatform(vehicle: 1))
        #expect(f.navPosition == Self.hbf)
    }

    /// Haenger der Screenshot-Tour / Akku: Ticks in derselben Minute und GPS-Rauschen aendern keinen beobachteten Wert.
    @Test func ticksAndNoiseDoNotRedraw() async throws {
        let clock = Clock()
        let f = await navigatingFlow(clock: clock)
        let start = GeoCoordinate(latitude: 51.2201, longitude: 6.7905)
        f.navigationUpdate(position: start, now: clock.now)
        let shownNow = f.navNow
        clock.set("06:01:30")
        f.navigationUpdate(position: GeoCoordinate(latitude: 51.22011, longitude: 6.7905), now: clock.now) // ca. 1 m
        #expect(f.navNow == shownNow)
        #expect(f.navPosition == start)
        clock.set("06:02:00")
        f.navigationUpdate(position: nil, now: clock.now)
        #expect(f.navNow == clock.now)
        // Knapper Puffer zaehlt Sekunden: dann jede Auswertung sichtbar
        clock.set("06:06:10")
        f.navigationUpdate(position: nil, now: clock.now)
        clock.set("06:06:15")
        f.navigationUpdate(position: nil, now: clock.now)
        #expect(f.navNow == clock.now)
    }

    /// Ohne Erlaubnis (.notDetermined) kein Standort-Stream: er wuerde den System-Dialog ausloesen. Navigation nur nach Zeit.
    func notAllowedFlow(clock: Clock, positions: (@Sendable () -> AsyncStream<LocationFix>)? = nil) async -> AppFlow {
        var deps = AppDependencies.fakes(location: FakeLocation(status: .notDetermined), onboarding: .withoutLocation,
                                         debounce: .milliseconds(10))
        deps.now = { clock.now }
        if let positions { deps.positions = positions }
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(Self.stop)
        f.send(.editEndpoint(.origin))
        f.choose(.stop(id: "de-DELFI_de:05111:18235", label: "Düsseldorf Hbf"))
        f.send(.planTapped)
        await f.waitForWork()
        f.send(.startNavigation(0))
        return f
    }

    @Test func withoutLocationPermissionNoPositionStream() async throws {
        let clock = Clock()
        let calls = Mutex(0)
        let f = await notAllowedFlow(clock: clock, positions: { calls.withLock { $0 += 1 }; return AsyncStream { _ in } })
        #expect(f.phase == .navigation(0))
        #expect(f.navStep == .approachingFirstStop(vehicle: 1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.withLock { $0 } == 0)
    }

    /// Abfahrt vorbei, Position weit vom Halt, nie am Gleis: Anschluss verpasst, naechste Verbindung anbieten.
    @Test func missedDepartureOffersNextConnection() async throws {
        let clock = Clock()
        let f = await navigatingFlow(clock: clock)
        clock.set("06:09:00")
        f.navigationUpdate(position: GeoCoordinate(latitude: 51.2201, longitude: 6.7905), accuracy: 8, now: clock.now)
        #expect(f.navStep == .missedDeparture(vehicle: 1))
        var c = try card(f)
        #expect(c.variant == .walk)
        #expect(c.hint?.action == .nextConnection)
        guard case .buffer(_, let status) = c.metrics[2].value else { Issue.record("kein Puffer"); return }
        #expect(status == .missed)
        // Bleibt nach der Ankunftszeit des verpassten Fahrzeugs (06:18) bis zum Neuplanen
        clock.set("06:19:00")
        f.navigationUpdate(position: nil, now: clock.now)
        #expect(f.navStep == .missedDeparture(vehicle: 1))
        c = try card(f)
        #expect(c.hint?.action == .nextConnection)
    }

    /// Veralteter Fix (U-Bahn): nicht "verpasst", sondern nach Fahrplanzeit im Fahrzeug.
    @Test func staleFixDoesNotMarkMissed() async {
        let clock = Clock()
        let f = await navigatingFlow(clock: clock)
        f.navigationUpdate(position: GeoCoordinate(latitude: 51.2201, longitude: 6.7905), now: clock.now) // 06:01
        clock.set("06:09:00")
        f.navigationUpdate(position: nil, now: clock.now)
        #expect(f.navStep == .onBoardTransit(vehicle: 1))
    }

    /// Ohne Standorterlaubnis plant "Nächste Verbindung" ab dem Halt des Zielfahrzeugs, nicht ab dem alten Start.
    @Test func nextConnectionWithoutLocationStartsAtTargetStop() async throws {
        let clock = Clock()
        let f = await notAllowedFlow(clock: clock)
        clock.set("06:20:00")
        f.navigationUpdate(position: nil, now: clock.now)
        #expect(f.navStep == .transferRouting(from: 1, to: 3))
        let stop = try #require(f.navJourney?.legs.first { $0.index == 3 }?.origin)
        let id = try #require(stop.id)
        f.nextConnection()
        await f.waitForWork()
        #expect(f.origin == .place(.stop(id: id, label: stop.name ?? id)))
        #expect(f.phase == .routeSelection)
    }

    @Test func rateLimitPausesPolling() async {
        let clock = Clock()
        let refresher = FakeRefresher()
        let f = await navigatingFlow(clock: clock, refresher: refresher, blockedUntil: iso("06:03:00"))
        refresher.set(.failure(.rateLimited))
        await f.refreshNavigation()
        #expect(f.banner == .rateLimited && f.navIsStale)
        await f.refreshNavigation()
        #expect(refresher.callCount == 1) // kein Haemmern waehrend Retry-After
    }

    @Test func platformChangeDetection() throws {
        let journeys = try #require(FakeData.routes?.journeys)
        #expect(!AppFlow.platformChanged(from: journeys[0], to: journeys[0]))
        // Leg 1: Gleis 9 -> Gleis 2
        #expect(AppFlow.platformChanged(from: journeys[1], to: journeys[0]))
    }

    @Test func refreshIntervalSpeedsUpBeforeTransfer() async {
        let clock = Clock()
        let f = await navigatingFlow(clock: clock)
        #expect(f.refreshInterval == .seconds(60))
        clock.set("06:14:00") // im Fahrzeug, Ankunft 06:18 mit folgendem Umstieg
        f.navigationUpdate(position: nil, now: clock.now)
        #expect(f.refreshInterval == .seconds(20))
    }
}

@Suite struct NavigationPresenterTests {
    @Test func instructionsFromSteps() throws {
        func step(_ json: String) throws -> Step { try TransitJSON.decoder().decode(Step.self, from: Data(json.utf8)) }
        let stairs = try step(#"{"direction":"stairs","distanceMeters":20,"fromLevel":0,"toLevel":1}"#)
        let left = try step(#"{"direction":"left","distanceMeters":30}"#)
        #expect(NavigationPresenter.instruction(WalkGuidance(nextStep: stairs, metersToNextStep: 80, remainingMeters: 200),
                                                target: "Hbf") == "In 80 m Treppe hoch")
        #expect(NavigationPresenter.instruction(WalkGuidance(nextStep: left, metersToNextStep: 40, remainingMeters: 200),
                                                target: "Hbf") == "In 40 m links")
        #expect(NavigationPresenter.instruction(WalkGuidance(nextStep: nil, metersToNextStep: nil, remainingMeters: 120),
                                                target: "Hbf") == "Noch 120 m zu Hbf")
        #expect(NavigationPresenter.instruction(WalkGuidance(nextStep: nil, metersToNextStep: nil, remainingMeters: nil),
                                                target: "Hbf") == "Zu Hbf")
    }

    @Test func stepTitlesAreCalmForStraightAndClearForTurns() {
        #expect(NavigationPresenter.stepTitle(Step(direction: .depart, distanceMeters: 640, streetName: "Hüttenstraße"))
                == "Hüttenstraße folgen")
        #expect(NavigationPresenter.stepTitle(Step(direction: .continue, distanceMeters: 40)) == "Geradeaus")
        #expect(NavigationPresenter.stepTitle(Step(direction: .right, distanceMeters: 40, streetName: "Bahnhofstraße"))
                == "Rechts abbiegen in Bahnhofstraße")
        #expect(NavigationPresenter.stepTitle(Step(direction: .stairs, distanceMeters: 20, fromLevel: 1, toLevel: 0))
                == "Treppe runter")
        #expect(NavigationPresenter.stepTitle(Step(direction: .unknown, distanceMeters: 12, fromLevel: 0, toLevel: 0.5))
                == "Ebene hoch")
    }

    @Test func spokenBufferUsesSecondsBelowTwoMinutes() {
        func spoken(_ seconds: Int) -> String {
            NavigationPresenter.spoken(NowCard(variant: .walk, eyebrow: "Zu Fuß zum Gleis", headline: "Zu Hbf", context: "",
                                               metrics: [NowCard.Metric(label: "Puffer", value: .buffer(seconds: seconds, status: .tight))]))
        }
        #expect(spoken(75).contains("Puffer 75 Sekunden"))
        #expect(spoken(180).contains("Puffer 3 Minuten"))
    }

    /// Ohne Indoor-Daten nur die Laenge, nichts erfunden.
    @Test func transferSummaryUsesOnlyGivenData() throws {
        let legs = try #require(FakeData.routes?.journeys.first?.legs)
        #expect(NavigationPresenter.walkSummary(legs[2]) == "Treppe runter, ca. 90 m")
        #expect(NavigationPresenter.walkSummary(legs[4]) == "ca. 200 m")
    }
}
#endif
