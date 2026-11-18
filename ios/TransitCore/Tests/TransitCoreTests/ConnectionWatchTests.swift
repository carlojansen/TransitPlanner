import Foundation
import Testing
@testable import TransitCore

/// Fahrt aus Leg-Beschreibungen (Minuten ab 08:00 UTC), ohne Fixture-Datei.
private struct L {
    var walk = false
    var trip = "t"
    var dep: Int
    var arr: Int
    var from = "a"
    var to = "b"
    var cancelled = false
    /// Verspaetung in Minuten (nur Echtzeit-Ankunft/Abfahrt)
    var delay = 0
    var seconds: Int? = nil
    var noTrip = false
}

private func time(_ minutes: Int, seconds: Int = 0) -> String {
    let d = Date.iso("2026-11-20T08:00:00Z").addingTimeInterval(TimeInterval(minutes * 60 + seconds))
    return d.formatted(.iso8601)
}

private func place(_ id: String) -> String {
    #"{"kind":"stop","id":"\#(id)","name":"Halt \#(id)","latitude":51.0,"longitude":7.0}"#
}

private func journeyText(_ legs: [L], cancelled: Bool = false) -> String {
    let json = legs.enumerated().map { i, l in
        let line = l.walk ? #","isTransfer":true,"distanceMeters":100"# :
            #","line":{"name":"\#(l.trip)"}\#(l.noTrip ? "" : #","tripId":"\#(l.trip)""#)"#
        return #"{"index":\#(i),"mode":"\#(l.walk ? "walk" : "regional")","origin":\#(place(l.from)),"destination":\#(place(l.to)),"#
            + #""departure":"\#(time(l.dep + l.delay))","plannedDeparture":"\#(time(l.dep))","arrival":"\#(time(l.arr + l.delay))","#
            + #""plannedArrival":"\#(time(l.arr))","durationSeconds":\#(l.seconds ?? (l.arr - l.dep) * 60),"realtime":true,"#
            + #""cancelled":\#(l.cancelled)\#(line)}"#
    }.joined(separator: ",")
    let text = #"{"refreshToken":null,"departure":"\#(time(0))","arrival":"\#(time(60))","durationSeconds":3600,"transfers":1,"#
        + #""modes":["regional"],"cancelled":\#(cancelled),"realtime":true,"hasPolylines":false,"legs":[\#(json)],"remarks":[]}"#
    return text
}

private func journey(_ legs: [L], cancelled: Bool = false) throws -> Journey {
    try TransitJSON.decoder().decode(Journey.self, from: Data(journeyText(legs, cancelled: cancelled).utf8))
}

private func calibrated(_ j: Journey, walks: [Int: Int] = [:]) -> CalibratedJourney {
    let fixed = Dictionary(uniqueKeysWithValues: walks.map { ($0.key, WalkEstimate(legIndex: $0.key, seconds: $0.value, distanceMeters: nil, source: .timetable)) })
    return CalibratedJourney(journey: j, walks: fixed, transfers: HybridRouteCalculator.transferChecks(j, walks: fixed))
}

private func at(_ minutes: Int, seconds: Int = 0) -> Date { Date.iso(time(minutes, seconds: seconds)) }

/// A: 08:00-08:30 an "deutz", 120 s Fussweg, B: ab 08:40 (Puffer planmaessig 480 s).
private func base(delay: Int = 0, cancelledB: Bool = false) throws -> Journey {
    try journey([
        L(trip: "A", dep: 0, arr: 30, from: "start", to: "deutz", delay: delay),
        L(walk: true, dep: 30, arr: 32, from: "deutz", to: "gleis9", seconds: 120),
        L(trip: "B", dep: 40, arr: 60, from: "gleis9", to: "ziel", cancelled: cancelledB),
    ])
}

private let pace = WalkingPaceFactor()

@Suite struct ConnectionWatchTriggerTests {
    private func evaluate(_ j: Journey, _ step: NavigationStep, minute: Int, latched: Set<Int> = []) -> (searches: [ReplanSearch], latched: Set<Int>) {
        ConnectionWatch.evaluate(journey: j, step: step, latched: latched, walks: [:], now: at(minute), pace: pace)
    }

    @Test func punctualGivesNothing() throws {
        #expect(try evaluate(base(), .onBoardTransit(vehicle: 0), minute: 10).searches.first == nil)
    }

    @Test func delayWithoutConsequenceGivesNothing() throws {
        // 5 min Verspaetung: Puffer 480 - 300 = 180 s
        #expect(try evaluate(base(delay: 5), .onBoardTransit(vehicle: 0), minute: 10).searches.first == nil)
    }

    @Test func tightConnectionGivesNothing() throws {
        // 7 min: Puffer 60 s, knapp aber erreichbar
        #expect(try evaluate(base(delay: 7), .onBoardTransit(vehicle: 0), minute: 10).searches.first == nil)
    }

    @Test func brokenConnectionSearchesFromAlightingStopAtRealtimeArrival() throws {
        let result = try evaluate(base(delay: 9), .onBoardTransit(vehicle: 0), minute: 10)
        let search = try #require(result.searches.first)
        #expect(search.trigger == .connectionBroken(vehicle: 2))
        #expect(search.alightingVehicle == 0)
        #expect(search.start == .stop(id: "deutz", label: "Halt deutz"))
        #expect(search.time == at(39))
        #expect(search.bufferSeconds == -60)
    }

    @Test func searchTimeNeverBeforeNow() throws {
        // Echtzeit-Ankunft 08:39, jetzt 08:40 (Zug hat Verspaetung noch nicht eingeholt): Suchzeit ist jetzt, nicht die Vergangenheit
        let search = try #require(evaluate(base(delay: 9), .onBoardTransit(vehicle: 0), minute: 40).searches.first)
        #expect(search.time == at(40))
        let early = try #require(evaluate(base(delay: 9), .onBoardTransit(vehicle: 0), minute: 38).searches.first)
        #expect(early.time == at(39))
    }

