import Foundation
import Testing
@testable import TransitCore

@Suite struct WalkingPaceFactorTests {
    @Test func defaultIsNeutral() {
        let p = WalkingPaceFactor()
        #expect(p.value == 1.0)
        #expect(p.apply(to: 300) == 300)
    }

    @Test func learnsFastWalkerAndClamps() {
        var p = WalkingPaceFactor()
        for _ in 0..<20 { p.record(predictedSeconds: 600, actualSeconds: 510) }
        #expect(abs(p.value - 0.85) < 0.001)
        #expect(p.apply(to: 600) == 510)
        #expect(WalkingPaceFactor(learned: 9).value == WalkingPaceFactor.allowedRange.upperBound)
        #expect(WalkingPaceFactor(learned: .nan).value == 1.0)
    }

    @Test func ignoresOutliersAndShortWalks() {
        var p = WalkingPaceFactor()
        let accepted = [
            p.record(predictedSeconds: 30, actualSeconds: 20),     // zu kurz
            p.record(predictedSeconds: 600, actualSeconds: 3_000), // Pause/Umweg
            p.record(predictedSeconds: 600, actualSeconds: 0),
        ]
        #expect(accepted == [false, false, false])
        #expect(p.sampleCount == 0 && p.value == 1.0)
    }

    @Test func manualOverrideWins() {
        var p = WalkingPaceFactor()
        p.record(predictedSeconds: 600, actualSeconds: 540)
        p.manualOverride = 1.2
        #expect(p.value == 1.2)
        p.manualOverride = nil
        #expect(abs(p.value - 0.9) < 0.001)
    }
}

@Suite struct HybridRouteCalculatorTests {
    let exactOrigin = GeoCoordinate(latitude: 51.220_123, longitude: 6.790_456)

    func calculator(_ directions: FakeDirections) -> HybridRouteCalculator {
        HybridRouteCalculator(api: client(FakeTransport([])), directions: directions)
    }

    @Test func replacesWalkDurationsWithAppleMapsTimesPacedAndDeduplicated() async throws {
        let journeys = try Fixture.routes().journeys
        let directions = FakeDirections()
        let pace = WalkingPaceFactor(learned: 0.8)
        let result = try await calculator(directions).calibrate(journeys, pace: pace, origin: exactOrigin)

        // 3 eindeutige Fusswege (Zugang ist in beiden Verbindungen gleich)
        #expect(directions.recorded.count == 3)
        // Exakte lokale Startkoordinate statt der gerundeten aus der Antwort
        let keyOrigin = exactOrigin.rounded(decimals: 5) // Segment-Schluessel ~1 m
        #expect(directions.recorded.contains { $0.0 == keyOrigin })

        let first = result[0]
        let access = try #require(first.walks[0])
        #expect(access.source == .appleMaps)
        let hbf = GeoCoordinate(latitude: 51.21996, longitude: 6.79432)
        #expect(access.seconds == pace.apply(to: keyOrigin.distance(to: hbf) / 1.2))
        #expect(first.walks.count == 3)
        #expect(result[1].walks[0] == WalkEstimate(legIndex: 0, seconds: access.seconds,
                                                  distanceMeters: access.distanceMeters, source: .appleMaps))
    }

    @Test func fallsBackToTimetableWhenDirectionsFail() async throws {
        let journeys = try Fixture.routes().journeys
        let hbf = GeoCoordinate(latitude: 51.21996, longitude: 6.79432)
        let pace = WalkingPaceFactor(learned: 1.1)
        let result = try await calculator(FakeDirections(failing: [hbf])).calibrate(journeys, pace: pace)
        let access = try #require(result[0].walks[0])
        #expect(access.source == .timetable)
        #expect(access.seconds == pace.apply(to: 300))
        #expect(result[0].walks[2]?.source == .appleMaps)
    }

    @Test func transferCheckUsesCalibratedWalk() async throws {
        let journeys = try Fixture.routes().journeys
        let result = try await calculator(FakeDirections()).calibrate(journeys, pace: WalkingPaceFactor())
        let check = try #require(result[0].transfers.first)
        let walk = try #require(result[0].walks[2]?.seconds)
        #expect(check.legIndex == 2)
        #expect(check.slackSeconds == 300 - walk) // Ankunft 06:18, Abfahrt 06:23
        #expect(!check.isAtRisk)

        let slow = try await calculator(FakeDirections()).calibrate(journeys, pace: WalkingPaceFactor(learned: 2.0))
        #expect(slow[0].transfers.first?.slackSeconds == 300 - (slow[0].walks[2]?.seconds ?? 0))
    }

    @Test func arrivalIncludesCalibratedFinalWalk() async throws {
        let journeys = try Fixture.routes().journeys
        let result = try await calculator(FakeDirections()).calibrate(journeys, pace: WalkingPaceFactor())
        let egress = try #require(result[0].walks[4]?.seconds)
        #expect(result[0].arrivalAtDestination == Date.iso("2026-10-24T06:38:00Z").addingTimeInterval(TimeInterval(egress)))
    }

    @Test func planYieldsSkeletonThenCalibrated() async throws {
        let transport = FakeTransport(json: try Fixture.data("routes", "json"))
        let calc = HybridRouteCalculator(api: client(transport), directions: FakeDirections())
        let trip = ManualTripRequest(origin: .coordinate(exactOrigin, label: "Zuhause"),
                                     destination: .stop(id: "de-DELFI_de:05315:11201", label: "Koeln"),
                                     targetTime: Date.iso("2026-10-24T06:00:00Z"))
        var stages: [String] = []
        for try await stage in calc.plan(trip, pace: WalkingPaceFactor()) {
            switch stage {
            case .skeleton: stages.append("skeleton")
            case .calibrated(_, let j): stages.append("calibrated-\(j.count)")
            }
        }
        #expect(stages == ["skeleton", "calibrated-2"])
        #expect(transport.requests.count == 1)
    }
}

