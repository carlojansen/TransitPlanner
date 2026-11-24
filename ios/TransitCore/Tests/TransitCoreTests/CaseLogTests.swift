import Foundation
import Testing
@testable import TransitCore

struct CaseLogTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000 + 187)
    let here = GeoCoordinate(latitude: 50.93871, longitude: 6.96033)

    @Test func nearMissNurWennMotisReichenWuerde() {
        // 120 s bis Abfahrt, Apple 180 s, MOTIS 90 s: Fall
        let hit = CaseTrigger.departureNearMiss(slackSeconds: -60, walkSeconds: 180, motisWalkSeconds: 90, now: now, near: here)
        #expect(hit?.numbers == ["slack": -60, "walkApple": 180, "walkMotis": 90])
        // auch nach MOTIS nicht erreichbar: kein Fall
        #expect(CaseTrigger.departureNearMiss(slackSeconds: -60, walkSeconds: 180, motisWalkSeconds: 150, now: now, near: here) == nil)
        // erreichbar: kein Fall
        #expect(CaseTrigger.departureNearMiss(slackSeconds: 5, walkSeconds: 180, motisWalkSeconds: 90, now: now, near: here) == nil)
    }

    @Test func umplanungNurWennSpaet() {
        #expect(CaseTrigger.replanLate(bufferSeconds: -30, delaySeconds: 60, now: now, near: here) == nil)
        #expect(CaseTrigger.replanLate(bufferSeconds: -30, delaySeconds: 61, now: now, near: here)?.numbers["delay"] == 61)
    }

    @Test func ankunftNurPerZeitUndWeitWeg() {
        #expect(CaseTrigger.arrivalWithoutGPS(endedByTime: true, distanceMeters: 400, now: now, near: here)?.numbers["distance"] == 400)
        #expect(CaseTrigger.arrivalWithoutGPS(endedByTime: true, distanceMeters: 20, now: now, near: here) == nil)
        #expect(CaseTrigger.arrivalWithoutGPS(endedByTime: false, distanceMeters: 400, now: now, near: here) == nil)
    }

    @Test func eintragIstAnonymisiert() {
        let e = CaseEvent(kind: .replanLate, time: now, near: here, numbers: [:])
        #expect(e.time.timeIntervalSince1970.truncatingRemainder(dividingBy: 300) == 0)
        #expect(e.time <= now && now.timeIntervalSince(e.time) < 300)
        #expect(e.latitude == 50.94 && e.longitude == 6.96)
    }

    @Test func ringpufferWirftAelteste() {
        var log = CaseLog()
        for i in 0..<(CaseLog.capacity + 5) {
            log.record(CaseEvent(kind: .replanLate, time: now.addingTimeInterval(Double(i) * 300), numbers: ["i": i]))
        }
        log.record(nil)
        #expect(log.events.count == CaseLog.capacity)
        #expect(log.events.first?.numbers["i"] == 5)
    }

    @Test func gleicherEintragNurEinmal() {
        var log = CaseLog()
        let e = CaseEvent(kind: .replanLate, time: now, numbers: ["delay": 90])
        log.record(e); log.record(e)
        #expect(log.events.count == 1)
    }

    @Test func gleicherFallMitAndererReserveBleibtEinEintrag() {
        var log = CaseLog()
        log.record(CaseEvent(kind: .departureNearMiss, time: now, near: here, numbers: ["slack": -50]))
        log.record(CaseEvent(kind: .departureNearMiss, time: now, near: here, numbers: ["slack": -40]))
        #expect(log.events.count == 1 && log.events[0].numbers["slack"] == -40)
    }

    @Test func protokollIstCodable() throws {
        var log = CaseLog()
        log.record(CaseEvent(kind: .departureNearMiss, time: now, near: here, numbers: ["slack": -1]))
        let back = try JSONDecoder().decode(CaseLog.self, from: JSONEncoder().encode(log))
        #expect(back == log)
    }
}

