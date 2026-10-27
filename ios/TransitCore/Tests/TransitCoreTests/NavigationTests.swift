import Foundation
import Testing
@testable import TransitCore

/// Fixture-Verbindung 0: Fussweg (06:00-06:05) > Tram 1 (06:08-06:18) > Umstieg > Fahrzeug 3, Ersatzverkehr (06:23-06:38) > Fussweg.
@Suite struct NavigationEngineTests {
    static let start = GeoCoordinate(latitude: 51.2201, longitude: 6.7905)
    static let hbf = GeoCoordinate(latitude: 51.21996, longitude: 6.79432)
    static let bilkGleis3 = GeoCoordinate(latitude: 51.2049, longitude: 6.7761)
    static let koeln = GeoCoordinate(latitude: 50.9430, longitude: 6.9589)
    static let destination = GeoCoordinate(latitude: 50.9413, longitude: 6.9583)
    static let far = GeoCoordinate(latitude: 51.0, longitude: 7.2)
    /// ca. 50 m noerdlich vom Hbf-Halt
    static let nearHbf = GeoCoordinate(latitude: 51.22041, longitude: 6.79432)

    struct Row: Sendable, CustomTestStringConvertible {
        let time: String
        let position: GeoCoordinate?
        let previous: NavigationStep?
        let expected: NavigationStep
        /// Alter des Fixes (s) und Genauigkeit (m)
        var age: TimeInterval = 0
        var accuracy: Double = 5
        var testDescription: String { "\(time) \(position.map { "\($0.latitude),\($0.longitude)" } ?? "ohne Fix") -> \(expected)" }
    }

    static let table: [Row] = [
        // Fahrt weit voraus (Losgehen 06:00, Schwelle 30 Min.): ruhig warten, auch am Halt oder weit weg
        Row(time: "05:00:00", position: nil, previous: nil, expected: .waitingToLeave(vehicle: 1)),
        Row(time: "05:29:00", position: hbf, previous: nil, expected: .waitingToLeave(vehicle: 1)),
        Row(time: "05:29:00", position: far, previous: .waitingToLeave(vehicle: 1), expected: .waitingToLeave(vehicle: 1)),
        // Danach automatisch der normale Ablauf; nie zurueck ins Warten
        Row(time: "05:31:00", position: nil, previous: .waitingToLeave(vehicle: 1), expected: .approachingFirstStop(vehicle: 1)),
        Row(time: "05:00:00", position: nil, previous: .approachingFirstStop(vehicle: 1), expected: .approachingFirstStop(vehicle: 1)),
        Row(time: "06:01:00", position: start, previous: nil, expected: .approachingFirstStop(vehicle: 1)),
        Row(time: "06:01:00", position: nil, previous: nil, expected: .approachingFirstStop(vehicle: 1)),
        Row(time: "06:05:00", position: hbf, previous: nil, expected: .waitingAtPlatform(vehicle: 1)),
        // GPS-Rauschen: am Gleis bleibt am Gleis
        Row(time: "06:05:30", position: start, previous: .waitingAtPlatform(vehicle: 1), expected: .waitingAtPlatform(vehicle: 1)),
        Row(time: "06:12:00", position: nil, previous: nil, expected: .onBoardTransit(vehicle: 1)),
        // 120 s vor Ankunft am Umsteigehalt (Echtzeit-Ankunft 06:18)
        Row(time: "06:16:30", position: nil, previous: nil, expected: .transferRouting(from: 1, to: 3)),
        Row(time: "06:20:00", position: far, previous: nil, expected: .transferRouting(from: 1, to: 3)),
        Row(time: "06:20:00", position: bilkGleis3, previous: nil, expected: .waitingAtPlatform(vehicle: 3)),
        // letztes Fahrzeug: kein Umstieg, bis zur Ankunft im Fahrzeug
        Row(time: "06:37:30", position: nil, previous: nil, expected: .onBoardTransit(vehicle: 3)),
        Row(time: "06:39:00", position: koeln, previous: nil, expected: .finalWalkToDestination),
        Row(time: "06:43:00", position: destination, previous: nil, expected: .arrived),
        Row(time: "06:43:00", position: koeln, previous: .arrived, expected: .arrived),
        // Abfahrt 06:08 vorbei, frischer Fix weit vom Halt, nie am Gleis: verpasst
        Row(time: "06:09:00", position: start, previous: .approachingFirstStop(vehicle: 1), expected: .missedDeparture(vehicle: 1)),
        // Verpasst bleibt bis zum Neuplanen, auch nach der Ankunftszeit des verpassten Fahrzeugs und ohne Fix
        Row(time: "06:19:00", position: start, previous: .missedDeparture(vehicle: 1), expected: .missedDeparture(vehicle: 1)),
        Row(time: "06:30:00", position: nil, previous: .missedDeparture(vehicle: 1), expected: .missedDeparture(vehicle: 1)),
        // U-Bahn: veralteter Strassen-Fix (60 s) entscheidet nicht, Fahrplanzeit
        Row(time: "06:09:00", position: start, previous: .approachingFirstStop(vehicle: 1), expected: .onBoardTransit(vehicle: 1),
            age: 60),
        // Ungenauer Fix (100 m) bei ca. 50 m Abstand (mit 5 m waere es verpasst): nicht sicher weg vom Halt, Fahrplanzeit
        Row(time: "06:09:00", position: nearHbf, previous: .approachingFirstStop(vehicle: 1), expected: .onBoardTransit(vehicle: 1),
            accuracy: 100),
        Row(time: "06:09:00", position: nearHbf, previous: .approachingFirstStop(vehicle: 1), expected: .missedDeparture(vehicle: 1)),
        Row(time: "06:09:00", position: start, previous: .approachingFirstStop(vehicle: 1), expected: .onBoardTransit(vehicle: 1),
            accuracy: 300),
        // Vorher am Gleis: eingestiegen, auch wenn der Fix danach weit weg ist
        Row(time: "06:09:00", position: start, previous: .waitingAtPlatform(vehicle: 1), expected: .onBoardTransit(vehicle: 1)),
        // Ohne Position: nach Fahrplanzeit wie bisher
        Row(time: "06:09:00", position: nil, previous: .approachingFirstStop(vehicle: 1), expected: .onBoardTransit(vehicle: 1)),
        // Umstieg verpasst
        Row(time: "06:24:00", position: far, previous: .transferRouting(from: 1, to: 3), expected: .missedDeparture(vehicle: 3)),
    ]