    @Test func cancelledLaterVehicleTriggersEvenWhenPunctual() throws {
        let search = try #require(evaluate(base(cancelledB: true), .onBoardTransit(vehicle: 0), minute: 10).searches.first)
        #expect(search.trigger == .tripCancelled(vehicle: 2))
        #expect(search.bufferSeconds == ConnectionWatch.cancelledBuffer)
    }

    @Test func triggerAlsoInLast120SecondsBeforeAlighting() throws {
        let j = try base(delay: 9)
        let step = NavigationStep.transferRouting(from: 0, to: 2)
        // 08:38 = 60 s vor Echtzeit-Ankunft 08:39
        #expect(evaluate(j, step, minute: 38).searches.first != nil)
    }

    @Test func noTriggerAfterAlightingOrAtPlatformOrWalking() throws {
        let j = try base(delay: 9)
        #expect(evaluate(j, .transferRouting(from: 0, to: 2), minute: 41).searches.first == nil)
        #expect(evaluate(j, .waitingAtPlatform(vehicle: 2), minute: 41).searches.first == nil)
        #expect(evaluate(j, .approachingFirstStop(vehicle: 0), minute: 0).searches.first == nil)
        #expect(evaluate(j, .missedDeparture(vehicle: 2), minute: 41).searches.first == nil)
    }

    @Test func failureOfVehicleWaitedForAtPlatformGivesNoProposal() throws {
        #expect(try evaluate(base(cancelledB: true), .waitingAtPlatform(vehicle: 2), minute: 35).searches.first == nil)
    }

    @Test func waitingAtPlatformGivesNoProposalEvenWhenLaterVehicleFails() throws {
        let j = try journey([
            L(trip: "A", dep: 0, arr: 30, from: "start", to: "deutz"),
            L(walk: true, dep: 30, arr: 32, from: "deutz", to: "gleis9", seconds: 120),
            L(trip: "B", dep: 40, arr: 60, from: "gleis9", to: "x"),
            L(walk: true, dep: 60, arr: 62, from: "x", to: "y", seconds: 120),
            L(trip: "C", dep: 70, arr: 90, from: "y", to: "ziel", cancelled: true),
        ])
        #expect(evaluate(j, .waitingAtPlatform(vehicle: 2), minute: 35).searches.first == nil)
        // im Fahrzeug B dagegen gilt der Ausfall von C
        #expect(evaluate(j, .onBoardTransit(vehicle: 2), minute: 45).searches.first?.trigger == .tripCancelled(vehicle: 4))
    }

    @Test func secondAffectedVehicleStaysVisibleWhenFirstDeclined() throws {
        // B reicht nicht (-60 s), C faellt aus: beide kommen, frueheste zuerst
        let j = try journey([
            L(trip: "A", dep: 0, arr: 30, from: "start", to: "deutz", delay: 9),
            L(walk: true, dep: 30, arr: 32, from: "deutz", to: "gleis9", seconds: 120),
            L(trip: "B", dep: 40, arr: 60, from: "gleis9", to: "x"),
            L(walk: true, dep: 60, arr: 62, from: "x", to: "y", seconds: 120),
            L(trip: "C", dep: 70, arr: 90, from: "y", to: "ziel", cancelled: true),
        ])
        let result = evaluate(j, .onBoardTransit(vehicle: 0), minute: 10)
        #expect(result.searches.map(\.trigger) == [.connectionBroken(vehicle: 2), .tripCancelled(vehicle: 4)])
        #expect(result.searches[1].alightingVehicle == 2)
        var memory = ReplanMemory()
        memory.decline(result.searches[0])
        #expect(memory.next(in: result.searches, now: at(10)) == result.searches[1])
        memory.decline(result.searches[1])
        #expect(memory.next(in: result.searches, now: at(10)) == nil)
    }

    @Test func searchesRunOneAfterAnotherUntilAnswered() throws {
        let j = try journey([
            L(trip: "A", dep: 0, arr: 30, from: "start", to: "deutz", delay: 9),
            L(walk: true, dep: 30, arr: 32, from: "deutz", to: "gleis9", seconds: 120),
            L(trip: "B", dep: 40, arr: 60, from: "gleis9", to: "x"),
            L(walk: true, dep: 60, arr: 62, from: "x", to: "y", seconds: 120),
            L(trip: "C", dep: 70, arr: 90, from: "y", to: "ziel", cancelled: true),
        ])
        let result = evaluate(j, .onBoardTransit(vehicle: 0), minute: 10)
        var memory = ReplanMemory()
        memory.markSearched(result.searches[0])
        // B gesucht, unbeantwortet: C wartet
        #expect(memory.next(in: result.searches, now: at(10)) == nil)
        // B ohne Alternative oder abgelehnt: C ist dran
        memory.decline(result.searches[0])
        #expect(memory.next(in: result.searches, now: at(10)) == result.searches[1])
    }

    @Test func cancellationGoesBeforeDelayOnSameVehicle() throws {
        let j = try journey([
            L(trip: "A", dep: 0, arr: 30, from: "start", to: "deutz", delay: 9),
            L(walk: true, dep: 30, arr: 32, from: "deutz", to: "gleis9", seconds: 120),
            L(trip: "B", dep: 40, arr: 60, from: "gleis9", to: "ziel", cancelled: true),
        ])
        let found = evaluate(j, .onBoardTransit(vehicle: 0), minute: 10).searches
        #expect(found.count == 1)
        #expect(found.first?.trigger == .tripCancelled(vehicle: 2))
    }

    @Test func boundaryNowEqualsArrivalIsAlreadyAlighted() throws {
        let j = try base(delay: 9)
        #expect(evaluate(j, .transferRouting(from: 0, to: 2), minute: 39).searches.isEmpty)
        #expect(!evaluate(j, .transferRouting(from: 0, to: 2), minute: 38).searches.isEmpty)
    }

    @Test func noTriggerOnArrivalOrFinalWalk() throws {
        let j = try base(cancelledB: true)
        #expect(evaluate(j, .arrived, minute: 10).searches.isEmpty)
        #expect(evaluate(j, .finalWalkToDestination, minute: 10).searches.isEmpty)
    }

