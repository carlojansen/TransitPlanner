import Foundation
import SwiftData
import Testing
@testable import TransitCore

/// Fixture: Fussweg > STR 704 (06:08 statt 06:06, Gleis 2 statt 1) > Umstieg > RE 5 > Fussweg. Rohes Losgehen 06:02.
@Suite struct ReminderPlanTests {
    static let trip = UUID()
    static let fixtureText: String = {
        (try? Fixture.data("routes", "json")).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }()
    static let tramDeparture = "\"departure\": \"2026-10-24T06:08:00Z\""

    func at(_ time: String) -> Date { Date.iso("2026-10-24T\(time)Z") }

    func journey(replacing pairs: [(String, String)] = []) throws -> Journey {
        var text = Self.fixtureText
        for (a, b) in pairs { text = text.replacingOccurrences(of: a, with: b) }
        return try TransitJSON.decoder().decode(RoutesResponse.self, from: Data(text.utf8)).journeys[0]
    }

    func plan(earlier: Int = 0, warn: Int = 0) throws -> ReminderPlan {
        let j = try journey()
        let walks = [
            0: WalkEstimate(legIndex: 0, seconds: 240, distanceMeters: 280, source: .appleMaps),
            2: WalkEstimate(legIndex: 2, seconds: 60, distanceMeters: 90, source: .timetable),
        ]
        let calibrated = CalibratedJourney(journey: j, walks: walks, transfers: HybridRouteCalculator.transferChecks(j, walks: walks))
        let attribution = try Fixture.routes().attribution
        return try ReminderPlan(calibrated: calibrated, earlierMinutes: earlier, warnMinutes: warn, attribution: attribution)
    }

    struct ShiftRow: Sendable, CustomTestStringConvertible {
        let earlier: Int
        let warn: Int
        let departure: String
        let leave: String
        let replaces: Bool
        var testDescription: String { "frueher \(earlier), vorwarnen \(warn), Abfahrt \(departure) -> \(leave)" }
    }

    /// "frueher" und "Vorwarnen" ueberstehen jede Verschiebung; unter 60 s bleibt der Wecker stehen.
    @Test(arguments: [
        ShiftRow(earlier: 0, warn: 0, departure: "06:13:00", leave: "06:07:00", replaces: true),
        ShiftRow(earlier: 10, warn: 0, departure: "06:13:00", leave: "05:57:00", replaces: true),
        ShiftRow(earlier: 10, warn: 5, departure: "06:13:00", leave: "05:57:00", replaces: true),
        ShiftRow(earlier: 5, warn: 10, departure: "06:03:00", leave: "05:52:00", replaces: true), // Abfahrt vorverlegt
        ShiftRow(earlier: 10, warn: 5, departure: "06:08:00", leave: "05:52:00", replaces: false), // nichts geaendert
    ])
    func rescheduleKeepsChoices(_ row: ShiftRow) throws {
        var p = try plan(earlier: row.earlier, warn: row.warn)
        let fresh = try journey(replacing: [(Self.tramDeparture, "\"departure\": \"2026-10-24T\(row.departure)Z\"")])
        let replaces = p.apply(fresh, now: at("05:40:00"))
        #expect(replaces == row.replaces)
        #expect(p.leaveAt == at(row.leave))
        #expect(p.firstAlarm == at(row.leave).addingTimeInterval(TimeInterval(-row.warn * 60)))
        #expect(p.earlierMinutes == row.earlier && p.warnMinutes == row.warn)
        #expect(!p.isEstimated)
        let alerts = p.alerts(tripID: Self.trip, now: at("05:00:00"))
        #expect(alerts.map(\.kind) == (row.warn > 0 ? [.warn, .leave] : [.leave]))
        #expect(alerts.last?.fireAt == p.leaveAt)
    }

    /// Bestehende Erinnerungen uebernehmen "Am Gleis sein vorher" beim Refresh; "frueher" bleibt, die Rueckwaertsrechnung nicht.
    @Test func refreshAdoptsTheCurrentStationBuffer() throws {
        var plan = try plan(earlier: 5)
        #expect(plan.scheduled.bufferSeconds == 120)
        #expect(plan.apply(try journey(), now: at("05:40:00"), scheduler: DepartureScheduler(stationBufferSeconds: 300)))
        #expect(plan.scheduled.bufferSeconds == 300)
        #expect(plan.scheduled.leaveAt == at("05:59:00"))
        #expect(plan.leaveAt == at("05:54:00"))
    }

