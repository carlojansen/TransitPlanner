#if DEBUG
import Foundation
import Synchronization
import Testing
import TransitCore
import UserNotifications
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
        let notifier = FakeNotifier()
        let blocked = Mutex<Date?>(nil)
        /// So lange dauert die Abfrage der Rate-Limit-Sperre (Fenster nach einer gescheiterten Suche).
        let blockedDelay: Duration

        init(delay: Duration = .zero, blockedDelay: Duration = .zero, calibrationDelay: Duration = .zero) {
            planner = FakeRoutePlanner(delay: delay, response: FakeData.deutz(), calibrationDelay: calibrationDelay)
            self.blockedDelay = blockedDelay
        }
        func set(_ time: String) { now.withLock { $0 = ReplanFlowTests.at(time) } }
        var clock: Date { now.withLock { $0 } }
    }

    /// Antwort ab Deutz: [0] der betroffene RB 25, [1] Fussweg 120 s und Tram 1 ab `tram` (Token "YWx0"), mit `early`
    /// [2] Tram 7 ohne Fussweg ab Deutz (frueher am Ziel). `fromHansaring`: Tram 1 startet am Hansaring (Suchstart dort).
    /// `walkOnly`: [1] ist ein reiner Fussweg ab Deutz (Backend-Fussweg-Vorrang), ohne Tram.
    static func alternatives(tram: String = "07:50:00", tramCancelled: Bool = false, early: String? = nil,
                             fromHansaring: Bool = false, walkOnly: Bool = false) -> RoutesResponse? {
        func place(_ id: String, _ lat: Double, _ lon: Double) -> String {
            #"{"kind":"stop","id":"\#(id)","name":"Halt \#(id)","latitude":\#(lat),"longitude":\#(lon)}"#
        }
        let deutz93 = place("deutz93", 50.9409, 6.9750), deutzTram = place("deutzTram", 50.9409, 6.9750)
        let deutz92 = place("deutz92", 50.9406, 6.9745), weyertal = place("weyertal", 50.9258, 6.9218)
        let tramStart = fromHansaring ? place("hansaring", 50.9483, 6.9431) : deutz93
        let tramStop = fromHansaring ? place("hansaringTram", 50.9479, 6.9438) : deutzTram
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
            walk(0, tramStart, tramStop, "07:48:00", "07:50:00", 120),
            ride(1, "tram", "1", tramStop, weyertal, tram, "08:08:00", cancelled: tramCancelled),
            walk(2, weyertal, goal, "08:08:00", "08:16:00", 480),
        ])
        let earlyTrip = early.map { dep in
            journey("ZWFy", dep, "08:08:00", [
                ride(0, "tram", "7", deutz93, weyertal, dep, "08:00:00", cancelled: false),
                walk(1, weyertal, goal, "08:00:00", "08:08:00", 480),
            ])
        }
        let walkTrip = journey("d2Fsaw==", "07:35:00", "08:20:00", [walk(0, deutz93, goal, "07:35:00", "08:20:00", 2700)])
        let list = [rb25, walkOnly ? walkTrip : tramTrip] + (earlyTrip.map { [$0] } ?? [])
        let json = #"{"journeys":[\#(list.joined(separator: ","))],"earlierRef":null,"laterRef":null,"walkOnly":false,"#
            + #""removedLongDistance":0,"fetchedAt":"2026-10-26T07:10:00Z","attribution":\#(FakeData.attributionJSON)}"#
        return try? TransitJSON.decoder().decode(RoutesResponse.self, from: Data(json.utf8))
    }

    /// Navigation der Deutz-Fahrt, im ICE (07:10); Folgesuchen liefern `alternatives()`.
    func navigating(_ env: Env, via stops: [TripEndpoint] = [], configure: (AppFlow) -> Void = { _ in }) async -> AppFlow {
        var deps = AppDependencies.fakes(planner: env.planner, onboarding: .withLocation, debounce: .milliseconds(10),
                                         refresher: env.refresher, notifier: env.notifier)
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
    /// Suchzeit geprueft (gleiche ID, gleiche Alternative, Suchzeit nachgefuehrt) und faellt erst, wenn keine Alternative mehr
    /// erreichbar ist. Dann sucht es neu, mit neuem Vorschlag.
    @Test func visibleProposalIsRecheckedInsteadOfSearchingAgain() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        let id = try #require(f.replanOffer?.proposal.id)
        try await refresh(f, env, iceDelay: 480) // Ankunft 07:40, Tram 07:50 reicht noch
        #expect(env.planner.callCount == 2)
        #expect(f.replanOffer?.proposal.id == id)
        #expect(f.replanOffer?.proposal.alternativeIndex == 1)
        #expect(f.replanOffer?.proposal.search.time == Self.at("07:40:00"))
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

    /// Reiner Fussweg als Vorschlag (Backend-Fussweg-Vorrang): wird vorgeschlagen und startet am Suchstart direkt im
    /// Schritt "zu Fuss zum Ziel", ohne Refresh.
    @Test func walkOnlyAlternativeIsProposedAndSwitchesWithoutRefresh() async throws {
        let env = Env()
        let f = await navigating(env)
        env.planner.setResponse(Self.alternatives(walkOnly: true))
        try await refresh(f, env, iceDelay: 180)
        let offer = try #require(f.replanOffer)
        #expect(offer.proposal.alternativeIndex == 1)
        f.acceptReplan(offer.proposal.id)
        let calls = env.refresher.callCount
        await tick(f, env, at: "07:36:00")
        #expect(f.pendingSwitch == nil)
        #expect(env.refresher.callCount == calls)
        #expect(f.navJourney?.legs.allSatisfy(\.isWalk) == true)
        #expect(f.navStep == .finalWalkToDestination)
    }

    /// Der Wechsel-Refresh laeuft erst am Suchstart (.start), nicht waehrend des Wartens (.wait), und nur einmal.
    @Test func switchRefreshesOnlyAtTheSearchStart() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        f.acceptReplan(try #require(f.replanOffer).proposal.id)
        let calls = env.refresher.callCount
        await tick(f, env, at: "07:20:00")
        #expect(f.pendingSwitch != nil && env.refresher.callCount == calls)
        env.refresher.set(.success(try #require(Self.alternatives()?.journeys[1])))
        await tick(f, env, at: "07:36:00")
        #expect(f.pendingSwitch == nil && env.refresher.callCount == calls + 1)
        await tick(f, env, at: "07:37:00")
        #expect(env.refresher.callCount == calls + 1)
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

    // MARK: Schritt 5: Banner, Mitteilung, Blatt

    /// Vordergrund: keine Mitteilung. Hintergrund: eine, eigene Kategorie, zeitkritisch, nur Linie, Halt, Zeit und Gleis.
    @Test func proposalInTheBackgroundPostsATimeSensitiveAlert() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        let offer = try #require(f.replanOffer)
        #expect(env.notifier.replanAlert == nil)
        f.movedToBackground()
        await f.waitForReplan()
        let alert = try #require(env.notifier.replanAlert)
        #expect(alert.proposalID == offer.proposal.id)
        #expect(alert.title == "Anschluss RB 25 reicht nicht mehr")
        #expect(alert.body.hasPrefix("Vorschlag: 1 um ") && alert.body.contains("ab Halt deutzTram"))
        // Ankunft der Alternative (kalibrierter Zielweg) und wie viel spaeter als die laufende Fahrt, nur als Uhrzeit
        #expect(alert.body.contains(", Ankunft ") && alert.body.hasSuffix(" (+9 Min.)"), "\(alert.body)")
        // Ziel-Label des Nutzers ("Weyertal 119a") und Koordinaten nie, keine Emojis
        #expect(!alert.body.contains("119a") && !alert.body.contains("50.9"))
        // Sperrbildschirm: nur ein Halt (Abfahrt), nicht der letzte Ausstiegshalt der Alternative
        #expect(!alert.body.contains("weyertal") && !alert.body.contains("nach"))
        #expect((alert.title + alert.body).unicodeScalars.allSatisfy { !$0.properties.isEmojiPresentation })
        #expect(env.notifier.alerts.isEmpty) // nicht bei den Erinnerungen
        let request = SystemNotifier.request(for: alert)
        #expect(request.content.interruptionLevel == .timeSensitive)
        #expect(request.content.categoryIdentifier == SystemNotifier.replanCategory.identifier)
        #expect(request.content.categoryIdentifier != SystemNotifier.category.identifier)
        #expect(SystemNotifier.replanCategory.actions.isEmpty)
        #expect(request.content.userInfo.values.contains { $0 as? String == offer.proposal.id.uuidString })
    }

    enum ReplanEnd: CaseIterable, Sendable { case decline, accept, expire, end, arrive }

    /// Die Mitteilung verschwindet bei Ablehnen, Uebernehmen, Verfall, Beenden und Ankunft.
    @Test(arguments: ReplanEnd.allCases) func alertIsRemovedWhenTheProposalEnds(_ end: ReplanEnd) async throws {
        let env = Env()
        let f = await navigating(env)
        f.movedToBackground()
        try await refresh(f, env, iceDelay: 180)
        let id = try #require(f.replanOffer?.proposal.id)
        #expect(env.notifier.replanAlert?.proposalID == id)
        switch end {
        case .decline: f.declineReplan(id)
        case .accept: f.acceptReplan(id)
        case .expire: try await refresh(f, env, iceDelay: -100)
        case .end: f.send(.back)
        case .arrive:
            env.set("08:04:00")
            f.navigationUpdate(position: GeoCoordinate(latitude: 50.9233, longitude: 6.9200), accuracy: 5, now: env.clock)
        }
        await f.waitForReplan()
        #expect(f.replanOffer == nil)
        #expect(env.notifier.replanAlert == nil)
    }

    /// Tipp (Mitteilung oder Banner) oeffnet das Blatt mit der Antwort ab dem Suchstart, ohne neue Suche.
    @Test func showProposalOpensTheSheetWithTheAnswer() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        let offer = try #require(f.replanOffer)
        f.showProposal(offer.proposal.id)
        guard case .loaded(let response, let walks, _) = f.peek else {
            Issue.record("Blatt nicht vorbelegt")
            return
        }
        #expect(response.journeys.count == 2 && walks?.count == 2)
        #expect(env.planner.callCount == 2)
        #expect(f.peekOrigin == .nextStation)
        #expect(f.peekStart?.name == "Köln Messe/Deutz" && f.peekStart?.time == Self.at("07:35:00"))
    }

    /// Gegenproben: fremde ID, Suchstart erreicht, Fahrt beendet. Dann weder Blatt noch Wechsel.
    @Test func showProposalIgnoresForeignExpiredOrEndedProposals() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        let id = try #require(f.replanOffer?.proposal.id)
        f.showProposal(UUID())
        #expect(f.peek == nil)
        env.set("07:35:00") // Suchstart (Echtzeit-Ankunft) erreicht, noch kein Tick
        f.showProposal(id)
        f.acceptReplan(id)
        #expect(f.peek == nil && f.pendingSwitch == nil)
        env.set("07:20:00")
        f.send(.back)
        f.showProposal(id)
        #expect(f.peek == nil)
    }

    /// Jetzt-Karte: Vorschlag mit Aktionen statt "reicht nicht"; nach "Übernehmen" "Wechsel auf 1 vorgemerkt".
    @Test func cardShowsProposalThenReservedSwitch() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        let id = try #require(f.replanOffer?.proposal.id)
        var input = try #require(f.navInput)
        var hint = try #require(NavigationPresenter.card(input).hint)
        #expect(hint.action == .replan(id))
        #expect(hint.text.hasPrefix("Anschluss RB 25 reicht nicht mehr. Vorschlag: 1 um "))
        f.acceptReplan(id)
        input = try #require(f.navInput)
        hint = try #require(NavigationPresenter.card(input).hint)
        #expect(hint.text == "Wechsel auf 1 vorgemerkt")
        #expect(hint.action == nil && !hint.text.contains("reicht nicht"))
    }

    /// Verfall (Anschluss reicht wieder): kurzer Hinweis, nach `replanNoticeSeconds` weg. Ablehnen zeigt ihn nicht.
    @Test func expiryShowsAShortNotice() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        try await refresh(f, env, iceDelay: -100)
        #expect(f.replanOffer == nil)
        #expect(f.replanBanner == .expired("Anschluss RB 25 reicht wieder"))
        let input = try #require(f.navInput)
        #expect(NavigationPresenter.card(input).hint?.text == "Anschluss RB 25 reicht wieder")
        await tick(f, env, at: "07:10:59")
        #expect(f.replanBanner != nil)
        await tick(f, env, at: "07:11:00")
        #expect(f.replanBanner == nil)
        try await refresh(f, env, iceDelay: 180)
        f.declineReplan(try #require(f.replanOffer?.proposal.id))
        #expect(f.replanBanner == nil)
    }

    /// Suchstart erreicht: der Vorschlag endet still, kein Hinweis "reicht wieder" (der gilt nur fuer den Verfall).
    @Test func reachingTheSearchStartEndsTheProposalSilently() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        #expect(f.replanOffer != nil)
        await tick(f, env, at: "07:35:30")
        #expect(f.replanOffer == nil)
        #expect(f.replanBanner == nil)
    }

    /// Wechseln im Blatt aus dem Vorschlag merkt ab dessen Suchstart vor (Hansaring), nicht ab der naechsten Station (Deutz).
    @Test func choosingInTheProposalSheetReservesFromTheSearchStart() async throws {
        let env = Env()
        let f = await navigating(env)
        env.planner.setResponse(Self.alternatives(fromHansaring: true))
        env.refresher.set(.success(try Self.shifted(leg: 4, by: -170))) // Tram 12 am Hansaring reicht nicht, im ICE
        await f.refreshNavigation()
        await f.waitForReplan()
        let offer = try #require(f.replanOffer)
        f.showProposal(offer.proposal.id)
        #expect(f.peekStart?.name == "Köln Hansaring")
        f.chooseAlternative(offer.proposal.alternativeIndex)
        #expect(f.pendingSwitch?.proposal.search.alightingVehicle == 2)
        #expect(f.pendingSwitch?.proposal.search.key == offer.proposal.search.key)
        #expect(f.peek == nil && f.replanOffer == nil)
    }
    // MARK: Review-Befunde

    /// Vorgemerkt ab Hansaring (Tram 12 reicht nicht), danach faellt der RB 25 davor aus: der Ausfall gilt wie ohne Vormerkung
    /// (Vorschlag ab Deutz, Problem "Anschluss"), die Vormerkung entfaellt, gewechselt wird nicht.
    @Test func reservedSwitchAtALaterStationKeepsWatchingTheVehiclesBefore() async throws {
        let env = Env()
        let f = await navigating(env)
        env.planner.setResponse(Self.alternatives(fromHansaring: true))
        env.refresher.set(.success(try Self.shifted(leg: 4, by: -170)))
        await f.refreshNavigation()
        await f.waitForReplan()
        let offer = try #require(f.replanOffer)
        #expect(offer.proposal.search.alightingVehicle == 2)
        f.acceptReplan(offer.proposal.id)
        #expect(f.pendingSwitch != nil)
        #expect(problem(env) != .connection)
        env.planner.setResponse(Self.alternatives())
        env.refresher.set(.success(try ViaFlowTests.changed(Self.shifted(leg: 4, by: -170)) { legs in legs[2]["cancelled"] = true }))
        await f.refreshNavigation()
        await f.waitForReplan()
        #expect(f.pendingSwitch == nil)
        #expect(f.replanOffer?.proposal.search.trigger == .tripCancelled(vehicle: 2))
        let hint = try #require(f.navInput.map(NavigationPresenter.card)?.hint)
        #expect(hint.text.hasPrefix("Anschluss RB 25 fällt aus"))
        #expect(problem(env) == .connection)
        env.refresher.set(.success(try #require(Self.alternatives(fromHansaring: true)?.journeys[1])))
        await tick(f, env, at: "07:39:00")
        #expect(f.navJourney?.legs.contains { $0.line?.name == "ICE 47" } == true)
    }

    /// Vorgemerkt ab Hansaring, aber der Nutzer steht nach der Abfahrt des RB 25 noch in Deutz: die Uhrzeit allein startet
    /// den Wechsel nicht, nur der Schritt im bzw. nach dem Ausstiegsfahrzeug.
    @Test func reservedSwitchStartsOnlyFromTheAlightingVehicle() async throws {
        let env = Env()
        let f = await navigating(env)
        env.planner.setResponse(Self.alternatives(fromHansaring: true))
        env.refresher.set(.success(try Self.shifted(leg: 4, by: -170)))
        await f.refreshNavigation()
        await f.waitForReplan()
        f.acceptReplan(try #require(f.replanOffer).proposal.id)
        env.refresher.set(.success(try #require(Self.alternatives(fromHansaring: true)?.journeys[1])))
        env.set("07:37:00") // RB 25 ist 07:34 abgefahren, der Nutzer ist noch 200 m vom Gleis in Deutz
        f.navigationUpdate(position: GeoCoordinate(latitude: 50.9425, longitude: 6.9760), accuracy: 5, now: env.clock)
        #expect(f.navStep == .missedDeparture(vehicle: 2))
        await tick(f, env, at: "07:39:00") // RB 25 haette Hansaring um 07:38 erreicht
        #expect(f.pendingSwitch == nil)
        #expect(f.navJourney?.legs.contains { $0.line?.name == "ICE 47" } == true)
    }

    /// Der Puffer zittert, die beste Alternative wechselt: derselbe Vorschlag (ID), die bisherige bleibt, solange sie
    /// erreichbar ist, und im Hintergrund kommt nur eine Mitteilung mit Ton.
    @Test func flappingBestAlternativeKeepsTheProposalAndAlertsOnce() async throws {
        let env = Env()
        let f = await navigating(env)
        env.planner.setResponse(Self.alternatives(early: "07:37:30"))
        f.movedToBackground()
        try await refresh(f, env, iceDelay: 180) // Suchzeit 07:35: Tram 7 um 07:37:30 erreichbar und beste
        let offer = try #require(f.replanOffer)
        #expect(offer.proposal.alternativeIndex == 2)
        for delay in [360, 180, 360] { try await refresh(f, env, iceDelay: delay) }
        #expect(f.replanOffer?.proposal.id == offer.proposal.id)
        #expect(f.replanOffer?.proposal.alternativeIndex == 1)
        #expect(env.notifier.replanPostCount == 1)
        #expect(env.planner.callCount == 2)
    }

    /// "Wechseln" im Blatt, solange die Gehzeiten noch rechnen (`.skeleton`): auch dann vorgemerkt, nicht sofort.
    @Test func choosingWhileTheSheetIsStillCalibratingIsReservedToo() async throws {
        let env = Env(calibrationDelay: .milliseconds(400))
        let f = await navigating(env)
        f.openAlternatives(from: .nextStation)
        for _ in 0..<40 {
            if case .loaded = f.peek { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .loaded(_, nil, _) = f.peek else {
            Issue.record("Blatt sollte noch ohne Gehzeiten sein")
            return
        }
        f.chooseAlternative(1)
        #expect(f.pendingSwitch?.proposal.alternativeIndex == 1)
        #expect(f.navJourney?.legs.contains { $0.line?.name == "ICE 47" } == true)
    }

    /// Die Suchzeit des sichtbaren Vorschlags folgt der Echtzeit-Ankunft (Blatt und Pruefung am Suchstart).
    @Test func visibleProposalFollowsTheRealtimeArrival() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        let id = try #require(f.replanOffer?.proposal.id)
        try await refresh(f, env, iceDelay: 300) // Ankunft 07:37, keine neue Suche
        #expect(env.planner.callCount == 2)
        #expect(f.replanOffer?.proposal.id == id)
        #expect(f.replanOffer?.proposal.search.time == Self.at("07:37:00"))
        f.showProposal(id)
        #expect(f.peekStart?.time == Self.at("07:37:00"))
    }

    /// Rate-Limit aktiv: am Suchstart kein Refresh, der gemerkte Stand zaehlt.
    @Test func switchDuringRateLimitSkipsTheRefresh() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        f.acceptReplan(try #require(f.replanOffer).proposal.id)
        env.refresher.set(.failure(.rateLimited))
        env.blocked.withLock { $0 = Self.at("07:50:00") }
        await f.refreshNavigation()
        #expect(f.blockedUntil != nil)
        let calls = env.refresher.callCount
        await tick(f, env, at: "07:36:00")
        #expect(env.refresher.callCount == calls)
        #expect(f.navJourney?.legs.first { $0.line?.name == "1" }?.departure == Self.at("07:50:00"))
    }

    /// Antwortet der Refresh am Suchstart mit Rate-Limit, gilt die Sperre danach fuer die ganze App.
    @Test func rateLimitOfTheSwitchRefreshIsAdopted() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        f.acceptReplan(try #require(f.replanOffer).proposal.id)
        env.refresher.set(.failure(.rateLimited))
        env.blocked.withLock { $0 = Self.at("07:50:00") }
        await tick(f, env, at: "07:36:00")
        #expect(f.blockedUntil == Self.at("07:50:00"))
        #expect(f.navJourney?.legs.contains { $0.line?.name == "1" } == true)
    }

    /// Verwirft die Pruefung am Suchstart die vorgemerkte Alternative: kurzer Hinweis, im Hintergrund eine Mitteilung.
    @Test func droppedSwitchShowsANoticeAndAlertsInTheBackground() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        f.acceptReplan(try #require(f.replanOffer).proposal.id)
        f.movedToBackground()
        env.refresher.set(.success(try #require(Self.alternatives(tramCancelled: true)?.journeys[1])))
        await tick(f, env, at: "07:36:00")
        #expect(f.pendingSwitch == nil)
        #expect(f.replanBanner == .expired("Wechsel auf 1 nicht mehr möglich"))
        #expect(env.notifier.replanAlert?.title == "Wechsel auf 1 nicht mehr möglich")
    }

    /// Wischen der Mitteilung = "Behalten", aber nur fuer den laufenden, noch gueltigen Vorschlag.
    @Test func dismissingTheAlertDeclinesOnlyTheLiveProposal() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180)
        let id = try #require(f.replanOffer?.proposal.id)
        #expect(SystemNotifier.replanCategory.options.contains(.customDismissAction))
        f.declineReplan(UUID())
        #expect(f.replanOffer != nil)
        env.set("07:35:00") // Suchstart erreicht, noch kein Tick
        f.declineReplan(id)
        #expect(f.replanOffer != nil)
    }

    /// Bestaetigt wird die angetippte Fahrt, nicht die Zeile: hat sich die Liste veraendert, zaehlt dieselbe Verbindung.
    @Test func choosingByJourneyFindsTheSameTrip() async throws {
        let env = Env()
        let f = await navigating(env)
        f.openAlternatives(from: .nextStation)
        await f.waitForPeek()
        let tram = try #require(Self.alternatives()?.journeys[1])
        f.chooseAlternative(tram)
        #expect(f.pendingSwitch?.proposal.alternativeIndex == 1)
    }

    /// Vorgemerkt ab Hansaring, am Gleis des RB 25 faellt er aus: "fällt aus" bleibt stehen, "vorgemerkt" ersetzt nur
    /// "reicht nicht" eines Anschlusses nach dem Ausstieg.
    @Test func reservedReplacesOnlyTheBrokenConnectionAfterAlighting() throws {
        let base = try RouteOverviewTests.journey()
        let cancelled = try ViaFlowTests.changed(base) { legs in legs[2]["cancelled"] = true }
        func hint(_ journey: Journey, _ step: NavigationStep, at time: String) -> NowCard.Hint? {
            NavigationPresenter.card(NavigationPresenter.Input(
                step: step, journey: journey, geometry: base, walks: [:], position: nil, now: Self.at(time), pace: WalkingPaceFactor(),
                destinationLabel: "Weyertal 119a", startedAt: nil, expired: false,
                replan: .reserved("Wechsel auf 1 vorgemerkt", alighting: 2))).hint
        }
        #expect(hint(cancelled, .waitingAtPlatform(vehicle: 2), at: "07:33:00")?.text == "RB 25 fällt aus.")
        let broken = try Self.shifted(leg: 4, by: -170) // Tram 12 am Hansaring reicht nicht
        #expect(hint(broken, .onBoardTransit(vehicle: 0), at: "07:20:00")?.text == "Wechsel auf 1 vorgemerkt")
    }

    // MARK: Re-Review

    /// RB 25 (B) abgelehnt, Ausfall Tram 12 (C) uebernommen: nach dem Aussteigen aus dem ICE gibt es keine Suchen mehr, B bleibt
    /// trotzdem abgelehnt. Die Vormerkung ab Hansaring bleibt, keine weitere Mitteilung.
    @Test func declinedEarlierVehicleKeepsTheReservationAfterAlighting() async throws {
        let env = Env()
        let f = await navigating(env)
        f.movedToBackground()
        // ICE an 07:33:30, RB 25 ab 07:34: Puffer -70 s; Tram 12 faellt aus
        env.refresher.set(.success(try ViaFlowTests.changed(RouteOverviewTests.journey(iceDelay: 90)) { legs in
            legs[4]["cancelled"] = true
        }))
        await f.refreshNavigation()
        await f.waitForReplan()
        let first = try #require(f.replanOffer)
        #expect(first.proposal.search.trigger == .connectionBroken(vehicle: 2))
        f.declineReplan(first.proposal.id)
        env.planner.setResponse(Self.alternatives(fromHansaring: true))
        await tick(f, env, at: "07:11:00")
        let second = try #require(f.replanOffer)
        #expect(second.proposal.search.trigger == .tripCancelled(vehicle: 4))
        f.acceptReplan(second.proposal.id)
        await f.waitForReplan()
        let posts = env.notifier.replanPostCount
        await tick(f, env, at: "07:33:40")
        #expect(f.navStep == .transferRouting(from: 0, to: 2))
        #expect(f.pendingSwitch?.proposal.id == second.proposal.id)
        #expect(env.notifier.replanPostCount == posts)
    }

    /// Spaeter Tick am Suchstart (Hintergrund, langsamer Refresh): die Alternative muss ab jetzt erreichbar sein, nicht ab der
    /// Ankunft. 07:48 + 120 s Weg + 120 s Puffer liegt nach der Tram um 07:50.
    @Test func switchIsCheckedFromNowWhenTheTickComesLate() async throws {
        let env = Env()
        let f = await navigating(env)
        try await refresh(f, env, iceDelay: 180) // Ankunft Deutz 07:35
        f.acceptReplan(try #require(f.replanOffer).proposal.id)
        env.refresher.set(.success(try #require(Self.alternatives()?.journeys[1])))
        await tick(f, env, at: "07:48:00")
        #expect(f.pendingSwitch == nil)
        #expect(f.replanBanner == .expired("Wechsel auf 1 nicht mehr möglich"))
        #expect(f.navJourney?.legs.contains { $0.line?.name == "ICE 47" } == true)
    }

    /// Auf dem Weg zum RB 25 (Ausstiegsfahrzeug der Vormerkung ab Hansaring) zeigt die Position: reicht nicht mehr. Die
    /// Vormerkung entfaellt im selben Tick, nicht erst im naechsten.
    @Test func liveMissOnTheWayToTheAlightingVehicleDropsTheReservationAtOnce() async throws {
        let env = Env()
        let f = await navigating(env)
        env.planner.setResponse(Self.alternatives(fromHansaring: true))
        env.refresher.set(.success(try Self.shifted(leg: 4, by: -170))) // Tram 12 am Hansaring reicht nicht, im ICE
        await f.refreshNavigation()
        await f.waitForReplan()
        f.acceptReplan(try #require(f.replanOffer).proposal.id)
        #expect(f.pendingSwitch != nil)
        env.set("07:33:00") // ICE an 07:32, RB 25 ab 07:34; 200 m vom Gleis
        f.navigationUpdate(position: GeoCoordinate(latitude: 50.9425, longitude: 6.9760), accuracy: 5, now: env.clock)
        #expect(f.navStep == .transferRouting(from: 0, to: 2))
        #expect(f.pendingSwitch == nil)
    }

    // MARK: Re-Review 2

    /// Wie oben, aber der RB 25 wurde vorher behalten (Echtzeit -70 s): das Ablehnen galt der Echtzeit-Lage. Zeigt die
    /// Position, dass er wirklich verpasst ist, entfaellt die Vormerkung ab Hansaring trotzdem sofort.
    @Test func liveMissDropsTheReservationEvenWhenTheVehicleWasDeclined() async throws {
        let env = Env()
        let f = await navigating(env)
        // ICE an 07:33:30, RB 25 ab 07:34: Puffer -70 s; Tram 12 faellt aus
        env.refresher.set(.success(try ViaFlowTests.changed(RouteOverviewTests.journey(iceDelay: 90)) { legs in
            legs[4]["cancelled"] = true
        }))
        await f.refreshNavigation()
        await f.waitForReplan()
        let first = try #require(f.replanOffer)
        #expect(first.proposal.search.trigger == .connectionBroken(vehicle: 2))
        f.declineReplan(first.proposal.id)
        env.planner.setResponse(Self.alternatives(fromHansaring: true))
        await tick(f, env, at: "07:11:00")
        let second = try #require(f.replanOffer)
        f.acceptReplan(second.proposal.id)
        #expect(f.pendingSwitch != nil)
        env.set("07:33:40") // 200 m vom Gleis, 20 s bis zur Abfahrt
        f.navigationUpdate(position: GeoCoordinate(latitude: 50.9425, longitude: 6.9760), accuracy: 5, now: env.clock)
        #expect(f.navStep == .transferRouting(from: 0, to: 2))
        #expect(f.pendingSwitch == nil)
    }

    /// Wechsel ab Deutz gewaehlt, am Suchstart startet der Wechsel; waehrend des Refresh kommt ein Fix 1 km von Deutz bei
    /// noch laufendem Umstiegsschritt aus dem ICE (Zug spaeter als geschaetzt). Gewechselt wird nicht, die Vormerkung bleibt.
    @Test func switchWaitsWhenAFixDuringTheRefreshIsFarFromTheSearchStart() async throws {
        let env = Env()
        let f = await navigating(env)
        f.openAlternatives(from: .nextStation)
        await f.waitForPeek()
        f.chooseAlternative(1)
        env.refresher.set(.success(try #require(Self.alternatives()?.journeys[1])))
        env.set("07:33:00") // ICE an 07:32, RB 25 ab 07:34
        f.navigationUpdate(position: nil, now: env.clock)
        f.navigationUpdate(position: GeoCoordinate(latitude: 50.9499, longitude: 6.9750), accuracy: 5, now: env.clock)
        await f.waitForReplan()
        #expect(f.navStep == .transferRouting(from: 0, to: 2))
        #expect(f.pendingSwitch != nil)
        #expect(f.navJourney?.legs.contains { $0.line?.name == "ICE 47" } == true)
    }

    /// Im Vordergrund steht der Vorschlag in der Jetzt-Karte: Mitteilung nur still in der Liste. Erinnerungen weiter mit
    /// Banner und Ton.
    @Test func replanAlertIsSilentInTheForeground() {
        #expect(SystemNotifier.foregroundPresentation(category: SystemNotifier.replanCategoryID) == [.list])
        #expect(SystemNotifier.foregroundPresentation(category: SystemNotifier.category.identifier) == [.banner, .list, .sound])
    }
}
#endif