    @Test func stopWithoutIdFallsBackToCoordinateAndWithoutBothGivesNothing() throws {
        var text = journeyText([
            L(trip: "A", dep: 0, arr: 30, from: "start", to: "deutz", delay: 9),
            L(walk: true, dep: 30, arr: 32, from: "deutz", to: "gleis9", seconds: 120),
            L(trip: "B", dep: 40, arr: 60, from: "gleis9", to: "ziel"),
        ])
        text = text.replacingOccurrences(of: #""id":"deutz","#, with: "")
        let coordinateOnly = try TransitJSON.decoder().decode(Journey.self, from: Data(text.utf8))
        let found = ConnectionWatch.evaluate(journey: coordinateOnly, step: .onBoardTransit(vehicle: 0), latched: [], walks: [:], now: at(10), pace: pace)
        if case .coordinate = found.searches.first?.start {} else { Issue.record("Koordinatenstart erwartet") }
        let bare = text.replacingOccurrences(of: #""latitude":51.0,"longitude":7.0"#, with: #""latitude":null,"longitude":null"#)
        // Halt ohne ID und ohne Koordinate: keine Suche statt Absturz
        let none = try TransitJSON.decoder().decode(Journey.self, from: Data(bare.utf8))
        #expect(ConnectionWatch.evaluate(journey: none, step: .onBoardTransit(vehicle: 0), latched: [], walks: [:], now: at(10), pace: pace).searches.isEmpty)
    }

    @Test func vehicleWithoutDepartureTimeIsReleased() throws {
        let text = journeyText([
            L(trip: "A", dep: 0, arr: 30, from: "start", to: "deutz", delay: 9),
            L(walk: true, dep: 30, arr: 32, from: "deutz", to: "gleis9", seconds: 120),
            L(trip: "B", dep: 40, arr: 60, from: "gleis9", to: "ziel"),
        ]).replacingOccurrences(of: #""departure":"\#(time(40))","#, with: "").replacingOccurrences(of: #""plannedDeparture":"\#(time(40))","#, with: "")
        let noTimes = try TransitJSON.decoder().decode(Journey.self, from: Data(text.utf8))
        let r = ConnectionWatch.evaluate(journey: noTimes, step: .onBoardTransit(vehicle: 0), latched: [2], walks: [:], now: at(10), pace: pace)
        #expect(r.searches.isEmpty)
        #expect(r.latched.isEmpty)
    }

    @Test func lastVehicleHasNoConnection() throws {
        let j = try base(delay: 30)
        #expect(evaluate(j, .onBoardTransit(vehicle: 2), minute: 50).searches.first == nil)
    }

    @Test func latchHoldsUntilConnectionRecoversWithSlack() throws {
        // Puffer um 0 s: erst gebrochen, dann (Echtzeit-Zittern) wieder 60 s -> bleibt aktiv, erst ab 120 s faellt es
        let broken = try evaluate(base(delay: 9), .onBoardTransit(vehicle: 0), minute: 10)
        #expect(broken.latched == [2])
        let flapping = try evaluate(base(delay: 7), .onBoardTransit(vehicle: 0), minute: 11, latched: broken.latched)
        #expect(flapping.searches.first != nil)
        #expect(flapping.latched == [2])
        let recovered = try evaluate(base(delay: 6), .onBoardTransit(vehicle: 0), minute: 12, latched: flapping.latched)
        #expect(recovered.searches.first == nil)
        #expect(recovered.latched.isEmpty)
    }

    /// Nach dem Ausstieg und am Gleis rasten spaetere Anschluesse weiter ein und frei (Live Activity), gesucht wird nicht.
    @Test func laterConnectionLatchesAndReleasesAfterAlightingWithoutSearch() throws {
        func trip(delayB: Int) throws -> Journey {
            try journey([
                L(trip: "A", dep: 0, arr: 30, from: "start", to: "deutz"),
                L(walk: true, dep: 30, arr: 32, from: "deutz", to: "gleis9", seconds: 120),
                L(trip: "B", dep: 40, arr: 60, from: "gleis9", to: "x", delay: delayB),
                L(walk: true, dep: 60, arr: 62, from: "x", to: "y", seconds: 120),
                L(trip: "C", dep: 70, arr: 90, from: "y", to: "ziel"),
            ])
        }
        // B 9 min spaet: C reicht nicht (-60 s)
        let walking = try evaluate(trip(delayB: 9), .transferRouting(from: 0, to: 2), minute: 31)
        #expect(walking.latched == [4])
        #expect(walking.searches.isEmpty)
        let platform = try evaluate(trip(delayB: 9), .waitingAtPlatform(vehicle: 2), minute: 35)
        #expect(platform.latched == [4] && platform.searches.isEmpty)
        // B wieder puenktlich: frei, auch ohne im Fahrzeug zu sitzen
        #expect(try evaluate(trip(delayB: 0), .transferRouting(from: 0, to: 2), minute: 31, latched: [4]).latched.isEmpty)
        #expect(try evaluate(trip(delayB: 0), .waitingAtPlatform(vehicle: 2), minute: 35, latched: [4]).latched.isEmpty)
    }

    @Test func chosenSwitchOnlyWhileBoardedFromTheAlightingStop() throws {
        let j = try base(delay: 9)
        let s = try #require(ConnectionWatch.chosenSwitch(journey: j, step: .onBoardTransit(vehicle: 0), now: at(10), pace: pace))
        #expect(s.trigger == .chosen(vehicle: 0) && s.alightingVehicle == 0)
        #expect(s.start == .stop(id: "deutz", label: "Halt deutz"))
        #expect(s.time == at(39))
        #expect(ConnectionWatch.chosenSwitch(journey: j, step: .transferRouting(from: 0, to: 2), now: at(40), pace: pace) == nil)
        #expect(ConnectionWatch.chosenSwitch(journey: j, step: .approachingFirstStop(vehicle: 0), now: at(0), pace: pace) == nil)
        // kein betroffenes Fahrzeug: auch eine Alternative mit B ist erlaubt, Gehweg und Puffer gelten weiter
        let withB = try calibrated(journey([L(trip: "B", dep: 41, arr: 60, from: "gleis9", to: "ziel")]))
        #expect(ConnectionWatch.pick([withB], for: s) == 0)
        let tooEarly = try calibrated(journey([L(trip: "B", dep: 40, arr: 60, from: "gleis9", to: "ziel")]))
        #expect(ConnectionWatch.pick([tooEarly], for: s) == nil)
    }

    @Test func latchOfEarlierVehicleIsIgnoredOnceBoarded() throws {
        // eingerastet fuer Fahrzeug 0, im Fahrzeug 2 gilt es nicht mehr
        let j = try base(delay: 0)
        #expect(evaluate(j, .onBoardTransit(vehicle: 2), minute: 50, latched: [0]).searches.first == nil)
    }
}

@Suite struct ConnectionWatchPickTests {
    private func search() throws -> ReplanSearch {
        try #require(ConnectionWatch.evaluate(journey: base(delay: 9), step: .onBoardTransit(vehicle: 0), latched: [], walks: [:],
                                              now: at(10), pace: pace).searches.first)
    }

    private func alt(_ trip: String, dep: Int, access: Int? = nil, cancelled: Bool = false, extra: [L] = []) throws -> CalibratedJourney {
        var legs: [L] = []
        var walks: [Int: Int] = [:]
        if let access {
            legs.append(L(walk: true, dep: dep - 3, arr: dep, from: "deutz", to: "gleis4", seconds: access))
            walks[0] = access
        }
        legs.append(L(trip: trip, dep: dep, arr: dep + 20, from: "gleis4", to: "ziel", cancelled: cancelled))
        return try calibrated(journey(legs + extra), walks: walks)
    }

    @Test func firstDepartureNeedsSearchTimePlusSlack() throws {
        let s = try search() // Suchzeit 08:39, Grenze 08:41
        #expect(try ConnectionWatch.pick([alt("C", dep: 39), alt("D", dep: 40)], for: s) == nil)
        #expect(try ConnectionWatch.pick([alt("C", dep: 39), alt("D", dep: 41)], for: s) == 1)
    }

    /// Beim Wechsel am Suchstart zaehlt die neue Echtzeit-Ankunft: kam der Zug spaeter an, reicht die Alternative nicht mehr.
    @Test func searchAtLaterArrivalRejectsFormerlyReachable() throws {
        let s = try search() // Suchzeit 08:39
        #expect(try ConnectionWatch.pick([alt("D", dep: 41)], for: s) == 0)
        #expect(try ConnectionWatch.pick([alt("D", dep: 41)], for: s.at(at(40))) == nil)
        #expect(s.at(at(40)).key == s.key && s.at(at(40)).alightingVehicle == s.alightingVehicle)
    }

    @Test func accessWalkAtStartCounts() throws {
        let s = try search()
        // 08:42 ab, 120 s Gehweg: frueheste 08:43 -> nicht erreichbar; 08:44 ja
        #expect(try ConnectionWatch.pick([alt("C", dep: 42, access: 120), alt("D", dep: 44, access: 120)], for: s) == 1)
    }

    @Test func affectedVehicleNeverProposed() throws {
        let s = try search()
        #expect(try ConnectionWatch.pick([alt("B", dep: 50)], for: s) == nil)
        // auch als zweites Fahrzeug einer Alternative
        #expect(try ConnectionWatch.pick([alt("C", dep: 45, extra: [L(trip: "B", dep: 70, arr: 80, from: "ziel", to: "x")])], for: s) == nil)
    }

    @Test func cancelledAlternativeSkippedAndBestRankedWins() throws {
        let s = try search()
        #expect(try ConnectionWatch.pick([alt("C", dep: 45, cancelled: true), alt("D", dep: 50), alt("E", dep: 46)], for: s) == 2)
    }

    @Test func rankBeatsListOrderAfterExcludingTheAffectedVehicle() throws {
        let s = try search()
        // Liste in Abfahrtsreihenfolge: B (betroffen, beste), D 08:41 -> 09:01, E 08:44 mit 5 min Gehweg -> 09:04 + Aufschlag
        #expect(try ConnectionWatch.pick([alt("B", dep: 41), alt("D", dep: 50), alt("E", dep: 44)], for: s) == 2)
    }

    @Test func stayingOnTheSameTrainNeedsNoWalkOrSlack() throws {
        let s = try search() // Suchzeit 08:39, Ausstiegsfahrzeug "A"
        // A faehrt um 08:40 ab "deutz" weiter: reicht, obwohl vor Suchzeit + 120 s
        let stay = try calibrated(journey([L(trip: "A", dep: 40, arr: 70, from: "deutz", to: "ziel")]))
        #expect(ConnectionWatch.pick([stay], for: s) == 0)
        // Abfahrt vor der Ankunft zaehlt nicht
        let before = try calibrated(journey([L(trip: "A", dep: 38, arr: 70, from: "deutz", to: "ziel")]))
        #expect(ConnectionWatch.pick([before], for: s) == nil)
        // jedes andere Fahrzeug braucht weiter den Puffer
        #expect(try ConnectionWatch.pick([alt("C", dep: 40)], for: s) == nil)
    }

    @Test func keyWithoutTripIdMatchesByLineTimeAndOrigin() throws {
        let a = try journey([L(trip: "X", dep: 40, arr: 50, from: "p", to: "q", noTrip: true)]).legs[0]
        let same = try journey([L(trip: "X", dep: 40, arr: 50, from: "p", to: "r")]).legs[0]
        let otherStop = try journey([L(trip: "X", dep: 40, arr: 50, from: "other", to: "q", noTrip: true)]).legs[0]
        let withId = try journey([L(trip: "X", dep: 40, arr: 50, from: "p", to: "q")]).legs[0]
        #expect(ReplanKey(a).matches(same))
        #expect(!ReplanKey(a).matches(otherStop))
        #expect(ReplanKey(withId).matches(a))
    }

    @Test func keyIsStableWhenPlatformChanges() throws {
        let p1 = try journey([L(trip: "X", dep: 40, arr: 50, from: "gleis1", to: "q")]).legs[0]
        let p2 = try journey([L(trip: "X", dep: 40, arr: 50, from: "gleis2", to: "q")]).legs[0]
        #expect(ReplanKey(p1) == ReplanKey(p2))
        #expect(ReplanKey(p1).hashValue == ReplanKey(p2).hashValue)
    }

    /// Ohne Fahrt-ID: ein Gleiswechsel (andere Bahnsteig-ID, gleicher Haltname) bleibt dasselbe Fahrzeug.
    @Test func keyWithoutTripIdIsStableWhenPlatformChanges() throws {
        let one = journeyText([L(trip: "X", dep: 40, arr: 50, from: "gleis1", to: "q", noTrip: true)])
        let two = one.replacingOccurrences(of: #""id":"gleis1""#, with: #""id":"gleis2""#)
        let a = try TransitJSON.decoder().decode(Journey.self, from: Data(one.utf8)).legs[0]
        let b = try TransitJSON.decoder().decode(Journey.self, from: Data(two.utf8)).legs[0]
        #expect(a.origin.id != b.origin.id)
        #expect(ReplanKey(a) == ReplanKey(b))
        #expect(ReplanKey(a).matches(b))
    }

    /// Die Alternative muss am Suchstart beginnen: gleiche ID, Bahnsteig der Station ("<id>:3") oder in der Naehe.
    /// Ein anderer Halt 2 km weiter ist keine Alternative ab dem Ausstieg.
    @Test func alternativeMustStartAtTheSearchStart() throws {
        let s = try search() // Start "deutz" bei 51.0/7.0
        #expect(try ConnectionWatch.pick([from("elsewhere", latitude: "51.02")], for: s) == nil)
        // 2,2 km Luftlinie zum Bahnsteig: rund 29 Min. Weg, darum spaete Abfahrt
        #expect(try ConnectionWatch.pick([from("deutz:3:1", latitude: "51.02", dep: 75)], for: s) == 0)
        #expect(try ConnectionWatch.pick([from("gleis4", latitude: "51.001")], for: s) == 0)
    }

    /// Alternative, die ohne Fussweg-Abschnitt an einem anderen Halt beginnt: die Luftlinie vom Suchstart zaehlt mit Gehtempo
    /// als Weg (vorher 0 s); bei gleicher Halt-ID kein Weg.
    @Test func accessWithoutWalkLegUsesTheStraightLineAndPace() throws {
        let s = try search() // Suchzeit 08:39, ohne Weg reicht 08:41
        // 111 m: 86 s Weg -> fruehestens 08:42:26
        #expect(try ConnectionWatch.pick([from("gleis4", latitude: "51.001", dep: 42)], for: s) == nil)
        #expect(try ConnectionWatch.pick([from("gleis4", latitude: "51.001", dep: 43)], for: s) == 0)
        #expect(try ConnectionWatch.pick([from("deutz", latitude: "51.001", dep: 41)], for: s) == 0)
        // doppelt so langsam: 172 s -> fruehestens 08:43:52
        let slow = try #require(ConnectionWatch.evaluate(journey: base(delay: 9), step: .onBoardTransit(vehicle: 0), latched: [],
                                                         walks: [:], now: at(10), pace: WalkingPaceFactor(learned: 2)).searches.first)
        #expect(try ConnectionWatch.pick([from("gleis4", latitude: "51.001", dep: 43)], for: slow) == nil)
    }