    /// Gleicher Index, aber aus dem Fussweg wurde ein Fahrzeug: dessen Geometrie gehoert nicht zum neuen Abschnitt.
    @Test func geometryStaysWithItsLegKind() throws {
        let original = try journey()
        #expect(original.legs[0].polyline != nil && original.legs[0].isWalk)
        var fresh = try journey(replacing: [("\"index\": 0, \"mode\": \"walk\"", "\"index\": 0, \"mode\": \"tram\"")])
        fresh.legs = fresh.legs.map { leg in
            var bare = leg
            bare.polyline = nil
            bare.steps = []
            return bare
        }
        let merged = fresh.withGeometry(of: original)
        #expect(merged.legs[0].polyline == nil && merged.legs[0].steps.isEmpty)
        #expect(merged.legs[1].polyline == original.legs[1].polyline && merged.legs[1].polyline != nil)
    }

    @Test func driftBelowThresholdNeverAccumulates() throws {
        var p = try plan()
        // 50 s nach Plan: kein Verschieben; der naechste Vergleich laeuft gegen den gestellten Wecker, nicht gegen 06:08:50.
        _ = p.apply(try journey(replacing: [(Self.tramDeparture, "\"departure\": \"2026-10-24T06:08:50Z\"")]), now: at("05:40:00"))
        #expect(p.leaveAt == at("06:02:00"))
        _ = p.apply(try journey(replacing: [(Self.tramDeparture, "\"departure\": \"2026-10-24T06:09:40Z\"")]), now: at("05:45:00"))
        #expect(p.leaveAt == at("06:03:40"))
    }

    @Test func platformChangeWithoutShiftReplacesText() throws {
        var p = try plan()
        let fresh = try journey(replacing: [("\"departurePlatform\": \"2\"", "\"departurePlatform\": \"7\"")])
        let replaces = p.apply(fresh, now: at("05:40:00"))
        #expect(replaces)
        #expect(p.leaveAt == at("06:02:00"))
        #expect(p.alerts(tripID: Self.trip, now: at("05:40:00")).first?.body.contains("Gleis 7 statt 1") == true)
    }

    @Test func lostConnectionLeavesAlarmStanding() throws {
        var p = try plan(earlier: 5, warn: 5)
        let alarms = p.alerts(tripID: Self.trip, now: at("05:30:00"))
        let cancelled = try journey(replacing: [("\"cancelled\": false,\n      \"realtime\": true", "\"cancelled\": true,\n      \"realtime\": true")])
        #expect(cancelled.cancelled)
        let replaces = p.apply(cancelled, now: at("05:35:00"))
        #expect(replaces) // gleiche Zeit, aber der Text sagt es
        #expect(p.status == .lost)
        #expect(p.leaveAt == at("05:57:00"))
        let lost = p.alerts(tripID: Self.trip, now: at("05:30:00"))
        #expect(lost.map(\.fireAt) == alarms.map(\.fireAt))
        #expect(lost.allSatisfy { $0.title == "Verbindung fällt aus" })
        // Weiter ausgefallen: nichts Neues
        var again = p
        let repeated = again.apply(cancelled, now: at("05:40:00"))
        #expect(!repeated)
        // Die Bahn faehrt doch: Hinweis weg, Text zurueck
        let recovered = p.apply(try journey(), now: at("05:40:00"))
        #expect(recovered && p.status == .scheduled)
        #expect(p.alerts(tripID: Self.trip, now: at("05:30:00")).last?.title == "Jetzt losgehen")
    }

    @Test func expiredStaysEstimatedAndStopsAsking() throws {
        var p = try plan()
        _ = p.apply(try journey(), now: at("05:40:00"))
        p.markExpired()
        #expect(p.isEstimated)
        #expect(!p.refreshDue(now: at("05:50:00")))
        #expect(p.nextCheck(now: at("05:50:00")) == nil)
    }