@Suite struct DepartureSchedulerTests {
    static let fixtureText: String = {
        (try? Fixture.data("routes", "json")).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }()

    func journey(replacing pairs: [(String, String)] = []) throws -> Journey {
        var text = Self.fixtureText
        for (a, b) in pairs { text = text.replacingOccurrences(of: a, with: b) }
        return try TransitJSON.decoder().decode(RoutesResponse.self, from: Data(text.utf8)).journeys[0]
    }

    func calibrated(_ j: Journey, accessWalk: Int = 240, transferWalk: Int = 60) -> CalibratedJourney {
        let walks = [
            0: WalkEstimate(legIndex: 0, seconds: accessWalk, distanceMeters: 280, source: .appleMaps),
            2: WalkEstimate(legIndex: 2, seconds: transferWalk, distanceMeters: 90, source: .appleMaps),
        ]
        return CalibratedJourney(journey: j, walks: walks, transfers: HybridRouteCalculator.transferChecks(j, walks: walks))
    }

    @Test func leaveTimeIsRealtimeDepartureMinusWalkMinusBuffer() throws {
        let ttl = try DepartureScheduler(stationBufferSeconds: 120).timeToLeave(for: calibrated(try journey()))
        // Tram 06:08 (inkl. +2 min Echtzeit) - 240 s Fussweg - 120 s Puffer
        #expect(ttl.firstDeparture == Date.iso("2026-10-24T06:08:00Z"))
        #expect(ttl.leaveAt == Date.iso("2026-10-24T06:02:00Z"))
    }

    @Test func pendingStagesSkipPastOnes() throws {
        let ttl = try DepartureScheduler().timeToLeave(for: calibrated(try journey()))
        let all = ttl.pendingStages(now: Date.iso("2026-10-24T05:00:00Z"))
        #expect(all.map(\.stage) == [.liveActivity, .headsUp, .leaveNow])
        #expect(all[0].at == Date.iso("2026-10-24T05:47:00Z"))
        let late = ttl.pendingStages(now: Date.iso("2026-10-24T05:59:00Z"))
        #expect(late.map(\.stage) == [.leaveNow])
        // Nach Aufbruchszeit, Bahn noch nicht weg: sofort "Los"
        let overdue = ttl.pendingStages(now: Date.iso("2026-10-24T06:03:00Z"))
        #expect(overdue.map(\.stage) == [.leaveNow])
        #expect(ttl.pendingStages(now: Date.iso("2026-10-24T06:09:00Z")).isEmpty)
    }

    @Test func delayShiftsAlarmLater() throws {
        let scheduler = DepartureScheduler()
        let before = try scheduler.timeToLeave(for: calibrated(try journey()))
        let delayed = try journey(replacing: [("\"departure\": \"2026-10-24T06:08:00Z\"", "\"departure\": \"2026-10-24T06:13:00Z\"")])
        guard case .shifted(let after, let by) = scheduler.reschedule(before, with: calibrated(delayed)) else {
            Issue.record("erwartet: verschoben"); return
        }
        #expect(by == 300)
        #expect(after.leaveAt == Date.iso("2026-10-24T06:07:00Z"))
        #expect(scheduler.reschedule(before, with: calibrated(try journey())) == .unchanged(before))
    }

    @Test func cancellationOrBrokenTransferLosesConnection() throws {
        let scheduler = DepartureScheduler()
        let before = try scheduler.timeToLeave(for: calibrated(try journey()))
        let cancelled = try journey(replacing: [("\"cancelled\": false,\n      \"realtime\": true", "\"cancelled\": true,\n      \"realtime\": true")])
        #expect(cancelled.cancelled)
        #expect(scheduler.reschedule(before, with: calibrated(cancelled)) == .connectionLost)
        // Umstiegsweg 400 s bei 300 s Umstiegszeit
        #expect(scheduler.reschedule(before, with: calibrated(try journey(), transferWalk: 400)) == .connectionLost)
    }
}