    /// Blatt noch ohne Gehzeiten (`.skeleton`): die Fahrplan-Gehzeit zaehlt mit Gehtempo, wie der Rueckfall der Kalibrierung.
    @Test func timetableWalksUseThePace() throws {
        let s = try search() // Suchzeit 08:39
        // 120 s Zugangsweg, Abfahrt 08:43: mit Tempo 1.0 genau erreichbar (08:39 + 120 s + 120 s), mit 1.5 (180 s) nicht
        let j = try journey([
            L(walk: true, dep: 40, arr: 43, from: "deutz", to: "gleis4", seconds: 120),
            L(trip: "D", dep: 43, arr: 60, from: "gleis4", to: "ziel"),
        ])
        #expect(ConnectionWatch.pick([CalibratedJourney(timetable: j, pace: WalkingPaceFactor())], for: s) == 0)
        #expect(ConnectionWatch.pick([CalibratedJourney(timetable: j, pace: WalkingPaceFactor(learned: 1.5))], for: s) == nil)
        #expect(CalibratedJourney(timetable: j, pace: WalkingPaceFactor(learned: 1.5)).walks[0]?.seconds == 180)
    }

    /// Alternative mit einem Fahrzeug ab `id` (Koordinate mit anderer Breite als der Suchstart bei 51.0).
    private func from(_ id: String, latitude: String, dep: Int = 45) throws -> CalibratedJourney {
        let text = journeyText([L(trip: "D", dep: dep, arr: dep + 15, from: id, to: "ziel")])
            .replacingOccurrences(of: #""id":"\#(id)","name":"Halt \#(id)","latitude":51.0"#,
                                  with: #""id":"\#(id)","name":"Halt \#(id)","latitude":\#(latitude)"#)
        return calibrated(try TransitJSON.decoder().decode(Journey.self, from: Data(text.utf8)))
    }

    @Test func stayingOnTheSameTrainNeedsNoLeadingWalkAndATripId() throws {
        let s = try search()
        // Gehweg vor dem Ausstiegsfahrzeug: keine Ausnahme, 08:40 liegt vor Suchzeit + Gehweg + 120 s
        let walkFirst = try calibrated(journey([
            L(walk: true, dep: 39, arr: 40, from: "deutz", to: "s", seconds: 60),
            L(trip: "A", dep: 40, arr: 70, from: "s", to: "ziel"),
        ]), walks: [0: 60])
        #expect(ConnectionWatch.pick([walkFirst], for: s) == nil)
        // ohne Fahrt-ID wird die Weiterfahrt nicht erkannt
        let noId = try calibrated(journey([L(trip: "A", dep: 40, arr: 70, from: "deutz", to: "ziel", noTrip: true)]))
        #expect(ConnectionWatch.pick([noId], for: s) == nil)
    }

    @Test func alternativeWithMissedTransferSkipped() throws {
        let s = try search()
        // Alternative: C 08:45-09:05, 120 s Fussweg, D ab 09:06 -> Puffer -60 s
        let broken = try calibrated(journey([
            L(trip: "C", dep: 45, arr: 65, from: "gleis4", to: "m"),
            L(walk: true, dep: 65, arr: 67, from: "m", to: "n", seconds: 120),
            L(trip: "D", dep: 66, arr: 80, from: "n", to: "ziel"),
        ]), walks: [1: 120])
        #expect(ConnectionWatch.pick([broken], for: s) == nil)
    }

    @Test func walkOnlyAlternativeSkipped() throws {
        let s = try search()
        let walk = try calibrated(journey([L(walk: true, dep: 45, arr: 60, from: "deutz", to: "ziel")]))
        #expect(ConnectionWatch.pick([walk], for: s) == nil)
    }

    /// Die bisher vorgeschlagene Alternative bleibt, solange sie erreichbar ist; erst dann wird neu gewaehlt.
    @Test func keepsTheCurrentAlternativeWhileReachable() throws {
        let s = try search() // Suchzeit 08:39
        let list = try [alt("D", dep: 50), alt("E", dep: 46)]
        #expect(ConnectionWatch.pick(list, for: s) == 1)
        #expect(ConnectionWatch.pick(list, for: s, keeping: 0) == 0)
        #expect(ConnectionWatch.pick(list, for: s, keeping: 5) == 1)
        #expect(try ConnectionWatch.pick([alt("D", dep: 40), alt("E", dep: 46)], for: s, keeping: 0) == 1)
    }

    @Test func nothingWhenEmpty() throws {
        #expect(try ConnectionWatch.pick([], for: search()) == nil)
    }
}

/// Vormerkung ab "x" (Ausstieg aus B), betroffen ist C: A 08:00-08:30, B 08:40-09:00, C faellt aus.
@Suite struct PendingSwitchTests {
    private func trip(cancelledB: Bool = false) throws -> Journey {
        try journey([
            L(trip: "A", dep: 0, arr: 30, from: "start", to: "deutz"),
            L(walk: true, dep: 30, arr: 32, from: "deutz", to: "gleis9", seconds: 120),
            L(trip: "B", dep: 40, arr: 60, from: "gleis9", to: "x", cancelled: cancelledB),
            L(walk: true, dep: 60, arr: 62, from: "x", to: "y", seconds: 120),
            L(trip: "C", dep: 70, arr: 90, from: "y", to: "ziel", cancelled: true),
        ])
    }