    struct SnoozeRow: Sendable, CustomTestStringConvertible {
        let earlier: Int
        let warn: Int
        let now: String
        let expected: String?
        var testDescription: String { "\(now), frueher \(earlier) -> \(expected ?? "entfaellt")" }
    }

    /// Losgehen 06:02, letzter sinnvoller Moment 06:04 (Abfahrt 06:08 minus 240 s Weg).
    @Test(arguments: [
        SnoozeRow(earlier: 0, warn: 0, now: "06:02:00", expected: "06:04:00"), // 06:07 waere zu spaet: gedeckelt
        SnoozeRow(earlier: 0, warn: 0, now: "06:03:30", expected: nil), // 30 s Rest: sinnlos
        SnoozeRow(earlier: 0, warn: 0, now: "06:05:00", expected: nil), // Weg reicht nicht mehr
        SnoozeRow(earlier: 0, warn: 10, now: "05:52:00", expected: "05:57:00"), // T-0 kommt danach
        SnoozeRow(earlier: 0, warn: 3, now: "05:59:00", expected: nil), // T-0 kommt vor dem Snooze
        SnoozeRow(earlier: 10, warn: 0, now: "05:52:00", expected: "05:57:00"), // nach T-0, "frueher" hat Luft
        SnoozeRow(earlier: 10, warn: 0, now: "06:01:00", expected: "06:04:00"), // gedeckelt
    ])
    func snoozeStaysBeforeDeparture(_ row: SnoozeRow) throws {
        let p = try plan(earlier: row.earlier, warn: row.warn)
        let time = p.snoozeTime(now: at(row.now))
        #expect(time == row.expected.map(at))
        #expect(time.map { $0 < p.scheduled.firstDeparture } ?? true)
    }

    @Test func snoozeIsTimeSensitiveAndHasItsOwnID() throws {
        let alert = try #require(try plan().snoozeAlert(tripID: Self.trip, now: at("06:02:00")))
        #expect(alert.isTimeSensitive)
        #expect(alert.title == "Jetzt losgehen")
        #expect(ReminderAlert.identifiers(Self.trip).contains(alert.identifier))
    }

    @Test func onlyTheLeaveAlertIsTimeSensitive() throws {
        let alerts = try plan(warn: 5).alerts(tripID: Self.trip, now: at("05:00:00"))
        #expect(alerts.map(\.isTimeSensitive) == [false, true])
        #expect(alerts.map(\.title) == ["In 5 Min. losgehen", "Jetzt losgehen"])
        #expect(alerts.map(\.fireAt) == [at("05:57:00"), at("06:02:00")])
        #expect(Set(alerts.map(\.identifier)).count == 2)
    }

    @Test func overdueLeaveFiresNowWhileTheTrainIsThere() throws {
        let p = try plan(warn: 5)
        #expect(p.alerts(tripID: Self.trip, now: at("06:03:00")).map(\.fireAt) == [at("06:03:00")])
        #expect(p.alerts(tripID: Self.trip, now: at("06:09:00")).isEmpty)
    }

    @Test func checksStayInsideTheWindowAndAreThrottled() throws {
        var p = try plan(earlier: 10) // Losgehen 05:52, Fenster ab 05:22
        #expect(!p.refreshDue(now: at("05:21:00")))
        #expect(p.nextCheck(now: at("01:00:00")) == at("05:22:00"))
        #expect(p.refreshDue(now: at("05:22:00")))
        p.attemptedAt = at("05:30:00")
        #expect(!p.refreshDue(now: at("05:34:59")))
        #expect(p.refreshDue(now: at("05:35:00")))
        #expect(p.nextCheck(now: at("05:31:00")) == at("05:35:00"))
        #expect(!p.refreshDue(now: at("06:08:00"))) // abgefahren
        #expect(p.nextCheck(now: at("06:08:00")) == nil)
    }

    @Test func nextAlarmFallsBackToLeaving() throws {
        let p = try plan(warn: 5)
        #expect(p.nextAlarm(now: at("05:00:00")) == at("05:57:00"))
        #expect(p.nextAlarm(now: at("05:58:00")) == at("06:02:00"))
    }

