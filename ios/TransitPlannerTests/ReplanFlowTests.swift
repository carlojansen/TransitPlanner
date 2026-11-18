#if DEBUG
import Foundation
import Synchronization
import Testing
import TransitCore
@testable import TransitPlanner

/// Proaktive Umplanung in AppFlow (SPEZIFIKATION 4.4) mit der Deutz-Fahrt: ICE 47 an Köln Messe/Deutz 07:32, RB 25 ab 07:34
/// (Puffer 20 s minus ICE-Verspaetung). Die Regeln selbst prueft `ConnectionWatchTests` in TransitCore.
@MainActor @Suite struct ReplanFlowTests {
    nonisolated static func at(_ time: String) -> Date {
        (try? Date.ISO8601FormatStyle().parse("2026-10-26T\(time)Z")) ?? .distantPast
    }

    final class Env: Sendable {
        let now = Mutex(ReplanFlowTests.at("07:10:00"))
        let planner: FakeRoutePlanner
        let refresher = FakeRefresher()
        let activities = FakeTripActivities()
        let blocked = Mutex<Date?>(nil)
        /// So lange dauert die Abfrage der Rate-Limit-Sperre (Fenster nach einer gescheiterten Suche).
        let blockedDelay: Duration

        init(delay: Duration = .zero, blockedDelay: Duration = .zero) {
            planner = FakeRoutePlanner(delay: delay, response: FakeData.deutz())
            self.blockedDelay = blockedDelay
        }
        func set(_ time: String) { now.withLock { $0 = ReplanFlowTests.at(time) } }
        var clock: Date { now.withLock { $0 } }
    }

    /// Antwort ab Deutz: [0] der betroffene RB 25, [1] Fussweg 120 s und Tram 1 ab `tram` (Token "YWx0").
    static func alternatives(tram: String = "07:50:00", tramCancelled: Bool = false) -> RoutesResponse? {
        func place(_ id: String, _ lat: Double, _ lon: Double) -> String {
            #"{"kind":"stop","id":"\#(id)","name":"Halt \#(id)","latitude":\#(lat),"longitude":\#(lon)}"#
        }
        let deutz93 = place("deutz93", 50.9409, 6.9750), deutzTram = place("deutzTram", 50.9409, 6.9750)
        let deutz92 = place("deutz92", 50.9406, 6.9745), weyertal = place("weyertal", 50.9258, 6.9218)
        let goal = #"{"kind":"coordinate","latitude":50.9233,"longitude":6.9200}"#
        func t(_ time: String) -> String { "2026-10-26T\(time)Z" }
        func walk(_ i: Int, _ from: String, _ to: String, _ dep: String, _ arr: String, _ seconds: Int) -> String {
            #"{"index":\#(i),"mode":"walk","origin":\#(from),"destination":\#(to),"departure":"\#(t(dep))","arrival":"\#(t(arr))","#
                + #""durationSeconds":\#(seconds),"realtime":false,"cancelled":false,"isTransfer":false,"distanceMeters":100,"durationSource":"motis-osm"}"#
        }
        func ride(_ i: Int, _ mode: String, _ line: String, _ from: String, _ to: String, _ dep: String, _ arr: String, cancelled: Bool) -> String {
            #"{"index":\#(i),"mode":"\#(mode)","origin":\#(from),"destination":\#(to),"departure":"\#(t(dep))","plannedDeparture":"\#(t(dep))","#
                + #""arrival":"\#(t(arr))","realtime":true,"cancelled":\#(cancelled),"line":{"name":"\#(line)"},"replacement":false}"#
        }
        func journey(_ token: String, _ dep: String, _ arr: String, _ legs: [String]) -> String {
            #"{"refreshToken":"\#(token)","departure":"\#(t(dep))","arrival":"\#(t(arr))","durationSeconds":1800,"transfers":0,"#
                + #""modes":["tram"],"cancelled":false,"realtime":true,"hasPolylines":false,"legs":[\#(legs.joined(separator: ","))],"remarks":[]}"#
        }
        let rb25 = journey("cmIyNQ==", "07:34:00", "08:06:00", [
            ride(0, "regional", "RB 25", deutz92, weyertal, "07:34:00", "07:58:00", cancelled: false),
            walk(1, weyertal, goal, "07:58:00", "08:06:00", 480),
        ])
        let tramTrip = journey("YWx0", "07:48:00", "08:16:00", [
            walk(0, deutz93, deutzTram, "07:48:00", "07:50:00", 120),
            ride(1, "tram", "1", deutzTram, weyertal, tram, "08:08:00", cancelled: tramCancelled),
            walk(2, weyertal, goal, "08:08:00", "08:16:00", 480),
        ])
        let json = #"{"journeys":[\#(rb25),\#(tramTrip)],"earlierRef":null,"laterRef":null,"walkOnly":false,"#
            + #""removedLongDistance":0,"fetchedAt":"2026-10-26T07:10:00Z","attribution":\#(FakeData.attributionJSON)}"#
        return try? TransitJSON.decoder().decode(RoutesResponse.self, from: Data(json.utf8))
    }