    private func reserved() throws -> ReplanSearch {
        let found = ConnectionWatch.evaluate(journey: try trip(), step: .onBoardTransit(vehicle: 0), latched: [], walks: [:],
                                             now: at(10), pace: pace).searches
        let s = try #require(found.first)
        #expect(s.trigger == .tripCancelled(vehicle: 4) && s.alightingVehicle == 2)
        return s
    }

    private func state(_ step: NavigationStep, minute: Int, affected: Set<Int> = [], cancelledB: Bool = false) throws -> PendingSwitchStep {
        ConnectionWatch.pendingSwitch(try reserved(), journey: try trip(cancelledB: cancelledB), step: step, affected: affected, now: at(minute))
    }

    @Test func startsOnlyFromTheAlightingVehicleAfterItsArrival() throws {
        #expect(try state(.onBoardTransit(vehicle: 0), minute: 10) == .wait)
        #expect(try state(.onBoardTransit(vehicle: 2), minute: 59) == .wait)
        #expect(try state(.onBoardTransit(vehicle: 2), minute: 60) == .start(arrival: at(60)))
        #expect(try state(.transferRouting(from: 2, to: 4), minute: 61) == .start(arrival: at(60)))
        // Anschluss C verpasst (der Grund der Vormerkung) oder am Gleis von C: man ist am Suchstart
        #expect(try state(.missedDeparture(vehicle: 4), minute: 71) == .start(arrival: at(60)))
        #expect(try state(.waitingAtPlatform(vehicle: 4), minute: 65) == .start(arrival: at(60)))
        // vor der Ankunft nie, auch nicht im Fahrzeug selbst
        #expect(try state(.transferRouting(from: 2, to: 4), minute: 59) == .wait)
        // Uhrzeit allein reicht nicht: noch am Gleis bzw. auf dem Weg zu B
        #expect(try state(.waitingAtPlatform(vehicle: 2), minute: 61) == .wait)
        #expect(try state(.transferRouting(from: 0, to: 2), minute: 61) == .wait)
    }