    @Test func activeOnlyTodayAndUntilDeparture() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let p = try plan()
        #expect(p.isActive(now: at("00:30:00"), calendar: utc))
        #expect(!p.isActive(now: Date.iso("2026-10-23T23:00:00Z"), calendar: utc))
        #expect(!p.isActive(now: at("06:09:00"), calendar: utc))
        #expect(!p.isOver(now: at("06:20:00")))
        #expect(p.isOver(now: at("06:43:00")))
    }

    @Test func sameTripSurvivesRealtimeAndToken() throws {
        let j = try journey()
        let later = try journey(replacing: [(Self.tramDeparture, "\"departure\": \"2026-10-24T06:13:00Z\"")])
        #expect(j.isSameTrip(as: later.withRefreshToken("anders")))
        #expect(!j.isSameTrip(as: try Fixture.routes().journeys[1]))
        // Gleiches erstes Fahrzeug, anderer Ausstieg oder anderes Ziel: eine andere Fahrt
        let exit = try journey(replacing: [("\"name\": \"Bilk S\",", "\"name\": \"Volksgarten\",")])
        #expect(!j.isSameTrip(as: exit))
    }
}

@Suite struct ReminderTextTests {
    func journey(replacing pairs: [(String, String)] = []) throws -> Journey {
        var text = ReminderPlanTests.fixtureText
        for (a, b) in pairs { text = text.replacingOccurrences(of: a, with: b) }
        return try TransitJSON.decoder().decode(RoutesResponse.self, from: Data(text.utf8)).journeys[0]
    }

    @Test func namesLineTimeStopPlatformAndChanges() throws {
        let departure = Date.iso("2026-10-24T06:08:00Z").clockText
        let planned = Date.iso("2026-10-24T06:06:00Z").clockText
        #expect(ReminderText.body(try journey()) == "STR 704 um \(departure) statt \(planned), ab Duesseldorf Hbf, Gleis 2 statt 1, nach Koeln Hbf")
    }

    struct Row: Sendable, CustomTestStringConvertible {
        let replacements: [String]
        let expected: String
        var testDescription: String { expected }
    }

    @Test(arguments: [
        Row(replacements: ["\"plannedDeparturePlatform\": \"1\"", "\"plannedDeparturePlatform\": \"2\""], expected: "Gleis 2,"),
        Row(replacements: ["\"departurePlatform\": \"2\", \"plannedDeparturePlatform\": \"1\"", "\"departurePlatform\": null, \"plannedDeparturePlatform\": \"1\""], expected: "Gleis 1,"),
    ])
    func platformWithoutChange(_ row: Row) throws {
        let body = ReminderText.body(try journey(replacing: [(row.replacements[0], row.replacements[1])]))
        #expect(body.contains(row.expected))
        #expect(!body.contains("statt 1"))
    }

    /// Koordinaten-Endpunkte (Wohnadresse) tragen nie ihren Namen in die Mitteilung, auch wenn einer mitgeliefert wuerde.
    @Test func neverLeaksCoordinateEndpointNames() throws {
        let j = try journey(replacing: [("\"kind\": \"coordinate\", \"id\": null, \"name\": null", "\"kind\": \"coordinate\", \"id\": null, \"name\": \"Musterstrasse 1\"")])
        #expect(j.legs.first?.origin.name == "Musterstrasse 1" || j.legs.last?.destination.name == "Musterstrasse 1")
        #expect(!ReminderText.body(j).contains("Muster"))
    }

