#if DEBUG
import Foundation
import Synchronization
import Testing
import TransitCore
@testable import TransitPlanner

/// Restfahrt im Danach-Sheet mit der echten Fahrt Düsseldorf Hbf > Köln Messe/Deutz > Hansaring > Zülpicher Platz > Weyertal.
@MainActor @Suite struct RouteOverviewTests {
    static func at(_ time: String) -> Date {
        (try? Date.ISO8601FormatStyle().parse("2026-10-26T\(time)Z")) ?? .distantPast
    }

    static func journey(iceDelay: Int = 0) throws -> Journey {
        try #require(FakeData.deutz(iceDelay: iceDelay)?.journeys.first)
    }

    static func overview(_ step: NavigationStep, at time: String, journey: Journey? = nil,
                         position: GeoCoordinate? = nil) throws -> RouteOverview {
        let base = try Self.journey()
        return NavigationPresenter.overview(NavigationPresenter.Input(
            step: step, journey: journey ?? base, geometry: base, walks: [:], position: position, now: at(time),
            pace: WalkingPaceFactor(), destinationLabel: "Weyertal 119a", startedAt: nil, expired: false))
    }

    @Test func allStagesWithBuffersAndTightestTransfer() throws {
        let o = try Self.overview(.approachingFirstStop(vehicle: 0), at: "06:55:00")
        #expect(o.rows.map(\.kind) == [.ride, .transfer, .ride, .transfer, .ride, .transfer, .ride, .walk])
        #expect(o.rows.map(\.isCurrent) == [true] + Array(repeating: false, count: 7))
        #expect(o.rows.compactMap(\.buffer).map(\.seconds) == [20, 30, 40])
        #expect(o.rows.compactMap(\.buffer).allSatisfy { $0.status == .tight })
        #expect(o.arrival == Self.at("08:03:00"))

        let ice = o.rows[0]
        #expect(ice.leg?.badgeText == "ICE 47" && ice.title == "bis Köln Messe/Deutz")
        #expect(ice.detail.hasPrefix("ab Gleis 9 · an ") && ice.detail.hasSuffix("Gleis 93"))
        let deutz = o.rows[1]
        #expect(deutz.title == "Umstieg Köln Messe/Deutz")
        #expect(deutz.detail == "Gleis 93 → Gleis 92 · 2 Min. zu Fuß")
        #expect(NavigationPresenter.bufferLabel(try #require(deutz.buffer)) == "Knapp: 20 s")
        #expect(deutz.spoken.contains("Umstieg in Köln Messe/Deutz, Gleis 93 nach Gleis 92, 2 Minuten Fußweg, knapp, Puffer 20 Sekunden"))
        #expect(o.rows[7].title == "Zu Fuß zu Weyertal 119a" && o.rows[7].detail == "8 Min. zu Fuß · ca. 550 m")

        let tightest = try #require(o.tightest)
        #expect(tightest.stop == "Köln Messe/Deutz" && tightest.buffer.seconds == 20)
        #expect(NavigationPresenter.tightestText(tightest) == "Engster Umstieg: Köln Messe/Deutz, 20 s")
        #expect(NavigationPresenter.tightestText(tightest, spoken: true) == "Engster Umstieg: Köln Messe/Deutz, 20 Sekunden")
        #expect(NavigationPresenter.spokenHeader(o).hasPrefix("Restfahrt, Ankunft "))
        #expect(NavigationPresenter.spokenHeader(o).hasSuffix(", 8 Etappen."))
        #expect(ice.spoken.hasPrefix("Jetzt, "))
    }

    @Test func finishedStagesDropOut() throws {
        // Im RB 25: ICE und Umstieg Deutz sind erledigt, engste Stelle ist jetzt Hansaring.
        var o = try Self.overview(.onBoardTransit(vehicle: 2), at: "07:36:00")
        #expect(o.rows.map(\.id) == ["2", "3", "4", "5", "6", "7"])
        #expect(o.rows[0].isCurrent && o.rows[0].detail.hasPrefix("nächster Halt aussteigen"))
        #expect(o.tightest?.stop == "Köln Hansaring" && o.tightest?.buffer.seconds == 30)

        // Letzter Fussweg: keine Umstiege mehr, also keine engste Stelle.
        o = try Self.overview(.finalWalkToDestination, at: "07:56:00")
        #expect(o.rows.map(\.id) == ["7"] && o.tightest == nil)

        o = try Self.overview(.arrived, at: "08:03:00")
        #expect(o.rows.isEmpty)
    }

    @Test func currentTransferUsesPositionOnlyAfterArrival() throws {
        // Noch im ICE (Umstiegsansicht 2 Min. vor Ankunft): Puffer aus der Ankunftszeit, Position zaehlt nicht.
        let gleis93 = GeoCoordinate(latitude: 50.9409, longitude: 6.9750)
        var o = try Self.overview(.transferRouting(from: 0, to: 2), at: "07:31:00", position: gleis93)
        #expect(o.rows.first?.id == "1" && o.rows.first?.isCurrent == true)
        #expect(o.rows.first?.buffer?.seconds == 20)
        // 07:33 noch an Gleis 93: 60 s bis zur Abfahrt, 100 s Weg -> reicht nicht.
        o = try Self.overview(.transferRouting(from: 0, to: 2), at: "07:33:00", position: gleis93)
        #expect(o.rows.first?.buffer?.status == .missed)
        #expect(NavigationPresenter.bufferLabel(try #require(o.rows.first?.buffer)) == "Reicht nicht")
    }

