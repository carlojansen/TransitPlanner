#if DEBUG
import Foundation
import Testing
import TransitCore
@testable import TransitPlanner

/// Zwischenstopps (Stufe A): nur Haltestellen, hoechstens 2, nicht im Verlauf, nur ueber den Fahrt-Request ans Backend.
@MainActor @Suite struct ViaFlowTests {
    static let bilk = TripEndpoint.stop(id: "b", label: "Bilk S")
    static let bilkCoordinate = GeoCoordinate(latitude: 51.2045, longitude: 6.7755)
    static let neuss = TripEndpoint.stop(id: "neuss", label: "Neuss Hbf")

    /// Ergebnisse mit Ziel Koeln Hbf, dann zurueck in Planen (Feld ohne Fokus).
    func planned(_ planner: FakeRoutePlanner, places: MemoryPlaces = MemoryPlaces()) async -> AppFlow {
        let f = AppFlow(.fakes(planner: planner, onboarding: .withLocation, places: places))
        f.send(.editEndpoint(.destination))
        f.choose(AppFlowTests.stopEndpoint)
        await f.waitForWork()
        f.send(.back)
        return f
    }

    @Test func plusAddsStopThatGoesIntoTheTripAndRemoveDeletesIt() async throws {
        let planner = FakeRoutePlanner()
        let places = MemoryPlaces()
        let f = await planned(planner, places: places)
        let recentsBefore = places.recents()

        f.send(.editEndpoint(.via))
        #expect(f.phase == .plan(.via))
        f.choose(Self.bilk, coordinate: Self.bilkCoordinate)
        #expect(f.via == [ViaStop(id: "b", stayMinutes: 15, label: "Bilk S", coordinate: Self.bilkCoordinate)])
        #expect(f.phase == .routeSelection) // wie jede Wahl: sucht sofort
        await f.waitForWork()
        #expect(planner.recordedRequests.last?.via == f.via)
        #expect(places.recents() == recentsBefore) // nie im Verlauf

        // Aufenthalt geaendert: neue Anfrage mit neuem Wert (PlanKey enthaelt via)
        f.send(.back)
        f.setStay(20, at: 0)
        f.send(.planTapped)
        await f.waitForWork()
        #expect(planner.recordedRequests.last?.via?.first?.stayMinutes == 20)

        f.send(.back)
        f.removeVia(at: 0)
        #expect(f.via.isEmpty)
        f.send(.planTapped)
        await f.waitForWork()
        #expect(planner.recordedRequests.last?.via == nil)
    }

    /// Offline nach Aenderung des Stopps: die alte Antwort (ohne Stopp) darf nicht als Offline-Stand erscheinen.
    @Test func offlineDoesNotShowAnswerWithoutTheNewStop() async {
        let planner = FakeRoutePlanner()
        let f = await planned(planner)
        #expect(f.routes != nil)
        planner.setFailure(.offline)
        f.send(.editEndpoint(.via))
        f.choose(Self.bilk, coordinate: Self.bilkCoordinate)
        await f.waitForWork()
        #expect(f.routes == nil)
        #expect(!f.isStale)
    }

    /// Adresse oder "Mein Standort" als Zwischenstopp: abgelehnt, die Suche bleibt offen, nichts geht raus.
    @Test func addressIsRejectedAsStop() async {
        let planner = FakeRoutePlanner()
        let f = await planned(planner)
        let calls = planner.callCount
        f.send(.editEndpoint(.via))
        f.choose(AppFlowTests.addressEndpoint)
        f.useCurrentLocation()
        #expect(f.via.isEmpty)
        #expect(f.phase == .plan(.via))
        // Ziel als Zwischenstopp: Backend lehnt das ab, die App nimmt es gar nicht erst an.
        f.choose(AppFlowTests.stopEndpoint)
        #expect(f.via.isEmpty)
        #expect(f.viaRejections == 2) // Fehler-Haptik je Ablehnung
        #expect(planner.callCount == calls)
    }

    /// Hoechstens 2; Tauschen dreht Von/Nach und die Reihenfolge der Stopps.
    @Test func atMostTwoAndSwapReversesOrder() async {
        let f = await planned(FakeRoutePlanner())
        for stop in [Self.bilk, Self.neuss, TripEndpoint.stop(id: "dritter", label: "Dritter")] {
            f.send(.back)
            f.send(.editEndpoint(.via))
            f.choose(stop)
        }
        #expect(f.via.map(\.id) == ["b", "neuss"])
        f.send(.back)
        f.swapEndpoints()
        #expect(f.via.map(\.id) == ["neuss", "b"])
        #expect(f.destination == .currentLocation)
    }