    @Test func missedDepartureShowsMissedBuffer() throws {
        let journey = try Fixture.routes().journeys[0]
        let now = Date.iso("2026-10-24T06:09:00Z")
        let fix = LocationFix(coordinate: Self.start, horizontalAccuracy: 5, timestamp: now)
        let step = NavigationEngine.resolve(journey: journey, fix: fix, now: now, previous: .approachingFirstStop(vehicle: 1))
        #expect(step == .missedDeparture(vehicle: 1))
        #expect(NavigationEngine.walkingStep(toward: 1, in: journey) == .approachingFirstStop(vehicle: 1))
        #expect(NavigationEngine.walkingStep(toward: 3, in: journey) == .transferRouting(from: 1, to: 3))
        let vehicle = try #require(NavigationEngine.targetVehicle(step))
        let buffer = NavigationEngine.buffer(journey: journey, vehicle: vehicle, walks: [:], position: Self.start,
                                             now: now, pace: WalkingPaceFactor())
        #expect(buffer?.status == .missed)
    }

    @Test(arguments: table)
    func resolve(_ row: Row) throws {
        let journey = try Fixture.routes().journeys[0]
        let now = Date.iso("2026-10-24T\(row.time)Z")
        let fix = row.position.map { LocationFix(coordinate: $0, horizontalAccuracy: row.accuracy, timestamp: now.addingTimeInterval(-row.age)) }
        #expect(NavigationEngine.resolve(journey: journey, fix: fix, now: now, previous: row.previous) == row.expected)
    }

    @Test func targetVehicleAndWalkBefore() throws {
        let journey = try Fixture.routes().journeys[0]
        #expect(NavigationEngine.targetVehicle(.transferRouting(from: 1, to: 3)) == 3)
        #expect(NavigationEngine.targetVehicle(.arrived) == nil)
        #expect(NavigationEngine.walkLeg(before: 3, in: journey)?.index == 2)
        #expect(NavigationEngine.walkLeg(before: 1, in: journey)?.index == 0)
    }