    @Test func delayTurnsTightTransferRed() throws {
        let late = try Self.journey(iceDelay: 120)
        let o = try Self.overview(.onBoardTransit(vehicle: 0), at: "07:10:00", journey: late)
        let deutz = try #require(o.rows.first { $0.kind == .transfer })
        #expect(deutz.buffer?.status == .missed)
        #expect(deutz.spoken.contains("Umstieg reicht nicht"))
        let tightest = try #require(o.tightest)
        #expect(NavigationPresenter.tightestText(tightest) == "Engster Umstieg: Köln Messe/Deutz, reicht nicht")
    }

    @Test func comfortableTransferIsGreenWithText() throws {
        // Fake-Verbindung 0: Bilk S an 06:18, SEV ab 06:23, 3 Min. Weg -> 2 Min. Puffer.
        let j = try #require(FakeData.routes?.journeys.first)
        let o = NavigationPresenter.overview(NavigationPresenter.Input(
            step: .onBoardTransit(vehicle: 1), journey: j, geometry: j, walks: [:], position: nil,
            now: (try? Date.ISO8601FormatStyle().parse("2026-10-24T06:10:00Z")) ?? .distantPast, pace: WalkingPaceFactor(),
            destinationLabel: "Köln Hbf", startedAt: nil, expired: false))
        let bilk = try #require(o.rows.first { $0.kind == .transfer }?.buffer)
        #expect(bilk.status == .comfortable)
        #expect(NavigationPresenter.bufferLabel(bilk) == "Puffer 2 Min.")
        #expect(o.tightest == nil) // bequem: keine "engste Stelle" im Kopf
    }

    /// Jetzt-Karte und Liste zeigen ab 2 Min. vor Ankunft denselben Puffer (eine Rechnung in NavigationEngine.buffer).
    @Test func nowCardAndListAgreeBeforeArrival() throws {
        let j = try Self.journey()
        let gleis93 = GeoCoordinate(latitude: 50.9409, longitude: 6.9750)
        for time in ["07:30:30", "07:31:30", "07:33:00"] {
            let input = NavigationPresenter.Input(step: .transferRouting(from: 0, to: 2), journey: j, geometry: j, walks: [:],
                                                  position: gleis93, now: Self.at(time), pace: WalkingPaceFactor(),
                                                  destinationLabel: "Weyertal 119a", startedAt: nil, expired: false)
            let card = NavigationPresenter.card(input)
            guard case .buffer(let seconds, _) = card.metrics[2].value else { Issue.record("kein Puffer"); return }
            #expect(NavigationPresenter.overview(input).rows.first?.buffer?.seconds == seconds, "\(time)")
        }
    }

    /// Im ICE: Verspaetung macht Deutz unmoeglich -> Hinweis Kritisch mit "Nächste Verbindung", einmal Haptik.
    @Test func brokenLaterConnectionWarnsOnBoard() throws {
        let late = try Self.journey(iceDelay: 120)
        let input = NavigationPresenter.Input(step: .onBoardTransit(vehicle: 0), journey: late, geometry: late, walks: [:],
                                              position: nil, now: Self.at("07:10:00"), pace: WalkingPaceFactor(),
                                              destinationLabel: "Weyertal 119a", startedAt: nil, expired: false)
        let hint = try #require(NavigationPresenter.card(input).hint)
        #expect(hint.tone == .alert && hint.action == .nextConnection)
        #expect(hint.text == "Anschluss RB 25 in Köln Messe/Deutz reicht nicht mehr.")
    }

    /// Ueber AppFlow: Refresh mit Verspaetung aendert die Liste ohne Alert.
    @Test func refreshWithDelayUpdatesOverview() async throws {
        let now = Mutex(Self.at("07:10:00"))
        let refresher = FakeRefresher()
        var deps = AppDependencies.fakes(planner: FakeRoutePlanner(response: FakeData.deutz()), onboarding: .withLocation,
                                         debounce: .milliseconds(10), refresher: refresher)
        deps.now = { now.withLock { $0 } }
        let f = AppFlow(deps)
        f.send(.editEndpoint(.destination))
        f.choose(.stop(id: "weyertal", label: "Weyertal 119a"))
        await f.waitForWork()
        f.send(.startNavigation(0))
        #expect(f.navStep == .onBoardTransit(vehicle: 0))
        var o = NavigationPresenter.overview(try #require(f.navInput))
        #expect(o.tightest?.buffer.status == .tight)

        // Kalibrierung laesst Umstiege im Bahnhof bei der MOTIS-Zeit (Deutz 100 s -> 20 s Puffer).
        #expect(o.tightest?.buffer.seconds == 20)
        let before = f.navWarnings
        refresher.set(.success(try Self.journey(iceDelay: 120)))
        await f.refreshNavigation()
        o = NavigationPresenter.overview(try #require(f.navInput))
        #expect(o.tightest?.buffer.status == .missed)
        #expect(f.banner == nil)
        #expect(f.navWarnings == before + 1)
        let warnings = f.navWarnings
        await f.refreshNavigation()
        f.navigationUpdate(position: nil, now: Self.at("07:11:00"))
        #expect(f.navWarnings == warnings) // Haptik nur einmal je Anschluss
        #expect(NavigationPresenter.card(try #require(f.navInput)).hint?.action == .nextConnection)
    }
}
#endif
