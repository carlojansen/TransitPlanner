import Foundation
import Testing
@testable import TransitCore

/// Fixture: Fussweg > STR 704 (06:08, Gleis 2 statt 1) > Umstieg > RE 5 > Fussweg. Rohes Losgehen 06:02.
@Suite struct TripActivityTests {
    let helper = ReminderPlanTests()

    func journey() throws -> Journey { try helper.journey() }

    func state(_ step: NavigationStep, at time: String, broken: Bool = false) throws -> TripActivityState {
        TripActivityState(journey: try journey(), step: step, leaveAt: helper.at("06:02:00"), broken: broken, now: helper.at(time))
    }

    @Test func phasesFollowTheNowCard() throws {
        #expect(try state(.waitingToLeave(vehicle: 1), at: "05:00:00").phase == .leave)
        #expect(try state(.waitingToLeave(vehicle: 1), at: "05:00:00").target == helper.at("06:02:00"))
        let walk = try state(.approachingFirstStop(vehicle: 1), at: "06:03:00")
        #expect(walk.phase == .walk && walk.target == helper.at("06:08:00") && walk.ride?.line == "STR 704")
        #expect(try state(.waitingAtPlatform(vehicle: 1), at: "06:05:00").phase == .platform)
        let riding = try state(.onBoardTransit(vehicle: 1), at: "06:09:00")
        #expect(riding.phase == .riding && riding.target == helper.at("06:18:00") && riding.stop == "Bilk S")
        let transfer = try state(.transferRouting(from: 1, to: 3), at: "06:17:00")
        #expect(transfer.phase == .transfer && transfer.ride?.line == "RE 5" && transfer.current == 1)
        #expect(try state(.finalWalkToDestination, at: "06:40:00").phase == .finalWalk)
        #expect(try state(.arrived, at: "06:45:00").phase == .arrived)
    }