    /// Schritt schon hinter dem Suchstart, bevor die Echtzeit-Ankunft von B erreicht ist: die Ankunft war zu spaet geschaetzt,
    /// der Nutzer ist schon weiter (im Anschluss C bzw. auf dem Weg zum Ziel). Verworfen, kein Wechsel an der falschen Station.
    /// Nach der Ankunft ist derselbe Schritt eine Fahrplan-Annahme (C faellt hier sogar aus, der Nutzer steht noch am
    /// Suchstart): gewechselt wird wie bisher.
    @Test func stepBeyondTheSearchStartBeforeTheArrivalDrops() throws {
        #expect(try state(.onBoardTransit(vehicle: 4), minute: 59) == .drop)
        #expect(try state(.finalWalkToDestination, minute: 59) == .drop)
        #expect(try state(.onBoardTransit(vehicle: 4), minute: 75) == .start(arrival: at(60)))
        #expect(try state(.finalWalkToDestination, minute: 95) == .start(arrival: at(60)))
        #expect(try state(.arrived, minute: 95) == .drop)
    }

    /// Weg zum Ziel gehoert nur zum Suchstart, wenn das Ausstiegsfahrzeug das letzte ist (Wechseln im letzten Fahrzeug).
    @Test func finalWalkIsTheSearchStartOnlyAfterTheLastVehicle() throws {
        let j = try trip()
        let s = try #require(ConnectionWatch.chosenSwitch(journey: j, step: .onBoardTransit(vehicle: 4), now: at(75), pace: pace))
        #expect(ConnectionWatch.pendingSwitch(s, journey: j, step: .finalWalkToDestination, affected: [], now: at(89)) == .wait)
        #expect(ConnectionWatch.pendingSwitch(s, journey: j, step: .finalWalkToDestination, affected: [], now: at(90)) == .start(arrival: at(90)))
    }

