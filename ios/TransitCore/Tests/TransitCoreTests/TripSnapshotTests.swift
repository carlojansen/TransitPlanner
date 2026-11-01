import Foundation
import Testing
@testable import TransitCore

@Suite struct TripSnapshotTests {
    let helper = ReminderPlanTests()

    func plan(_ journey: Journey) throws -> ReminderPlan {
        let calibrated = CalibratedJourney(journey: journey, walks: [:], transfers: [])
        return try ReminderPlan(calibrated: calibrated, earlierMinutes: 0, warnMinutes: 0, attribution: Fixture.routes().attribution)
    }

    func tempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "trip-snapshot.json")
    }

    @Test func mapsTheTimetableOfVehiclesOnly() throws {
        let source = try helper.plan(earlier: 5)
        let trip = try #require(TripSnapshot(plans: [source]).trips.first)
        #expect(trip.leaveAt == source.leaveAt && trip.firstDeparture == helper.at("06:08:00"))
        #expect(trip.walkSeconds == 240 && trip.status == .scheduled && trip.isEstimated)
        #expect(trip.rides.map(\.line) == ["STR 704", "RE 5"])
        let tram = try #require(trip.rides.first)
        #expect(tram.from == "Duesseldorf Hbf" && tram.to == "Bilk S" && tram.lineColor == "#E2001A")
        #expect(tram.platform == "2" && tram.plannedPlatform == "1")
    }

    /// Die Fixture nennt die Punkte absichtlich wie ein Favorit, auch an einem Fahrzeug-Abschnitt.
    @Test func carriesNoLabelsCoordinatesOrTokens() throws {
        let stop = #""origin": { "kind": "stop", "id": "de-DELFI_de:05111:18235", "name": "Duesseldorf Hbf""#
        let journey = try helper.journey(replacing: [
            (#""kind": "coordinate", "id": null, "name": null"#, #""kind": "coordinate", "id": null, "name": "Zuhause""#),
            (stop, #""origin": { "kind": "coordinate", "id": "x", "name": "Zuhause""#),
        ])
        let token = try #require(journey.refreshToken)
        let snapshot = TripSnapshot(plans: [try plan(journey)])
        #expect(snapshot.trips.first?.rides.first?.from == nil)
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        for forbidden in ["Zuhause", token, "latitude", "longitude", "51.2", "6.79", "refreshToken", "polyline", "de-DELFI"] {
            #expect(!json.contains(forbidden), "\(forbidden)")
        }
    }

    /// Ohne exakte Rundreise schriebe `ReminderCenter` bei jedem Vergleich neu.
    @Test func roundTripKeepsFractionalDates() throws {
        let journey = try helper.journey(replacing: [("2026-10-24T06:08:00Z", "2026-10-24T06:08:00.123Z")])
        let snapshot = TripSnapshot(plans: [try plan(journey)])
        let url = try tempFile()
        try TripSnapshotFile.write(snapshot, to: url)
        #expect(TripSnapshotFile.read(url) == snapshot)
        // Atomar: kein Rest neben der Datei, zweites Schreiben ersetzt.
        try TripSnapshotFile.write(.empty, to: url)
        #expect(TripSnapshotFile.read(url) == .empty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count == 1)
    }

    @Test(arguments: ["", "kaputt", "[]", #"{"version":1}"#, #"{"version":2,"trips":[]}"#, #"{"version":1,"trips":[{"leaveAt":"gestern"}]}"#])
    func unknownOrBrokenFileReadsEmpty(content: String) throws {
        let url = try tempFile()
        try Data(content.utf8).write(to: url)
        #expect(TripSnapshotFile.read(url) == .empty)
    }

    @Test func missingFileOrContainerReadsEmpty() throws {
        #expect(TripSnapshotFile.read(nil) == .empty)
        #expect(TripSnapshotFile.read(try tempFile()) == .empty)
    }

    @Test func futureVersionWithReadableTripsStillReadsEmpty() throws {
        let url = try tempFile()
        try TripSnapshotFile.write(TripSnapshot(plans: [try helper.plan()]), to: url)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["version"] = TripSnapshot.currentVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(TripSnapshotFile.read(url) == .empty)
    }

    @Test func unknownFieldsAreIgnored() throws {
        let url = try tempFile()
        let snapshot = TripSnapshot(plans: [try helper.plan()])
        try TripSnapshotFile.write(snapshot, to: url)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["future"] = "x"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(TripSnapshotFile.read(url) == snapshot)
    }

    @Test func writeWithoutContainerIsTyped() throws {
        #expect(throws: TransitError.storageUnavailable) { try TripSnapshotFile.write(.empty, to: nil) }
        let unreachable = try tempFile().appending(path: "fehlt/trip-snapshot.json")
        #expect(throws: TransitError.storageUnavailable) { try TripSnapshotFile.write(.empty, to: unreachable) }
    }

    @Test func endedTripsDropOutAndReloadFollows() throws {
        let snapshot = TripSnapshot(plans: [try helper.plan()])
        let arrival = try #require(snapshot.trips.first?.arrival)
        #expect(snapshot.upcoming(now: arrival).count == 1)
        #expect(snapshot.upcoming(now: arrival.addingTimeInterval(1)).isEmpty)
        #expect(snapshot.nextReload(now: arrival.addingTimeInterval(-60)) == arrival)
        let far = arrival.addingTimeInterval(-7200)
        #expect(snapshot.nextReload(now: far) == far.addingTimeInterval(TripSnapshot.rereadInterval))
        #expect(TripSnapshot.empty.nextReload(now: far) == far.addingTimeInterval(TripSnapshot.rereadInterval))
    }

    @Test func fileStaysOutOfBackupsAfterEveryWrite() throws {
        let url = try tempFile()
        try TripSnapshotFile.write(.empty, to: url)
        try TripSnapshotFile.write(.empty, to: url)
        let values = try URL(filePath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    // Der Simulator kennt keinen Dateischutz; der Test greift nur auf einem echten Geraet.
    #if os(iOS) && !targetEnvironment(simulator)
    @Test func fileIsProtectedUntilFirstUnlock() throws {
        let url = try tempFile()
        try TripSnapshotFile.write(.empty, to: url)
        try TripSnapshotFile.write(.empty, to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attrs[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
    }
    #endif
}