    /// Gleiche Schwelle wie die Jetzt-Karte.
    @Test func exitNextOnlyInTheLastMinutes() throws {
        let leg = try #require(try journey().legs.first { !$0.isWalk })
        let arrival = helper.at("06:18:00")
        let lastStop = arrival.addingTimeInterval(-NavigationEngine.exitLead)
        #expect(NavigationEngine.exitsNext(leg: leg, now: lastStop) == (NavigationEngine.stopsUntilExit(leg: leg, now: lastStop) <= 1))
        #expect(!NavigationEngine.exitsNext(leg: leg, now: lastStop.addingTimeInterval(-1)))
        #expect(TripActivityState(journey: try journey(), step: .onBoardTransit(vehicle: 1), leaveAt: nil, broken: false,
                                  now: arrival.addingTimeInterval(-60)).phase == .exitNext)
    }

    @Test func platformChangeAndDelayAreSaid() throws {
        let walk = try state(.approachingFirstStop(vehicle: 1), at: "06:03:00")
        #expect(walk.ride?.platformText == "Gleis 2 statt 1")
        #expect(walk.delayMinutes == 2)
        let spoken = walk.spoken(stale: false, includeStops: false)
        #expect(spoken.contains("Gleis 2 statt 1") && spoken.contains("2 Minuten verspätet") && spoken.contains(helper.at("06:08:00").clockText))
        #expect(!spoken.contains("Duesseldorf Hbf"))
        #expect(walk.spoken(stale: false, includeStops: true).contains("Duesseldorf Hbf"))
    }

    @Test func problemsInWords() throws {
        #expect(try state(.onBoardTransit(vehicle: 1), at: "06:09:00", broken: true).title(stale: false) == "Anschluss reicht nicht mehr")
        #expect(try state(.missedDeparture(vehicle: 3), at: "06:30:00").problem == .connection)
        var lost = try helper.plan()
        _ = lost.apply(try helper.journey(replacing: [("\"cancelled\": false,\n      \"realtime\": true", "\"cancelled\": true,\n      \"realtime\": true")]),
                       now: helper.at("05:40:00"))
        #expect(TripActivityState(plan: lost).title(stale: false) == ReminderText.lostTitle(lost.journey))
    }

    @Test func staleLeaveAsksToGo() throws {
        let state = TripActivityState(plan: try helper.plan())
        #expect(state.title(stale: false) == "Losgehen")
        #expect(state.title(stale: true) == "Jetzt losgehen")
    }

    /// ActivityKit erlaubt 4 KB; laengste Fixture mit langen Namen und jedem Feld.
    @Test func contentStaysUnderFourKilobytes() throws {
        let long = String(repeating: "Hauptbahnhof Süd ", count: 12)
        let journey = try helper.journey(replacing: [("Duesseldorf Hbf", long), ("Bilk S", long), ("Koeln Hbf", long)])
        let state = TripActivityState(journey: journey, step: .approachingFirstStop(vehicle: 1), leaveAt: nil, broken: true, now: helper.at("06:03:00"))
        #expect(try JSONEncoder().encode(state).count < 4096)
    }

    @Test func carriesNoLabelsCoordinatesOrTokens() throws {
        let journey = try helper.journey(replacing: [
            (#""kind": "coordinate", "id": null, "name": null"#, #""kind": "coordinate", "id": null, "name": "Zuhause""#),
        ])
        let token = try #require(journey.refreshToken)
        let calibrated = CalibratedJourney(journey: journey, walks: [:], transfers: [])
        let plan = try ReminderPlan(calibrated: calibrated, earlierMinutes: 0, warnMinutes: 0, attribution: Fixture.routes().attribution)
        for state in [TripActivityState(plan: plan),
                      TripActivityState(journey: journey, step: .finalWalkToDestination, leaveAt: nil, broken: false, now: helper.at("06:40:00"))] {
            let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            for forbidden in ["Zuhause", token, "latitude", "longitude", "refreshToken", "polyline", "de-DELFI"] {
                #expect(!json.contains(forbidden), "\(forbidden)")
            }
        }
    }

    // MARK: Start

    func wish(_ time: String, plan: ReminderPlan? = nil) throws -> TripActivityDesire? {
        TripActivityPlanner.reminder(key: "a", plan: try plan ?? helper.plan(), now: helper.at(time))
    }

    @Test func startIsPlannedUntilT15ThenImmediate() throws {
        #expect(try wish("05:00:00")?.startAt == helper.at("05:47:00"))
        #expect(try wish("05:47:00")?.startAt == nil)
        #expect(try wish("05:47:00")?.staleDate == helper.at("06:02:00"))
        #expect(try wish("06:08:00") == nil)
    }

    func running(_ wish: TripActivityDesire, pending: Bool) -> TripActivityRunning {
        TripActivityRunning(key: wish.key, state: wish.state, startAt: wish.startAt, isPending: pending)
    }

    @Test func startsOnceAndOnlyInTheForeground() throws {
        let wish = try #require(try wish("05:00:00"))
        #expect(TripActivityPlanner.actions(running: [], desired: [wish], canStart: true) == [.start(wish)])
        #expect(TripActivityPlanner.actions(running: [], desired: [wish], canStart: false).isEmpty)
        #expect(TripActivityPlanner.actions(running: [running(wish, pending: true)], desired: [wish], canStart: true).isEmpty)
        #expect(TripActivityPlanner.actions(running: [running(wish, pending: false)], desired: [wish], canStart: true).isEmpty)
    }

    /// Geplanter Start ausgeblieben: beim Oeffnen der App ersetzt ein sofortiger Start die haengende Activity.
    @Test func missedScheduledStartFallsBack() throws {
        let planned = try #require(try wish("05:00:00"))
        let due = try #require(try wish("05:50:00"))
        let hanging = running(planned, pending: true)
        #expect(TripActivityPlanner.actions(running: [hanging], desired: [due], canStart: true) == [.end(key: "a"), .start(due)])
        #expect(TripActivityPlanner.actions(running: [hanging], desired: [due], canStart: false).isEmpty)
    }

    @Test func changedStateUpdatesARunningActivity() throws {
        let wish = try #require(try wish("05:50:00"))
        let old = TripActivityRunning(key: "a", state: try state(.waitingAtPlatform(vehicle: 1), at: "05:50:00"), startAt: nil, isPending: false)
        #expect(TripActivityPlanner.actions(running: [old], desired: [wish], canStart: false) == [.update(wish)])
    }

    @Test func unwantedActivityEnds() throws {
        let wish = try #require(try wish("05:50:00"))
        #expect(TripActivityPlanner.actions(running: [running(wish, pending: false)], desired: [], canStart: false) == [.end(key: "a")])
    }

    /// Dieselbe Regel wie bei den Widgets: Eine intakte Fahrt geht vor einer weggefallenen.
    @Test func nextReminderPrefersIntactDueTrip() throws {
        var lost = try helper.plan()
        _ = lost.apply(try helper.journey(replacing: [("\"cancelled\": false,\n      \"realtime\": true", "\"cancelled\": true,\n      \"realtime\": true")]),
                       now: helper.at("05:40:00"))
        let shifted = try helper.journey(replacing: [("T06:", "T07:")])
        let intact = try ReminderPlan(calibrated: CalibratedJourney(journey: shifted, walks: [:], transfers: []), earlierMinutes: 0,
                                      warnMinutes: 0, attribution: Fixture.routes().attribution)
        let chosen = TripActivityPlanner.nextReminder([(key: "lost", plan: lost), (key: "ok", plan: intact)], now: helper.at("06:07:00"))
        #expect(chosen?.key == "ok")
        #expect(TripActivityPlanner.nextReminder([(key: "lost", plan: lost)], now: helper.at("05:45:00"))?.key == "lost")
        #expect(TripActivityPlanner.nextReminder([(key: "lost", plan: lost)], now: helper.at("06:09:00")) == nil)
    }
}