    /// Puffer: Abfahrt 06:08, Fussweg 300 s.
    @Test func bufferFromCalibratedWalkAndPosition() throws {
        let journey = try Fixture.routes().journeys[0]
        let pace = WalkingPaceFactor()
        func buffer(_ time: String, _ position: GeoCoordinate?) -> WalkBuffer? {
            NavigationEngine.buffer(journey: journey, vehicle: 1, walks: [:], position: position,
                                    now: Date.iso("2026-10-24T\(time)Z"), pace: pace)
        }
        #expect(buffer("06:01:00", Self.start) == WalkBuffer(seconds: 120))
        #expect(buffer("06:01:00", Self.start)?.status == .comfortable)
        // 06:02: 360 s bis zur Abfahrt - 300 s Fussweg = 60 s
        #expect(buffer("06:02:00", Self.start)?.status == .tight)
        #expect(buffer("06:02:00", Self.start)?.needsWarning == true)
        #expect(buffer("06:04:00", Self.start)?.status == .missed)
        // Am Halt bleibt keine Gehzeit
        #expect(buffer("06:07:00", Self.hbf) == WalkBuffer(seconds: 60))
        // Kalibrierte Gehzeit hat Vorrang
        let calibrated = NavigationEngine.buffer(journey: journey, vehicle: 1,
                                                 walks: [0: WalkEstimate(legIndex: 0, seconds: 200, distanceMeters: 280, source: .appleMaps)],
                                                 position: Self.start, now: Date.iso("2026-10-24T06:01:00Z"), pace: pace)
        #expect(calibrated?.seconds == 220)
    }

    /// Umstieg Tram (an 06:18) > Fahrzeug 3 (ab 06:23), Weg 180 s: vor der Ankunft zaehlen Ankunft und keine Position.
    @Test func transferBufferBeforeArrivalUsesArrivalNotPosition() throws {
        let journey = try Fixture.routes().journeys[0]
        func buffer(_ time: String, _ position: GeoCoordinate?) -> WalkBuffer? {
            NavigationEngine.buffer(journey: journey, vehicle: 3, walks: [:], position: position,
                                    now: Date.iso("2026-10-24T\(time)Z"), pace: WalkingPaceFactor())
        }
        #expect(buffer("06:10:00", nil)?.seconds == 120)
        #expect(buffer("06:16:30", Self.far)?.seconds == 120)
        #expect(buffer("06:16:30", Self.bilkGleis3)?.seconds == 120)
        // Nach der Ankunft: jetzt und Position
        #expect(buffer("06:20:00", Self.bilkGleis3)?.seconds == 180)
    }

    @Test func brokenConnectionAfterDelay() throws {
        let journey = try Fixture.routes().journeys[0]
        let pace = WalkingPaceFactor()
        let now = Date.iso("2026-10-24T06:10:00Z")
        #expect(NavigationEngine.brokenConnection(after: 1, journey: journey, walks: [:], now: now, pace: pace) == nil)
        // Weg zum Ersatzbus dauert 6 statt 3 Min.: 300 s - 360 s reicht nicht
        let slow = [2: WalkEstimate(legIndex: 2, seconds: 360, distanceMeters: 90, source: .timetable)]
        #expect(NavigationEngine.brokenConnection(after: 1, journey: journey, walks: slow, now: now, pace: pace) == 3)
    }

