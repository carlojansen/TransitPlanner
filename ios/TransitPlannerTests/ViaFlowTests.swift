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
    }

    /// Block "Aufenthalt": echte Dauer bis zum naechsten Fahrzeug; kuerzer als gewuenscht = Warnhinweis.
    @Test func stayShowsRealDurationAndWarnsWhenShort() throws {
        let journey = try #require(FakeData.routes?.journeys.first)
        // Ankunft Bilk 06:18, Bus ab 06:23
        let short = try #require(journey.viaStays([ViaStop(id: "b", stayMinutes: 15, label: "Bilk S")]).first)
        #expect(short.minutes == 5)
        #expect(short.isShort)
        let fits = try #require(journey.viaStays([ViaStop(id: "b", stayMinutes: 5, label: "Bilk S")]).first)
        #expect(!fits.isShort)
    }
}
#endif
