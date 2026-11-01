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

    func snapshot(_ plans: ReminderPlan...) -> TripSnapshot { TripSnapshot(plans: plans) }

    @Test func emptySnapshotHasOneEmptyEntry() {
        #expect(TripSnapshot.empty.timeline(now: helper.at("05:00:00")) == [.init(date: helper.at("05:00:00"), trip: nil)])
    }

    /// Countdown-Beginn, Losgehen, Abfahrt, Fahrzeuge, Ankunft; Fixture: Losgehen 06:02, Abfahrt 06:08, Ankunft der Fahrt spaeter.
    @Test func timelineFollowsTheTripAndDropsItAtArrival() throws {
        let plan = try helper.plan()
        let trip = try #require(snapshot(plan).trips.first)
        let start = helper.at("04:00:00")
        let steps = snapshot(plan).timeline(now: start)
        let rides = trip.rides.compactMap(\.arrival)
        #expect(steps.dropLast().map(\.date) == [start, trip.leaveAt.addingTimeInterval(-TripSnapshot.countdownLead), trip.leaveAt,
                                                 trip.firstDeparture] + rides)
        // Die Ankunft liegt weniger als den Mindestabstand nach dem letzten Fahrzeug.
        #expect(steps.last?.date == rides.last.map { max(trip.arrival, $0.addingTimeInterval(TripSnapshot.minimumEntryGap)) })
        #expect(steps.dropLast().allSatisfy { $0.trip == trip })
        #expect(steps.last?.trip == nil)
    }

    @Test func tripsOverAtStartAreGone() throws {
        let snapshot = snapshot(try helper.plan())
        let arrival = try #require(snapshot.trips.first?.arrival)
        #expect(snapshot.timeline(now: arrival) == [.init(date: arrival, trip: nil)])
        #expect(snapshot.timeline(now: arrival.addingTimeInterval(1)).count == 1)
    }

    /// Dicht liegende Aenderungen: nie unter dem Mindestabstand, die Ankunft geht trotzdem nicht verloren.
    @Test(arguments: stride(from: 0, to: 3600, by: 97).map(TimeInterval.init))
    func entriesKeepTheirDistanceAndOrder(offset: TimeInterval) throws {
        let early = try helper.plan()
        let late = try helper.plan(earlier: 2)
        let snapshot = snapshot(late, early)
        let now = helper.at("05:00:00").addingTimeInterval(offset)
        let steps = snapshot.timeline(now: now)
        for (a, b) in zip(steps.dropFirst(), steps.dropFirst(2)) {
            #expect(b.date.timeIntervalSince(a.date) >= TripSnapshot.minimumEntryGap)
        }
        #expect(steps.first?.date == now)
        #expect(steps.last?.trip == nil)
    }

    /// Zwei Fahrten, Losgehen 06:00 und 06:02, Abfahrt je 06:08: Wechsel innerhalb des Abstands stecken im spaeteren Eintrag.
    @Test func nearChangesWaitAndMerge() throws {
        let snapshot = snapshot(try helper.plan(earlier: 2), try helper.plan())
        let steps = snapshot.timeline(now: helper.at("05:59:00"))
        #expect(steps.prefix(4).map(\.date) == ["05:59:00", "06:00:00", "06:05:00", "06:10:00"].map(helper.at))
    }

    /// Kurz vor dem Losgehen wartet der Wechsel nicht auf den Abstand zum ersten Eintrag.
    @Test func firstChangeIgnoresTheGapToNow() throws {
        let snapshot = snapshot(try helper.plan())
        let trip = try #require(snapshot.trips.first)
        let steps = snapshot.timeline(now: trip.leaveAt.addingTimeInterval(-30))
        #expect(steps.dropFirst().first?.date == trip.leaveAt)
        #expect(steps.dropFirst().first?.trip?.phase(at: trip.leaveAt) == .leaveNow)
    }

    /// Nach dem Umstieg steht ohne Reload das neue Fahrzeug da.
    @Test func arrivalOfARideIsAnEntry() throws {
        let snapshot = snapshot(try helper.plan())
        let trip = try #require(snapshot.trips.first)
        let first = try #require(trip.rides.first?.arrival)
        let steps = snapshot.timeline(now: first.addingTimeInterval(-600))
        #expect(steps.map(\.date).contains(first))
        #expect(trip.ride(at: first.addingTimeInterval(-1))?.line == "STR 704")
        #expect(trip.ride(at: first)?.line == "RE 5")
    }

    @Test func arrivedRidesLeaveTheList() throws {
        let trip = try #require(snapshot(try helper.plan()).trips.first)
        let first = try #require(trip.rides.first?.arrival)
        #expect(trip.remainingRides(at: helper.at("05:00:00")).map(\.line) == ["STR 704", "RE 5"])
        #expect(trip.remainingRides(at: first).map(\.line) == ["RE 5"])
        #expect(trip.remainingRides(at: trip.arrival).isEmpty)
    }

    func cancelledPlan(legToo: Bool = true) throws -> ReminderPlan {
        var plan = try helper.plan()
        var pairs = [("\"cancelled\": false,\n      \"realtime\": true", "\"cancelled\": true,\n      \"realtime\": true")]
        if legToo { pairs.append(("\"durationSeconds\": 900, \"realtime\": true, \"cancelled\": false", "\"durationSeconds\": 900, \"realtime\": true, \"cancelled\": true")) }
        _ = plan.apply(try helper.journey(replacing: pairs), now: helper.at("05:40:00"))
        return plan
    }

    /// Weggefallen endet bei der Abfahrt wie in der App, die naechste Fahrt rueckt nach.
    @Test func lostTripEndsAtDeparture() throws {
        let next = try plan(helper.journey(replacing: [("T06:", "T09:")]))
        let snapshot = snapshot(try cancelledPlan(), next)
        let lost = try #require(snapshot.trips.first)
        #expect(lost.endsAt == lost.firstDeparture)
        #expect(snapshot.trip(at: lost.firstDeparture.addingTimeInterval(-1)) == lost)
        #expect(snapshot.trip(at: lost.firstDeparture) == snapshot.trips.last)
        #expect(snapshot.timeline(now: helper.at("05:45:00")).contains { $0.date == lost.firstDeparture && $0.trip == snapshot.trips.last })
    }

    /// Weggefallen mit frueherem Losgehen verdeckt keine intakte Fahrt, deren Losgehen ansteht.
    @Test func intactTripGoesBeforeLostOneWhenDue() throws {
        let lost = try cancelledPlan()
        let intact = try plan(helper.journey(replacing: [("T06:", "T07:")]))
        let both = snapshot(lost, intact)
        #expect(both.trip(at: helper.at("06:07:00"))?.status == .scheduled) // beide stehen an
        let far = snapshot(lost, try plan(helper.journey(replacing: [("T06:", "T09:")])))
        #expect(far.trip(at: helper.at("05:45:00"))?.status == .lost) // die andere steht noch nicht an
    }

    /// Frueheres Losgehen gewinnt; ist A abgefahren, geht B vor, sobald dessen Losgehen ansteht.
    @Test func overlappingTrips() throws {
        let a = try plan(helper.journey())
        let b = try plan(helper.journey(replacing: [("T06:", "T07:")]))
        let far = try plan(helper.journey(replacing: [("T06:", "T09:")]))
        let snapshot = snapshot(a, b)
        let (first, second) = (snapshot.trips[0], snapshot.trips[1])
        #expect(snapshot.trip(at: helper.at("06:05:00")) == first) // A zaehlt herunter, B liegt noch weit vorn
        #expect(snapshot.trip(at: helper.at("06:10:00")) == second) // A faehrt, B zaehlt herunter
        let quiet = self.snapshot(a, far)
        #expect(quiet.trip(at: helper.at("06:10:00")) == quiet.trips.first) // B steht noch nicht an
    }

    @Test func phasesFollowTheClock() throws {
        let trip = try #require(snapshot(try helper.plan()).trips.first)
        #expect(trip.phase(at: trip.leaveAt.addingTimeInterval(-TripSnapshot.countdownLead - 1)) == .later)
        #expect(trip.phase(at: trip.leaveAt.addingTimeInterval(-TripSnapshot.countdownLead)) == .soon)
        #expect(trip.phase(at: trip.leaveAt) == .leaveNow)
        #expect(trip.phase(at: trip.firstDeparture) == .riding)
    }

    @Test func spokenTextUsesClockAndHidesStopsWhenRedacted() throws {
        let trip = try #require(snapshot(try helper.plan()).trips.first)
        let before = helper.at("05:00:00")
        let time = trip.leaveAt.clockText
        let full = trip.spoken(at: before, includeStops: true)
        #expect(full.hasPrefix("Losgehen ca. \(time)"))
        #expect(full.contains("STR 704") && full.contains("Gleis 2 statt 1") && full.contains("Duesseldorf Hbf"))
        let hidden = trip.spoken(at: before, includeStops: false)
        #expect(hidden.contains("STR 704") && !hidden.contains("Duesseldorf Hbf") && !hidden.contains("Koeln Hbf"))
        #expect(trip.spoken(at: trip.leaveAt, includeStops: true).hasPrefix("Jetzt losgehen"))
        #expect(trip.spoken(at: trip.firstDeparture, includeStops: true).hasPrefix("Ankunft \(trip.arrival.clockText)"))
    }

    @Test func delayIsSaidInWordsUntilTheRide() throws {
        var plan = try helper.plan()
        _ = plan.apply(try helper.journey(), now: helper.at("05:40:00"))
        let trip = try #require(snapshot(plan).trips.first)
        #expect(trip.lostText == nil)
        #expect(trip.spoken(at: helper.at("05:45:00"), includeStops: false).hasSuffix("2 Minuten verspätet"))
        #expect(trip.visibleDelay(at: trip.firstDeparture) == nil)
    }

    /// Mitteilung und Widget sprechen gleich, auch wenn nur die Verbindung als ausgefallen markiert ist.
    @Test func journeyCancelledWithoutCancelledLegCountsAsCancelled() throws {
        let plan = try cancelledPlan(legToo: false)
        let trip = try #require(snapshot(plan).trips.first)
        #expect(!trip.rides.contains { $0.cancelled })
        #expect(trip.lostText == ReminderText.lostTitle(plan.journey))
    }

    @Test func olderFileWithoutCancelledStillReads() throws {
        let url = try tempFile()
        try TripSnapshotFile.write(snapshot(try helper.plan()), to: url)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var trips = try #require(object["trips"] as? [[String: Any]])
        trips[0]["cancelled"] = nil
        object["trips"] = trips
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let trip = try #require(TripSnapshotFile.read(url).trips.first)
        #expect(trip.cancelled == nil && !trip.isCancelled)
    }

    @Test func farAwayLeaveTextNamesTheDate() throws {
        let trip = try #require(snapshot(try helper.plan()).trips.first)
        let week = trip.leaveText(at: trip.leaveAt.addingTimeInterval(-8 * 24 * 3600))
        #expect(week.contains(trip.leaveAt.formatted(.dateTime.month(.abbreviated))))
        let days = trip.leaveText(at: trip.leaveAt.addingTimeInterval(-2 * 24 * 3600))
        #expect(days.contains(trip.leaveAt.formatted(.dateTime.weekday(.abbreviated))))
    }

    @Test func lostConnectionIsSaidInWordsFirst() throws {
        let gone = try #require(snapshot(try cancelledPlan()).trips.first)
        #expect(gone.lostText == "Verbindung fällt aus")
        #expect(gone.spoken(at: helper.at("05:45:00"), includeStops: false).hasPrefix("Verbindung fällt aus"))

        var missed = try helper.plan()
        _ = missed.apply(try helper.journey(replacing: [("2026-10-24T06:18:00Z", "2026-10-24T06:40:00Z")]), now: helper.at("05:40:00"))
        #expect(try #require(snapshot(missed).trips.first).lostText == "Anschluss reicht nicht mehr")
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