    @Test func waitingStateUntilLeaveLead() throws {
        let journey = try Fixture.routes().journeys[0]
        #expect(NavigationEngine.leaveTime(journey) == Date.iso("2026-10-24T06:00:00Z"))
        #expect(NavigationEngine.targetVehicle(.waitingToLeave(vehicle: 1)) == 1)
        let threshold = Date.iso("2026-10-24T05:30:00Z")
        #expect(NavigationEngine.resolve(journey: journey, fix: nil, now: threshold.addingTimeInterval(-1), previous: nil)
            == .waitingToLeave(vehicle: 1))
        #expect(NavigationEngine.resolve(journey: journey, fix: nil, now: threshold, previous: .waitingToLeave(vehicle: 1))
            == .approachingFirstStop(vehicle: 1))
    }

    @Test func bufferThresholds() {
        #expect(WalkBuffer(seconds: 120).status == .comfortable)
        #expect(WalkBuffer(seconds: 119).status == .tight)
        #expect(WalkBuffer(seconds: 1).status == .tight)
        // 0 s reicht nicht (Audit: "Engster Umstieg: 0 s" nur gelb)
        #expect(WalkBuffer(seconds: 0).status == .missed)
        #expect(WalkBuffer(seconds: -1).status == .missed)
        #expect(WalkBuffer(seconds: 89).needsWarning && !WalkBuffer(seconds: 90).needsWarning)
    }

    /// Schritte (Fixture): depart 40 m, unbekannt 12 m, Aufzug, ... ; Polyline ca. 267 m.
    @Test func guidanceAlongPolyline() throws {
        let walk = try Fixture.routes().journeys[0].legs[0]
        let atStart = NavigationEngine.guidance(walk: walk, position: Self.start)
        #expect(atStart.metersToNextStep == 40)
        #expect(atStart.nextStep?.direction == .unknown)
        #expect((260...270).contains(atStart.remainingMeters ?? 0))

        let near = GeoCoordinate(latitude: 51.22003, longitude: 6.7924) // ca. 135 m weit
        let later = NavigationEngine.guidance(walk: walk, position: near)
        #expect(later.nextStep == nil) // alle Schritte liegen hinter uns
        #expect((120...145).contains(later.remainingMeters ?? 0))

        #expect(NavigationEngine.guidance(walk: walk, position: nil).remainingMeters == nil)
    }

    @Test func guidanceWithoutPolylineUsesStraightDistanceOnly() throws {
        let transfer = try Fixture.routes().journeys[0].legs[2] // polyline null
        let g = NavigationEngine.guidance(walk: transfer, position: GeoCoordinate(latitude: 51.2045, longitude: 6.7755))
        #expect(g.nextStep == nil && g.metersToNextStep == nil)
        #expect((55...70).contains(g.remainingMeters ?? 0))
    }

    @Test func stopsUntilExitCountsDown() throws {
        let tram = try Fixture.routes().journeys[0].legs[1] // Zwischenhalt 06:12
        #expect(NavigationEngine.stopsUntilExit(leg: tram, now: Date.iso("2026-10-24T06:10:00Z")) == 2)
        #expect(NavigationEngine.stopsUntilExit(leg: tram, now: Date.iso("2026-10-24T06:13:00Z")) == 1)
    }
}

/// Wegbeschreibung: OSM-Teilstuecke derselben Strasse werden eine Zeile.
@Suite struct WalkDirectionsTests {
    static func s(_ d: Step.Direction, _ m: Int?, _ name: String? = nil, from: Double? = nil, to: Double? = nil) -> Step {
        Step(direction: d, distanceMeters: m, fromLevel: from, toLevel: to, streetName: name)
    }