    /// MOTIS zaehlt den Aufenthalt als Umstieg; die Anzeige nicht. Unerkannter Stopp: normaler Umstieg.
    @Test func transferCountSkipsRecognizedStay() throws {
        let journey = try #require(FakeData.routes?.journeys.first)
        #expect(journey.transfers == 1)
        let stay = ViaStop(id: "b", stayMinutes: 15, label: "Bilk S")
        #expect(journey.transfers(excludingStaysAt: [stay]) == 0)
        #expect(journey.transfers(excludingStaysAt: []) == 1)
        #expect(journey.transfers(excludingStaysAt: [ViaStop(id: "zzz", stayMinutes: 15, label: "x")]) == 1)
        // Stopp am letzten Fahrzeug, danach nur Fussweg: dort zaehlt MOTIS keinen Umstieg, also nichts abziehen.
        #expect(journey.transfers(excludingStaysAt: [ViaStop(id: "de-DELFI_de:05315:11201", stayMinutes: 15, label: "Köln Hbf")]) == 1)
    }

    /// Block "Aufenthalt": Ankunft bis zum Umstiegsweg (der steht darunter eigens), ohne Weg bis zur Abfahrt;
    /// kuerzer als gewuenscht = Warnhinweis. Wie die echte Antwort (routes-via.json: an 11:43, Weg 12:03, ab 12:14 = 20 Min.).
    @Test func stayEndsWhereTheTransferWalkStarts() throws {
        let base = try #require(FakeData.routes?.journeys.first)
        // Ankunft Bilk 06:18, Umstiegsweg ab 06:30 (statt 06:18), Bus ab 06:23 laut Daten
        let journey = try Self.changed(base) { legs in
            if let arrival = legs[1]["arrival"] as? Double { legs[2]["departure"] = arrival + 12 * 60 }
        }
        let short = try #require(journey.viaStays([ViaStop(id: "b", stayMinutes: 15, label: "Bilk S")]).first)
        #expect(short.minutes(in: journey) == 12)
        #expect(short.isShort(in: journey))
        let fits = try #require(journey.viaStays([ViaStop(id: "b", stayMinutes: 10, label: "Bilk S")]).first)
        #expect(!fits.isShort(in: journey))
        // Ohne Umstiegsweg: bis zur Abfahrt (06:23)
        let direct = try Self.changed(base) { legs in legs.remove(at: 2) }
        let stay = try #require(direct.viaStays([ViaStop(id: "b", stayMinutes: 15, label: "Bilk S")]).first)
        #expect(stay.minutes(in: direct) == 5)
    }