    @Test func droppedWhenAVehicleUpToTheAlightingOneBreaks() throws {
        #expect(try state(.onBoardTransit(vehicle: 0), minute: 10, cancelledB: true) == .drop)
        #expect(try state(.waitingAtPlatform(vehicle: 2), minute: 35, cancelledB: true) == .drop)
        #expect(try state(.onBoardTransit(vehicle: 0), minute: 10, affected: [2]) == .drop)
        #expect(try state(.missedDeparture(vehicle: 2), minute: 41) == .drop)
        // spaetere Anschluesse gehoeren zur Vormerkung, schon gefahrene zaehlen nicht
        #expect(try state(.onBoardTransit(vehicle: 0), minute: 10, affected: [4]) == .wait)
        #expect(try state(.onBoardTransit(vehicle: 2), minute: 45, affected: [0, 2]) == .wait)
    }
}

@Suite struct ReplanMemoryTests {
    /// Puffer des Anschlusses = 480 s - 60 s je Minute Verspaetung; nur ganze Minuten.
    private func search(buffer: Int) throws -> ReplanSearch {
        let j = try base(delay: (480 - buffer) / 60)
        return try #require(ConnectionWatch.evaluate(journey: j, step: .onBoardTransit(vehicle: 0), latched: [], walks: [:],
                                                     now: at(10), pace: pace).searches.first)
    }

    @Test func failuresAreCappedToo() throws {
        var memory = ReplanMemory()
        let s = try search(buffer: -60)
        for round in 1...ConnectionWatch.maxFailures {
            #expect(memory.maySearch(s, now: at(round * 10)))
            memory.markSearched(s)
            memory.markFailed(s, now: at(round * 10), blockedUntil: nil)
        }
        #expect(memory.failureCount == ConnectionWatch.maxFailures)
        #expect(!memory.maySearch(s, now: at(100)))
    }

    @Test func markFailedWithoutSearchChangesNothing() throws {
        var memory = ReplanMemory()
        let s = try search(buffer: -60)
        memory.markFailed(s, now: at(10), blockedUntil: at(50))
        #expect(memory.failureCount == 0)
        #expect(memory.maySearch(s, now: at(10)))
    }

    @Test func declineKeepsVehicleNotKind() throws {
        let broken = try search(buffer: -60)
        let cancelled = try #require(ConnectionWatch.evaluate(journey: base(cancelledB: true), step: .onBoardTransit(vehicle: 0), latched: [], walks: [:],
                                                              now: at(10), pace: pace).searches.first)
        var a = ReplanMemory()
        a.decline(broken)
        #expect(a.maySearch(cancelled, now: at(10))) // "reicht nicht" behalten, dann Ausfall: neue Frage
        var b = ReplanMemory()
        b.decline(cancelled)
        #expect(!b.maySearch(broken, now: at(10))) // Ausfall behalten: Verspaetung desselben Fahrzeugs fragt nicht neu
    }

    @Test func proposalValidOnlyWhileTriggerActiveAndBeforeSearchTime() throws {
        let s = try search(buffer: -60) // Suchzeit 08:39
        let proposal = ReplanProposal(id: UUID(), search: s, alternativeIndex: 0)
        #expect(ConnectionWatch.isValid(proposal, current: [s], now: at(30)))
        #expect(!ConnectionWatch.isValid(proposal, current: [s], now: at(39)))
        #expect(!ConnectionWatch.isValid(proposal, current: [], now: at(30)))
        let other = try #require(ConnectionWatch.evaluate(journey: base(cancelledB: true), step: .onBoardTransit(vehicle: 0), latched: [], walks: [:],
                                                          now: at(10), pace: pace).searches.first)
        #expect(ConnectionWatch.isValid(proposal, current: [other], now: at(20))) // gleiches Fahrzeug B, Ankunft 08:30
        // anderes Fahrzeug betroffen: der Vorschlag fuer B gilt nicht fuer C
        let c = try journey([
            L(trip: "A", dep: 0, arr: 30, from: "start", to: "deutz", delay: 9),
            L(walk: true, dep: 30, arr: 32, from: "deutz", to: "gleis9", seconds: 120),
            L(trip: "C", dep: 40, arr: 60, from: "gleis9", to: "ziel"),
        ])
        let forC = ConnectionWatch.evaluate(journey: c, step: .onBoardTransit(vehicle: 0), latched: [], walks: [:], now: at(10), pace: pace).searches
        #expect(!ConnectionWatch.isValid(proposal, current: forC, now: at(30)))
        // Zeit folgt der aktuellen Echtzeit: Ankunft rutscht auf 08:45, Vorschlag gilt weiter
        let later = try search(buffer: -420)
        #expect(ConnectionWatch.isValid(proposal, current: [later], now: at(41)))
    }

    @Test func firstSearchAllowedSecondForSameKeyNot() throws {
        var memory = ReplanMemory()
        let s = try search(buffer: -60)
        #expect(memory.maySearch(s, now: at(10)))
        memory.markSearched(s)
        #expect(!memory.maySearch(s, now: at(11)))
        // Zittern um 120 s schlechter: weiter keine Suche
        #expect(try !memory.maySearch(search(buffer: -180), now: at(11)))
    }

    @Test func worseningOf300SecondsAllowsNewSearch() throws {
        var memory = ReplanMemory()
        let s = try search(buffer: -60)
        memory.markSearched(s)
        #expect(try memory.maySearch(search(buffer: -360), now: at(12)))
    }

    @Test func neverMoreThanThreeSearches() throws {
        var memory = ReplanMemory()
        var s = try search(buffer: -60)
        for step in 1...3 {
            #expect(memory.maySearch(s, now: at(10)))
            memory.markSearched(s)
            s = try search(buffer: -60 - 360 * step)
        }
        #expect(memory.searchCount == 3)
        #expect(!memory.maySearch(s, now: at(10)))
    }

    @Test func declineSuppressesSameButNotWorsening() throws {
        var memory = ReplanMemory()
        let s = try search(buffer: -60)
        memory.decline(s)
        #expect(!memory.maySearch(s, now: at(10)))
        #expect(memory.isDeclined(s))
        #expect(try !memory.maySearch(search(buffer: -300), now: at(10)))
        #expect(try memory.maySearch(search(buffer: -360), now: at(10)))
    }

    /// Nach dem Aussteigen entstehen keine Suchen mehr; ein abgelehntes Fahrzeug bleibt trotzdem abgelehnt (Vormerkung
    /// dahinter bleibt), bis es 5 Min. schlechter steht.
    @Test func declinedSurvivesAlightingWithoutSearches() throws {
        var memory = ReplanMemory()
        memory.decline(try search(buffer: -60)) // B, A an 08:39
        let j = try base(delay: 9)
        let afterAlighting = at(39, seconds: 30)
        #expect(ConnectionWatch.evaluate(journey: j, step: .transferRouting(from: 0, to: 2), latched: [2], walks: [:],
                                         now: afterAlighting, pace: pace).searches.isEmpty)
        #expect(ConnectionWatch.declined([2], memory: memory, journey: j, walks: [:], now: afterAlighting, pace: pace) == [2])
        #expect(ConnectionWatch.declined([2], memory: ReplanMemory(), journey: j, walks: [:], now: afterAlighting, pace: pace).isEmpty)
        // A erst 08:44 an: Puffer -360 s, 5 Min. schlechter als beim Ablehnen
        #expect(try ConnectionWatch.declined([2], memory: memory, journey: base(delay: 14), walks: [:], now: afterAlighting, pace: pace).isEmpty)
    }

    @Test func declinedVehicleDoesNotSuppressAnotherVehicle() throws {
        var memory = ReplanMemory()
        memory.decline(try search(buffer: -60))
        let other = try #require(ConnectionWatch.evaluate(journey: base(cancelledB: true), step: .onBoardTransit(vehicle: 0), latched: [], walks: [:],
                                                          now: at(10), pace: pace).searches.first)
        // gleiches Fahrzeug "B", aber Ausfall ist weit schlechter als -60 s -> eigener Vorschlag erlaubt
        #expect(memory.maySearch(other, now: at(10)))
        let c = try journey([
            L(trip: "A", dep: 0, arr: 30, from: "start", to: "deutz", delay: 9),
            L(walk: true, dep: 30, arr: 32, from: "deutz", to: "gleis9", seconds: 120),
            L(trip: "C", dep: 40, arr: 60, from: "gleis9", to: "ziel"),
        ])
        let otherVehicle = try #require(ConnectionWatch.evaluate(journey: c, step: .onBoardTransit(vehicle: 0), latched: [], walks: [:],
                                                                 now: at(10), pace: pace).searches.first)
        #expect(otherVehicle.key != other.key)
        #expect(memory.maySearch(otherVehicle, now: at(10)))
    }

    @Test func failureRefundsCountAndWaitsAtLeastRetryDelayOrBlock() throws {
        var memory = ReplanMemory()
        let s = try search(buffer: -60)
        memory.markSearched(s)
        memory.markFailed(s, now: at(10), blockedUntil: nil)
        #expect(memory.searchCount == 0)
        #expect(!memory.maySearch(s, now: at(10, seconds: 59)))
        #expect(memory.maySearch(s, now: at(11)))
        // Rate-Limit-Sperre laenger als 60 s
        memory.markSearched(s)
        memory.markFailed(s, now: at(10), blockedUntil: at(13))
        #expect(!memory.maySearch(s, now: at(12)))
        #expect(memory.maySearch(s, now: at(13)))
    }
}