    /// Screenshot-Fall: ca. 30 Teilstuecke "Hüttenstraße 3 m, 3 m, 2 m ..." (teils ohne Namen, leichte Biegung).
    static let huettenstrasse: [Step] = [s(.depart, 3, "Hüttenstraße")]
        + (1...27).map { i in s(i % 5 == 0 ? .unknown : .continue, [3, 3, 2][i % 3], i % 7 == 0 ? nil : "Hüttenstraße") }
        + [s(.slightlyLeft, 2, "Hüttenstraße"), s(.continue, 560, "Hüttenstraße")]

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let steps: [Step]
        let expected: [Step]
        var testDescription: String { name }
    }

    static let table: [Row] = [
        Row(name: "Hüttenstraße -> eine Zeile", steps: huettenstrasse, expected: [s(.depart, 637, "Hüttenstraße")]),
        Row(name: "Hüttenstraße, dann rechts -> zwei Zeilen",
            steps: huettenstrasse + [s(.right, 40, "Bahnhofstraße"), s(.continue, 3, nil), s(.continue, 2, "Bahnhofstraße")],
            expected: [s(.depart, 637, "Hüttenstraße"), s(.right, 45, "Bahnhofstraße")]),
        Row(name: "Namenloser Start uebernimmt den Strassennamen",
            steps: [s(.depart, 20, nil), s(.continue, 80, "Kölner Straße")], expected: [s(.depart, 100, "Kölner Straße")]),
        Row(name: "Strassenwechsel geradeaus bleibt, Mikroschritt nicht",
            steps: [s(.depart, 100, "A-Straße"), s(.continue, 4, "B-Weg"), s(.continue, 200, "C-Allee")],
            expected: [s(.depart, 104, "A-Straße"), s(.continue, 200, "C-Allee")]),
        Row(name: "Leichte Biegung auf andere Strasse bleibt",
            steps: [s(.depart, 50, "A-Straße"), s(.slightlyRight, 60, "B-Weg")],
            expected: [s(.depart, 50, "A-Straße"), s(.slightlyRight, 60, "B-Weg")]),
        Row(name: "Treppe und Aufzug bleiben, Mikroschritt danach geht auf",
            steps: [s(.depart, 40, "Breslauer Platz"), s(.stairs, 20, from: 1, to: 0), s(.continue, 3), s(.elevator, nil, from: 0, to: -1),
                    s(.continue, 30, "Gleis 7")],
            expected: [s(.depart, 40, "Breslauer Platz"), s(.stairs, 23, from: 1, to: 0), s(.elevator, nil, from: 0, to: -1),
                       s(.continue, 30, "Gleis 7")]),
        Row(name: "Abbiegen bleibt auch kurz", steps: [s(.depart, 30, "A"), s(.left, 5, "A")],
            expected: [s(.depart, 30, "A"), s(.left, 5, "A")]),
        Row(name: "Abbiegen auf namenlosen Weg uebernimmt keinen Namen",
            steps: [s(.depart, 50, "A"), s(.left, 30, nil), s(.continue, 80, "Feldweg")],
            expected: [s(.depart, 50, "A"), s(.left, 110, nil)]),
        Row(name: "Unbekannte Richtung mit neuem Namen bleibt",
            steps: [s(.depart, 20, nil), s(.unknown, 80, "Kölner Straße"), s(.unknown, 4, "Gasse")],
            expected: [s(.depart, 20, nil), s(.unknown, 84, "Kölner Straße")]),
        Row(name: "leer", steps: [], expected: []),
    ]

    @Test(arguments: table)
    func condensed(_ row: Row) {
        let out = WalkDirections.condensed(row.steps)
        #expect(out == row.expected)
        // Gesamtdistanz bleibt (Fuehrung rechnet kumuliert).
        #expect(out.compactMap(\.distanceMeters).reduce(0, +) == row.steps.compactMap(\.distanceMeters).reduce(0, +))
    }

    @Test func adjacentStairsBecomeOneLine() {
        let steps = [Self.s(.stairs, 12, from: 0, to: 1), Self.s(.stairs, 2, from: 1, to: 2), Self.s(.stairs, 12, from: 2, to: 3),
                     Self.s(.stairs, 13, from: 3, to: 4), Self.s(.left, 20, "A"), Self.s(.stairs, 16, from: 4, to: 3)]
        let lines = WalkDirections.grouped(steps)
        #expect(lines.map(\.stairs) == [4, 0, 1])
        #expect(lines[0].step.distanceMeters == 39)
        #expect(lines[2].step == steps[5])
        #expect(WalkDirections.grouped([]).isEmpty)
    }

    @Test func keyStepsShowManeuversOnlyWhenLong() {
        let short = [Self.s(.depart, 100, "A"), Self.s(.continue, 200, "B")]
        #expect(WalkDirections.keySteps(short) == short)
        let long = [Self.s(.depart, 100, "A"), Self.s(.continue, 200, "B"), Self.s(.left, 50, "C"),
                    Self.s(.continue, 300, "D"), Self.s(.stairs, 10, from: 0, to: 1)]
        #expect(WalkDirections.keySteps(long).map(\.direction) == [.left, .stairs])
        let straight = (0..<5).map { Self.s(.continue, 100, "S\($0)") }
        #expect(WalkDirections.keySteps(straight) == straight)
    }

    /// Umweg im Bahnhof (hin und zurueck): Rest entlang der Polylinie, nicht Luftlinie zum Ziel.
    @Test func remainingWalkFollowsPolyline() throws {
        let json = """
        {"index":1,"mode":"walk","realtime":false,"cancelled":false,"durationSeconds":200,
         "origin":{"kind":"stop","name":"Gleis 93","latitude":51.0,"longitude":7.0},
         "destination":{"kind":"stop","name":"Gleis 92","latitude":51.0001,"longitude":7.0},
         "polyline":{"type":"LineString","coordinates":[[7.0,51.0],[7.002,51.0],[7.0,51.0001]]}}
        """
        let walk = try TransitJSON.decoder().decode(Leg.self, from: Data(json.utf8))
        let turn = GeoCoordinate(latitude: 51.0, longitude: 7.002)
        let left = NavigationEngine.remainingWalkSeconds(to: walk.destination, walk: walk, walks: [:], position: turn,
                                                         pace: WalkingPaceFactor())
        #expect((95...105).contains(left)) // halber Weg, Luftlinie haette die volle Zeit ergeben
    }

    /// Nach dem Refresh (ohne Polylinie) rechnet der Puffer den Fussweg weiter entlang der Polylinie aus `geometry`.
    @Test func bufferUsesGeometryAfterRefresh() throws {
        func journey(polyline: Bool) throws -> Journey {
            let line = polyline ? #","polyline":{"type":"LineString","coordinates":[[7.0,51.0],[7.002,51.0],[7.0,51.0001]]}"# : ""
            let json = #"{"departure":"2026-10-24T06:00:00Z","arrival":"2026-10-24T06:20:00Z","durationSeconds":1200,"transfers":0,"modes":["tram"],"cancelled":false,"realtime":true,"hasPolylines":false,"legs":[{"index":0,"mode":"walk","realtime":false,"cancelled":false,"durationSeconds":200,"origin":{"kind":"stop","name":"A","latitude":51.0,"longitude":7.0},"destination":{"kind":"stop","name":"B","latitude":51.0001,"longitude":7.0}"# + line + #"},{"index":1,"mode":"tram","realtime":true,"cancelled":false,"replacement":false,"origin":{"kind":"stop","name":"B","latitude":51.0001,"longitude":7.0},"destination":{"kind":"stop","name":"C","latitude":51.01,"longitude":7.0},"departure":"2026-10-24T06:10:00Z","arrival":"2026-10-24T06:20:00Z"}],"remarks":[]}"#
            return try TransitJSON.decoder().decode(Journey.self, from: Data(json.utf8))
        }
        let refreshed = try journey(polyline: false)
        let geometry = try journey(polyline: true)
        let turn = GeoCoordinate(latitude: 51.0, longitude: 7.002)
        let now = Date.iso("2026-10-24T06:05:00Z")
        let withGeometry = NavigationEngine.buffer(journey: refreshed, geometry: geometry, vehicle: 1, walks: [:],
                                                   position: turn, now: now, pace: WalkingPaceFactor())
        let without = NavigationEngine.buffer(journey: refreshed, vehicle: 1, walks: [:], position: turn, now: now,
                                              pace: WalkingPaceFactor())
        // 300 s bis Abfahrt - halber Weg (100 s) = 200 s; Luftlinie haette den ganzen Weg (200 s) abgezogen.
        #expect((195...205).contains(withGeometry?.seconds ?? 0))
        #expect(without?.seconds == 100)
    }

    /// Jetzt-Karte: naechste Abbiegung statt Mikroschritt.
    @Test func guidanceSkipsMicroSteps() throws {
        let a = GeoCoordinate(latitude: 51.0, longitude: 7.0)
        let json = """
        {"index":0,"mode":"walk","realtime":false,"cancelled":false,"origin":{"kind":"stop","name":"A","latitude":51.0,"longitude":7.0},
         "destination":{"kind":"stop","name":"B","latitude":51.0,"longitude":7.01},
         "polyline":{"type":"LineString","coordinates":[[7.0,51.0],[7.01,51.0]]},
         "steps":[{"direction":"depart","distanceMeters":70,"streetName":"Hüttenstraße"},
                  {"direction":"continue","distanceMeters":3,"streetName":"Hüttenstraße"},
                  {"direction":"continue","distanceMeters":2},
                  {"direction":"right","distanceMeters":400,"streetName":"Bahnhofstraße"}]}
        """
        let leg = try TransitJSON.decoder().decode(Leg.self, from: Data(json.utf8))
        let g = NavigationEngine.guidance(walk: leg, position: a)
        #expect(g.nextStep?.direction == .right)
        #expect(g.metersToNextStep == 75)
    }
}