    /// Verbindung ueber JSON veraendert (Modelle haben keinen oeffentlichen Init).
    static func changed(_ journey: Journey, _ edit: (inout [[String: Any]]) -> Void) throws -> Journey {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(journey)) as? [String: Any])
        var legs = try #require(object["legs"] as? [[String: Any]])
        edit(&legs)
        object["legs"] = legs
        return try JSONDecoder().decode(Journey.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// Favorit ohne Koordinate: kennt die Umkreissuche die Haltestelle, nimmt der Zwischenstopp deren Koordinate mit.
    @Test func stopWithoutCoordinateTakesItFromNearbyStops() async throws {
        let f = await planned(FakeRoutePlanner())
        f.send(.editEndpoint(.via))
        await f.waitForNearby()
        let dus = try #require(FakeData.stops.first { $0.name == "Düsseldorf Hbf" })
        f.choose(.stop(id: try #require(dus.id), label: "Düsseldorf Hbf"))
        #expect(f.via.first?.coordinate == dus.coordinate)
    }

    // MARK: Unterwegs

    /// Navigation der Fake-Verbindung 0 (Hbf 06:08 > Bilk an 06:18 > Bus ab 06:23 > Koeln Hbf) ueber `stop`.
    func navigating(_ planner: FakeRoutePlanner, clock: NavigationFlowTests.Clock, via stop: TripEndpoint = Self.bilk,
                    coordinate: GeoCoordinate? = Self.bilkCoordinate) async -> AppFlow {
        var deps = AppDependencies.fakes(planner: planner, onboarding: .withLocation, debounce: .milliseconds(10))
        deps.now = { clock.now }
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(NavigationFlowTests.stop)
        await f.waitForWork()
        f.send(.back)
        f.send(.editEndpoint(.via))
        f.choose(stop, coordinate: coordinate)
        await f.waitForWork()
        f.send(.startNavigation(0))
        return f
    }

    @Test func nextConnectionBeforeTheStopKeepsIt() async {
        let clock = NavigationFlowTests.Clock()
        let planner = FakeRoutePlanner()
        let f = await navigating(planner, clock: clock)
        let via = f.via
        f.nextConnection()
        await f.waitForWork()
        #expect(planner.recordedRequests.last?.via == via)
    }

    @Test func nextConnectionAfterTheStopDropsIt() async {
        let clock = NavigationFlowTests.Clock()
        let planner = FakeRoutePlanner()
        let f = await navigating(planner, clock: clock)
        clock.set("06:20:00")
        f.navigationUpdate(position: nil, now: clock.now)
        f.nextConnection()
        await f.waitForWork()
        #expect(planner.recordedRequests.last?.via == nil)
    }

    /// Stopp, den die laufende Fahrt nicht erkennt: unbekannt, ob er noch vor einem liegt; die Folgeverbindung laesst ihn weg,
    /// statt womoeglich zurueck zu einem besuchten Stopp zu schicken.
    @Test func unrecognizedStopIsNotKeptForever() async {
        let clock = NavigationFlowTests.Clock()
        let planner = FakeRoutePlanner()
        let f = await navigating(planner, clock: clock, via: .stop(id: "zzz", label: "Irgendwo"), coordinate: nil)
        #expect(f.via.map(\.id) == ["zzz"])
        f.nextConnection()
        await f.waitForWork()
        #expect(planner.recordedRequests.last?.via == nil)
    }

    /// Alternative nach dem Stopp gewaehlt: der besuchte Stopp kommt nicht ueber "Naechste Verbindung" zurueck.
    @Test func alternativeAfterTheStopDoesNotSendBackToIt() async {
        let clock = NavigationFlowTests.Clock()
        let planner = FakeRoutePlanner()
        let f = await navigating(planner, clock: clock)
        clock.set("06:20:00")
        f.navigationUpdate(position: nil, now: clock.now)
        f.openAlternatives()
        await f.waitForPeek()
        #expect(planner.recordedRequests.last?.via == nil)
        f.chooseAlternative(1) // Direktverbindung, Bilk kommt darin nicht vor
        #expect(f.via.isEmpty)
        f.nextConnection()
        await f.waitForWork()
        #expect(planner.recordedRequests.last?.via == nil)
    }

    /// Alternativen ab der naechsten Station, die der Zwischenstopp selbst ist: der Stopp entfaellt, der Aufenthalt nicht.
    @Test func peekFromTheStopStartsAfterTheStay() async throws {
        let clock = NavigationFlowTests.Clock()
        let planner = FakeRoutePlanner()
        let f = await navigating(planner, clock: clock)
        f.navigationUpdate(position: GeoCoordinate(latitude: 51.2201, longitude: 6.7905), now: clock.now)
        clock.set("06:10:00")
        f.navigationUpdate(position: nil, now: clock.now)
        #expect(f.navStep == .onBoardTransit(vehicle: 1))
        f.openAlternatives(from: .nextStation)
        await f.waitForPeek()
        let request = try #require(planner.recordedRequests.last)
        #expect(request.via == nil)
        #expect(request.origin == TripEndpoint.stop(id: "b", label: "Bilk S").routePoint)
        #expect(request.targetTime == viaTime("06:33:00")) // an 06:18 + 15 Min.
    }

    /// Erinnerung mit Zwischenstopp: der Start aus der Mitteilung laedt den Stopp wieder.
    @Test func reminderRestoresTheStop() async throws {
        let env = ReminderFlowTests.Env()
        env.clock.set("05:00:00")
        let f = AppFlow(env.deps())
        f.send(.editEndpoint(.destination))
        f.choose(NavigationFlowTests.stop)
        await f.waitForWork()
        f.send(.back)
        f.send(.editEndpoint(.via))
        f.choose(Self.bilk, coordinate: Self.bilkCoordinate)
        await f.waitForWork()
        let via = f.via
        try await f.setReminder(forJourney: 0, earlierMinutes: 0, warnMinutes: 0)
        let id = try #require(f.reminders.rows.first).id
        f.send(.back)
        f.removeVia(at: 0)
        f.openReminder(id)
        #expect(f.via == via)
    }
}

private func viaTime(_ time: String) -> Date {
    (try? Date.ISO8601FormatStyle().parse("2026-10-24T\(time)Z")) ?? .distantPast
}
#endif