    /// Navigation der Deutz-Fahrt, im ICE (07:10); Folgesuchen liefern `alternatives()`.
    func navigating(_ env: Env, via stops: [TripEndpoint] = [], configure: (AppFlow) -> Void = { _ in }) async -> AppFlow {
        var deps = AppDependencies.fakes(planner: env.planner, onboarding: .withLocation, debounce: .milliseconds(10), refresher: env.refresher)
        deps.now = { env.clock }
        deps.activities = env.activities
        deps.blockedUntil = {
            if env.blockedDelay > .zero { try? await Task.sleep(for: env.blockedDelay) }
            return env.blocked.withLock { $0 }
        }
        let f = AppFlow(deps)
        configure(f)
        f.send(.editEndpoint(.destination))
        f.choose(.stop(id: "weyertal", label: "Weyertal 119a"))
        await f.waitForWork()
        for stop in stops {
            f.send(.back)
            f.send(.editEndpoint(.via))
            f.choose(stop)
            await f.waitForWork()
        }
        env.planner.setResponse(Self.alternatives())
        f.send(.startNavigation(0))
        return f
    }

    /// Refresh mit verspaetetem ICE, danach wartet der Test auf die Suche.
    func refresh(_ f: AppFlow, _ env: Env, iceDelay: Int) async throws {
        env.refresher.set(.success(try RouteOverviewTests.journey(iceDelay: iceDelay)))
        await f.refreshNavigation()
        await f.waitForReplan()
    }

    func tick(_ f: AppFlow, _ env: Env, at time: String) async {
        env.set(time)
        f.navigationUpdate(position: nil, now: env.clock)
        await f.waitForReplan()
    }

    func problem(_ env: Env) -> TripActivityState.Problem? { env.activities.running().first?.state.problem }

    /// Deutz-Fahrt mit verschobener Abfahrt eines Fahrzeugs (s) nach `iceDelay`.
    static func shifted(iceDelay: Int = 0, leg: Int, by seconds: Double) throws -> Journey {
        try ViaFlowTests.changed(RouteOverviewTests.journey(iceDelay: iceDelay)) { legs in
            legs[leg]["departure"] = (legs[leg]["departure"] as? Double ?? 0) + seconds
        }
    }

    @Test func brokenConnectionProposesBestReachableFromAlightingStop() async throws {
        let env = Env()
        let f = await navigating(env) { f in
            f.toggle(.bus)
            f.accessibility = .stepFree
            UserDefaults.standard.removeObject(forKey: Accessibility.key)
        }
        #expect(f.navStep == .onBoardTransit(vehicle: 0))
        try await refresh(f, env, iceDelay: 180) // Ankunft 07:35, Puffer -160 s
        #expect(env.planner.callCount == 2)
        let first = try #require(env.planner.recordedRequests.first)
        let request = try #require(env.planner.recordedRequests.last)
        // Ausstiegshalt und Echtzeit-Ankunft, nicht Standort und jetzt
        #expect(request.origin == .stop(id: "deutz93"))
        #expect(request.targetTime == Self.at("07:35:00"))
        #expect(request.destination == first.destination)
        #expect(request.modes != nil && request.modes == first.modes)
        #expect(request.accessibility == .stepFree)
        let offer = try #require(f.replanOffer)
        #expect(offer.proposal.search.trigger == .connectionBroken(vehicle: 2))
        // [0] enthaelt den betroffenen RB 25 und wird nie vorgeschlagen
        #expect(offer.proposal.alternativeIndex == 1)
    }