@Suite struct ConnectionWatchViaTests {
    @Test func viaAheadOfAlightingVehicleKeptEarlierDropped() throws {
        // Fahrzeug 0 -> Halt "p" (Aufenthalt) -> Fahrzeug 2 -> Halt "q" -> Fahrzeug 4
        let j = try journey([
            L(trip: "A", dep: 0, arr: 10, from: "s", to: "p"),
            L(walk: true, dep: 10, arr: 12, from: "p", to: "p2", seconds: 120),
            L(trip: "B", dep: 30, arr: 40, from: "p2", to: "q"),
            L(walk: true, dep: 40, arr: 42, from: "q", to: "q2", seconds: 120),
            L(trip: "C", dep: 60, arr: 70, from: "q2", to: "z"),
        ])
        let p = ViaStop(id: "p", stayMinutes: 15, label: "P")
        let q = ViaStop(id: "q", stayMinutes: 15, label: "Q")
        // Suchstart nach Fahrzeug 2: p liegt hinter uns, q vor uns
        #expect(ConnectionWatch.remainingVia([p, q], in: j, alightingVehicle: 2) == [q])
        // Suchstart nach Fahrzeug 0: Aufenthalt am Suchstart selbst bleibt dabei
        #expect(ConnectionWatch.remainingVia([p, q], in: j, alightingVehicle: 0) == [p, q])
        // nicht erkannter Stopp entfaellt
        #expect(ConnectionWatch.remainingVia([ViaStop(id: "x", stayMinutes: 5, label: "X")], in: j, alightingVehicle: 0).isEmpty)
    }
}