struct CaseReportTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("caselog-\(UUID().uuidString)")

    func log() -> CaseLog {
        var log = CaseLog()
        log.record(CaseEvent(kind: .departureNearMiss, time: now, near: GeoCoordinate(latitude: 50.93871, longitude: 6.96033),
                             numbers: ["slack": -60]))
        return log
    }

    @Test func berichtEnthaeltNurGerundetesUndVersionen() throws {
        let text = String(decoding: try CaseReport(log: log(), app: "1.0 (7)", os: "26.1").encoded(), as: UTF8.self)
        #expect(text.contains("\"latitude\" : 50.94") && text.contains("\"schema\" : 1") && text.contains("\"kind\" : \"departureNearMiss\""))
        #expect(!text.contains("50.93871") && !text.contains("6.96033"))
    }

    @Test func dateiLandetImOrdnerMitTagesname() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try CaseReport(log: log(), app: "1.0 (7)", os: "26.1").write(to: dir, day: now)
        #expect(url.lastPathComponent == "Bericht-2027-01-15.json")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func speicherRundreiseUndKaputteDateiGibtLeeresProtokoll() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CaseLogStore(url: dir.appendingPathComponent("log.json"))
        #expect(store.load().events.isEmpty)
        store.save(log())
        #expect(store.load() == log())
        try Data("kaputt".utf8).write(to: store.url)
        #expect(store.load().events.isEmpty)
        store.save(log()) // kaputter Inhalt wird ersetzt
        #expect(store.load() == log())
        #expect(try store.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func knappVerworfeneAbfahrtAusVerbindungen() throws {
        var pace = WalkingPaceFactor()
        pace.manualOverride = 1.5
        let timetable = try Fixture.routes().journeys.map { CalibratedJourney(timetable: $0, pace: pace) }
        // Fahrplan-Fallback (nur Tempo-Faktor) ist kein Apple-Fall
        let dep0 = try #require(timetable[0].journey.legs.first { !$0.isWalk }?.departure)
        #expect(CaseTrigger.departureNearMisses(in: timetable, now: dep0.addingTimeInterval(-400)).isEmpty)
        let items = timetable.map { item in
            CalibratedJourney(journey: item.journey, walks: item.walks.mapValues {
                WalkEstimate(legIndex: $0.legIndex, seconds: $0.seconds, distanceMeters: $0.distanceMeters, source: .appleMaps)
            }, transfers: item.transfers)
        }
        let departure = try #require(items[0].journey.legs.first { !$0.isWalk }?.departure)
        // 300 s MOTIS-Weg, 450 s mit Tempo 1,5; 400 s vor Abfahrt: nur mit MOTIS erreichbar
        let hit = CaseTrigger.departureNearMisses(in: items, now: departure.addingTimeInterval(-400))
        #expect(hit.count == 1 && hit[0].numbers == ["slack": -50, "walkApple": 450, "walkMotis": 300])
        // Ort = Einstiegshalt, nicht der Start des Zugangswegs
        let first = try #require(items[0].journey.legs.first { !$0.isWalk }?.origin.coordinate?.rounded(decimals: 2))
        #expect(hit[0].latitude == first.latitude && hit[0].longitude == first.longitude)
        // genug Zeit: kein Fall
        #expect(CaseTrigger.departureNearMisses(in: items, now: departure.addingTimeInterval(-600)).isEmpty)
    }

    /// Zwei Markierungen im selben 5-Minuten-Fenster ohne Ort bleiben zwei Eintraege.
    @Test func userMarksAreNeverMerged() {
        var log = CaseLog()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        log.record(CaseEvent(kind: .userMark, time: t, numbers: ["phase": 0]))
        log.record(CaseEvent(kind: .userMark, time: t.addingTimeInterval(60), numbers: ["phase": 0]))
        log.record(CaseEvent(kind: .diagnostics, time: t, numbers: ["crashes": 1]))
        log.record(CaseEvent(kind: .diagnostics, time: t, numbers: ["crashes": 1]))
        #expect(log.events.count == 4)
    }
}