    /// Ausgestiegen: wartet der Anschluss, verschwindet "Anschluss" aus der Live Activity (eingerastet zaehlt nur Spaeteres).
    @Test func connectionProblemClearsOnTheTransferWalkWhenTheConnectionWaits() async throws {
        let env = Env()
        let f = await navigating(env)
        // ICE an 07:35, RB ab 07:35:30: Puffer -70 s, eingerastet
        env.refresher.set(.success(try Self.shifted(iceDelay: 180, leg: 2, by: 90)))
        await f.refreshNavigation()
        await f.waitForReplan()
        #expect(problem(env) == .connection)
        await tick(f, env, at: "07:35:05")
        #expect(f.navStep == .transferRouting(from: 0, to: 2))
        #expect(problem(env) == .connection)
        // RB wartet bis 07:39
        env.refresher.set(.success(try Self.shifted(iceDelay: 180, leg: 2, by: 300)))
        await f.refreshNavigation()
        #expect(problem(env) == nil)
    }

    /// Auf dem Umstiegsweg rastet ein spaeterer Bruch (Tram am Hansaring) ein und wieder frei, ohne Suche.
    @Test func laterConnectionLatchesAndReleasesOnTheTransferWalk() async throws {
        let env = Env()
        let f = await navigating(env)
        await tick(f, env, at: "07:32:10")
        #expect(f.navStep == .transferRouting(from: 0, to: 2))
        #expect(problem(env) == nil)
        let warnings = f.navWarnings
        env.refresher.set(.success(try Self.shifted(leg: 4, by: -170)))
        await f.refreshNavigation()
        await f.waitForReplan()
        #expect(problem(env) == .connection)
        #expect(f.navWarnings == warnings + 1)
        #expect(env.planner.callCount == 1 && f.replanOffer == nil)
        // planmaessig nur 30 s (knapp, bleibt eingerastet); mit 130 s Reserve frei
        env.refresher.set(.success(try RouteOverviewTests.journey()))
        await f.refreshNavigation()
        #expect(problem(env) == .connection)
        env.refresher.set(.success(try Self.shifted(leg: 4, by: 100)))
        await f.refreshNavigation()
        #expect(problem(env) == nil)
    }