    @Test func walkOnlyJourneyHasNoAddress() throws {
        let walk = #"""
        {"journeys":[{"refreshToken":null,"departure":"2026-10-24T06:00:00Z","arrival":"2026-10-24T06:10:00Z","durationSeconds":600,
         "transfers":0,"modes":[],"cancelled":false,"realtime":false,"hasPolylines":false,"remarks":[],
         "legs":[{"index":0,"mode":"walk","origin":{"kind":"coordinate","name":"Zuhause"},"destination":{"kind":"coordinate","name":"Musterstrasse 1"},
          "departure":"2026-10-24T06:00:00Z","arrival":"2026-10-24T06:10:00Z","durationSeconds":600,"realtime":false,"cancelled":false}]}],
         "earlierRef":null,"laterRef":null,"walkOnly":true,"removedLongDistance":0,"fetchedAt":"2026-10-24T06:00:00Z",
         "attribution":\#(Fixture.attributionJSON)}
        """#
        let j = try TransitJSON.decoder().decode(RoutesResponse.self, from: Data(walk.utf8)).journeys[0]
        #expect(ReminderText.body(j) == "Zu Fuß, \(Date.iso("2026-10-24T06:00:00Z").clockText)")
    }
}

@Suite struct ReminderPersistenceTests {
    let sealer = LocalSealer(secrets: InMemorySecretStore())
    let request = ManualTripRequest(origin: .stop(id: "a", label: "Hbf"), destination: .stop(id: "b", label: "Zuhause"),
                                    targetTime: Date.iso("2026-10-24T06:00:00Z"))

    @MainActor @Test func roundTripKeepsPlanButNeverTheToken() throws {
        let tests = ReminderPlanTests()
        var plan = try tests.plan(earlier: 10, warn: 5)
        let token = try #require(plan.calibrated.journey.refreshToken)
        _ = plan.apply(try tests.journey(replacing: [(ReminderPlanTests.tramDeparture, "\"departure\": \"2026-10-24T06:13:00Z\"")]),
                       now: tests.at("05:30:00"))
        #expect(plan.live?.refreshToken == nil) // apply wirft ihn schon weg

        let container = try TransitStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let id = UUID()
        context.insert(try PlannedTrip(id: id, request: request, plan: plan, sealer: sealer))
        try context.save()

        let stored = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(stored.id == id && stored.reminderEnabled)
        #expect(stored.targetTime == plan.leaveAt)
        #expect(try stored.request(using: sealer) == request)
        let back = try #require(try stored.plan(using: sealer))
        #expect(back == plan.withoutTokens)
        #expect(back.calibrated.journey.refreshToken == nil)
        #expect(back.calibrated.journey.legs[0].steps == plan.calibrated.journey.legs[0].steps)
        #expect(back.earlierMinutes == 10 && back.warnMinutes == 5)
        #expect(back.calibrated.walks == plan.calibrated.walks)

        // Auch der entschluesselte Inhalt enthaelt den Token nicht
        let sealed = try #require(stored.sealedPlan)
        struct Raw: Decodable { let calibrated: Inner; struct Inner: Decodable { let journey: Token }; struct Token: Decodable { let refreshToken: String? } }
        #expect(try sealer.open(Raw.self, from: sealed).calibrated.journey.refreshToken == nil)
        #expect(sealed.range(of: Data(token.utf8)) == nil)
    }

    /// Feste Datei vom ersten Stand (Schluessel 32 x 0x2A). Bricht dieser Test, bricht die gespeicherte Erinnerung beim
    /// Nutzer: `removeUnreadable` wuerde sie loeschen. Neue Felder im Plan muessen optional sein.
    @Test func sealedPlanFromFirstVersionStaysReadable() throws {
        let secrets = InMemorySecretStore()
        try secrets.write(Data(repeating: 0x2A, count: 32), for: .coordinateKey)
        let plan = try LocalSealer(secrets: secrets).open(ReminderPlan.self, from: Fixture.data("reminder-plan-v1", "sealed"))
        #expect(plan.earlierMinutes == 10 && plan.warnMinutes == 5)
        #expect(plan.calibrated.journey.refreshToken == nil)
        #expect(plan.calibrated.journey.legs.count == 5)
        #expect(plan.scheduled.firstDeparture == Date.iso("2026-10-24T06:08:00Z"))
        #expect(plan.status == .scheduled && !plan.isEstimated)
        #expect(plan.alertsPending == nil)
        #expect(plan.calibrated.walks[0]?.seconds == 240)
    }

    @MainActor @Test func tripsWithoutPlanStayReadable() throws {
        let container = try TransitStore.makeContainer(inMemory: true)
        let trip = try PlannedTrip(request: request, sealer: sealer)
        container.mainContext.insert(trip)
        try container.mainContext.save()
        #expect(try trip.plan(using: sealer) == nil)
    }
}