    /// Steht ein Vorschlag, startet auch 5 Min. schlechter keine Suche (die Antwort waere verworfen); er wird gegen die neue
    /// Suchzeit geprueft und faellt erst, wenn die Alternative nicht mehr erreichbar ist. Dann sucht es neu.
    @Test func visibleProposalIsRecheckedInsteadOfSearchingAgain() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        let id = try #require(f.replanOffer?.proposal.id)
        try await refresh(f, env, iceDelay: 480) // Ankunft 07:40, Tram 07:50 reicht noch
        #expect(env.planner.callCount == 2)
        #expect(f.replanOffer?.proposal.id == id)
        env.planner.setResponse(Self.alternatives(tram: "08:00:00"))
        try await refresh(f, env, iceDelay: 900) // Ankunft 07:47: 07:50 reicht nicht mehr
        #expect(env.planner.callCount == 3)
        let fresh = try #require(f.replanOffer)
        #expect(fresh.proposal.id != id)
        #expect(fresh.answer.calibrated[fresh.proposal.alternativeIndex].journey.legs.contains { $0.departure == Self.at("08:00:00") })
    }

    /// "Wechseln" im Blatt ab der naechsten Station, waehrend man im ICE sitzt: vorgemerkt, nicht sofort (SPEZIFIKATION 4.4).
    @Test func choosingFromTheNextStationOnBoardIsReserved() async throws {
        let env = Env()
        let f = await navigating(env)
        f.openAlternatives(from: .nextStation)
        await f.waitForPeek()
        f.chooseAlternative(1)
        #expect(f.pendingSwitch?.proposal.alternativeIndex == 1)
        #expect(f.navJourney?.legs.contains { $0.line?.name == "ICE 47" } == true)
        await tick(f, env, at: "07:20:00")
        #expect(f.navStep == .onBoardTransit(vehicle: 0))
        env.refresher.set(.success(try #require(Self.alternatives()?.journeys[1])))
        await tick(f, env, at: "07:32:00")
        #expect(f.pendingSwitch == nil)
        #expect(f.navJourney?.legs.contains { $0.line?.name == "1" } == true)
    }

    /// Faellt der Refresh am Suchstart aus, gilt der gemerkte Stand der Alternative.
    @Test func switchUsesTheRememberedStateWhenTheRefreshFails() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        f.acceptReplan(try #require(f.replanOffer).proposal.id)
        env.refresher.set(.failure(.upstreamUnavailable))
        await tick(f, env, at: "07:36:00")
        #expect(f.pendingSwitch == nil)
        #expect(f.navJourney?.legs.first { $0.line?.name == "1" }?.departure == Self.at("07:50:00"))
    }

    /// Ohne Ankunftszeit des Ausstiegsfahrzeugs ist unklar, wann man am Suchstart ist: der Wechsel entfaellt, kein Sofortwechsel.
    @Test func pendingSwitchDroppedWhenTheAlightingTimeIsGone() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        f.acceptReplan(try #require(f.replanOffer).proposal.id)
        env.refresher.set(.success(try ViaFlowTests.changed(RouteOverviewTests.journey(iceDelay: 180)) { legs in
            legs[0]["arrival"] = nil
            legs[0]["plannedArrival"] = nil
        }))
        await f.refreshNavigation()
        env.refresher.set(.failure(.upstreamUnavailable)) // ein Wechsel nutzte jetzt den gemerkten Stand
        await f.waitForReplan()
        #expect(f.pendingSwitch == nil)
        #expect(f.navJourney?.legs.contains { $0.line?.name == "ICE 47" } == true)
    }

    /// Eine gescheiterte Suche, die nach dem Beenden noch auf die Sperre wartet, darf das Gedaechtnis der neuen Fahrt nicht
    /// beruehren (sonst sperrt ihr `markFailed` die naechste Suche fuer 60 s).
    @Test func failedSearchAfterRestartLeavesTheNewMemoryAlone() async throws {
        let env = Env(blockedDelay: .milliseconds(200))
        let f = await navigating(env)
        env.planner.setFailure(.upstreamUnavailable)
        env.refresher.set(.success(try RouteOverviewTests.journey(iceDelay: 180)))
        await f.refreshNavigation()
        try await Task.sleep(for: .milliseconds(50)) // Suche gescheitert, wartet auf die Sperre
        #expect(env.planner.callCount == 2)
        f.send(.back)
        env.planner.setFailure(nil)
        f.send(.startNavigation(0))
        await f.refreshNavigation()
        await f.waitForReplan()
        let offer = try #require(f.replanOffer)
        try await Task.sleep(for: .milliseconds(300)) // die alte Suche waere jetzt durch
        f.declineReplan(offer.proposal.id)
        try await refresh(f, env, iceDelay: 480) // 5 Min. schlechter: neue Suche, keine Sperre
        #expect(env.planner.callCount == 4)
    }

    @Test func tightConnectionDoesNotSearch() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 0) // 20 s: knapp, aber erreichbar
        #expect(env.planner.callCount == 1)
        #expect(f.replanOffer == nil)
    }

    @Test func cancelledLaterVehicleProposes() async throws {
        let env = Env()
        let f = await navigating(env)
        let cancelled = try ViaFlowTests.changed(RouteOverviewTests.journey()) { legs in legs[2]["cancelled"] = true }
        env.refresher.set(.success(cancelled))
        await f.refreshNavigation()
        await f.waitForReplan()
        let offer = try #require(f.replanOffer)
        #expect(offer.proposal.search.trigger == .tripCancelled(vehicle: 2))
        #expect(offer.proposal.alternativeIndex == 1)
        // Haptik einmal je Anschluss, auch beim Ausfall; Live Activity zeigt "Anschluss"
        #expect(f.navWarnings == 1)
        #expect(problem(env) == .connection)
        await tick(f, env, at: "07:11:00")
        #expect(f.navWarnings == 1)
    }

    /// Der Schluessel wird vor dem Task markiert: Ticks waehrend der Suche starten keine zweite, spaetere Ticks auch nicht.
    @Test func oneSearchPerKeyEvenWhileSearching() async throws {
        let env = Env(delay: .milliseconds(150))
        let f = await navigating(env)
        env.refresher.set(.success(try RouteOverviewTests.journey(iceDelay: 180)))
        await f.refreshNavigation()
        f.navigationUpdate(position: nil, now: env.clock)
        f.navigationUpdate(position: nil, now: env.clock)
        await f.waitForReplan()
        #expect(env.planner.callCount == 2)
        let id = try #require(f.replanOffer?.proposal.id)
        await tick(f, env, at: "07:12:00")
        #expect(env.planner.callCount == 2)
        #expect(f.replanOffer?.proposal.id == id)
    }

    @Test func declineSuppressesSameButNotFiveMinutesWorse() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        let offer = try #require(f.replanOffer)
        f.declineReplan(offer.proposal.id)
        #expect(f.replanOffer == nil)
        await tick(f, env, at: "07:11:00")
        #expect(env.planner.callCount == 2)
        #expect(f.replanOffer == nil)
        try await refresh(f, env, iceDelay: 300) // 2 Min. schlechter: bleibt still
        #expect(env.planner.callCount == 2 && f.replanOffer == nil)
        try await refresh(f, env, iceDelay: 480) // 5 Min. schlechter als beim Ablehnen
        #expect(env.planner.callCount == 3)
        #expect(f.replanOffer != nil && f.replanOffer?.proposal.id != offer.proposal.id)
    }

    /// Puffer zittert: derselbe Vorschlag, keine neue Suche, Live Activity bleibt bei "Anschluss". Verfall erst mit 120 s
    /// Reserve; loest es erneut aus, kommt die gemerkte Antwort ohne neue Suche.
    @Test func flappingKeepsProposalAndExpiryNeedsHysteresis() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        let id = try #require(f.replanOffer?.proposal.id)
        #expect(problem(env) == .connection)
        try await refresh(f, env, iceDelay: 0) // 20 s: knapp, eingerastet
        #expect(f.replanOffer?.proposal.id == id)
        #expect(problem(env) == .connection)
        try await refresh(f, env, iceDelay: 180)
        #expect(f.replanOffer?.proposal.id == id)
        #expect(env.planner.callCount == 2)
        try await refresh(f, env, iceDelay: -100) // 120 s Reserve: verfaellt
        #expect(f.replanOffer == nil)
        #expect(problem(env) == nil)
        try await refresh(f, env, iceDelay: 180)
        #expect(f.replanOffer != nil && f.replanOffer?.proposal.id != id)
        #expect(env.planner.callCount == 2)
    }

    @Test func answerAfterSearchStartIsDiscarded() async throws {
        let env = Env(delay: .milliseconds(150))
        let f = await navigating(env)
        env.refresher.set(.success(try RouteOverviewTests.journey(iceDelay: 180)))
        await f.refreshNavigation()
        env.set("07:36:00") // Suchstart 07:35 vorbei, bevor die Antwort kommt
        await f.waitForReplan()
        #expect(env.planner.callCount == 2)
        #expect(f.replanOffer == nil)
    }

    @Test func answerAfterEndIsDiscardedAndRestartForgets() async throws {
        let env = Env(delay: .milliseconds(150))
        let f = await navigating(env)
        env.refresher.set(.success(try RouteOverviewTests.journey(iceDelay: 180)))
        await f.refreshNavigation()
        f.send(.back) // Beenden waehrend der Suche
        await f.waitForReplan()
        #expect(f.replanOffer == nil && f.pendingSwitch == nil)
        // Neu gestartet: frisches Gedaechtnis, derselbe Anschluss wird wieder gesucht
        f.send(.startNavigation(0))
        try await refresh(f, env, iceDelay: 180)
        #expect(env.planner.callCount == 3)
        #expect(f.replanOffer != nil)
        f.send(.back)
        #expect(f.replanOffer == nil)
    }

    @Test func rateLimitBlocksTheRetry() async throws {
        let env = Env()
        let f = await navigating(env)
        env.planner.setFailure(.rateLimited)
        env.blocked.withLock { $0 = Self.at("07:20:00") }
        try await refresh(f, env, iceDelay: 180)
        #expect(env.planner.callCount == 2 && f.replanOffer == nil)
        #expect(f.banner == nil) // still, kein Banner fuer die Hintergrundsuche
        env.planner.setFailure(nil)
        await tick(f, env, at: "07:15:00") // nach 60 s, aber vor Retry-After
        #expect(env.planner.callCount == 2)
        env.blocked.withLock { $0 = nil }
        await tick(f, env, at: "07:21:00")
        #expect(env.planner.callCount == 3)
        #expect(f.replanOffer != nil)
    }

    /// Am Gleis gilt der bestehende Hinweis "fällt aus": kein Vorschlag.
    @Test func cancelledVehicleAtPlatformGivesNoProposal() async throws {
        let env = Env()
        let f = await navigating(env)
        env.set("07:33:00")
        f.navigationUpdate(position: GeoCoordinate(latitude: 50.9406, longitude: 6.9745), accuracy: 5, now: env.clock)
        #expect(f.navStep == .waitingAtPlatform(vehicle: 2))
        env.refresher.set(.success(try ViaFlowTests.changed(RouteOverviewTests.journey()) { legs in legs[2]["cancelled"] = true }))
        await f.refreshNavigation()
        await f.waitForReplan()
        #expect(env.planner.callCount == 1)
        #expect(f.replanOffer == nil)
    }

    /// "Uebernehmen": im Zug bleibt die Fahrt (kein Fussweg-Zustand, kein Problem "Anschluss"); am Suchstart startet die
    /// Alternative mit frischem Stand.
    @Test func acceptKeepsTheTrainUntilTheSearchStartThenSwitches() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        let offer = try #require(f.replanOffer)
        #expect(problem(env) == .connection)
        f.acceptReplan(offer.proposal.id)
        #expect(f.pendingSwitch?.proposal.id == offer.proposal.id && f.replanOffer == nil)
        #expect(problem(env) != .connection)
        await tick(f, env, at: "07:20:00")
        #expect(f.navStep == .onBoardTransit(vehicle: 0))
        #expect(f.navJourney?.legs.contains { $0.line?.name == "ICE 47" } == true)
        #expect(problem(env) != .connection)
        #expect(env.planner.callCount == 2)

        let fresh = try #require(Self.alternatives(tram: "07:52:00")?.journeys[1])
        env.refresher.set(.success(fresh))
        await tick(f, env, at: "07:36:00")
        #expect(f.pendingSwitch == nil)
        #expect(f.phase == .navigation(0))
        let tram = f.navJourney?.legs.first { $0.line?.name == "1" }
        #expect(tram?.departure == Self.at("07:52:00")) // frischer Stand, nicht der gemerkte
        #expect(f.navJourney?.legs.contains { $0.line?.name == "ICE 47" } == false)
    }

    @Test func switchIsDroppedWhenTheFreshAlternativeNoLongerWorks() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        f.acceptReplan(try #require(f.replanOffer).proposal.id)
        env.refresher.set(.success(try #require(Self.alternatives(tramCancelled: true)?.journeys[1])))
        await tick(f, env, at: "07:36:00")
        #expect(f.pendingSwitch == nil)
        #expect(f.navJourney?.legs.contains { $0.line?.name == "ICE 47" } == true)
    }

    /// Ankunft mit vorgemerktem Wechsel: der Wechsel laeuft nicht mehr, kein Zustand bleibt.
    @Test func arrivalClearsPendingSwitch() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        f.acceptReplan(try #require(f.replanOffer).proposal.id)
        env.set("08:04:00")
        f.navigationUpdate(position: GeoCoordinate(latitude: 50.9233, longitude: 6.9200), accuracy: 5, now: env.clock)
        #expect(f.phase == .arrival)
        #expect(f.pendingSwitch == nil && f.replanOffer == nil)
        await f.waitForReplan()
        #expect(f.phase == .arrival)
    }

    /// Stopps ab dem Fahrzeug vor dem betroffenen: im ICE reicht die Tram am Hansaring nicht (Suche ab Hansaring); der Stopp
    /// in Deutz liegt davor und entfaellt, Zülpicher Platz bleibt.
    @Test func viaFromTheVehicleBeforeTheAffectedOne() async throws {
        let env = Env()
        let f = await navigating(env, via: [.stop(id: "deutz93", label: "Köln Messe/Deutz"), .stop(id: "zuelpicher12", label: "Zülpicher Platz")])
        #expect(f.via.map(\.id) == ["deutz93", "zuelpicher12"])
        let broken = try ViaFlowTests.changed(RouteOverviewTests.journey()) { legs in
            legs[4]["departure"] = (legs[4]["departure"] as? Double ?? 0) - 170
        }
        env.refresher.set(.success(broken))
        await f.refreshNavigation()
        await f.waitForReplan()
        let request = try #require(env.planner.recordedRequests.last)
        #expect(request.origin == .stop(id: "hansaring"))
        #expect(request.targetTime == Self.at("07:38:00"))
        #expect(request.via?.map(\.id) == ["zuelpicher12"])
    }
}
#endif
