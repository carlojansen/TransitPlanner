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
        #expect(NavigationEngine.exitsNext(leg: leg, now: lastStop))
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

    // MARK: Inhalt

    static let cancelledTram = (#""durationSeconds": 600, "realtime": true, "cancelled": false"#, #""durationSeconds": 600, "realtime": true, "cancelled": true"#)
    static let cancelledJourney = ("\"cancelled\": false,\n      \"realtime\": true", "\"cancelled\": true,\n      \"realtime\": true")
    static let lateTramArrival = ("\"arrivalDelaySeconds\": 120,\n          \"durationSeconds\": 600", "\"arrivalDelaySeconds\": 300,\n          \"durationSeconds\": 600")

    /// Datenschutz: ein benannter Koordinatenpunkt als Ende des letzten Fahrzeugs geht nie in die Activity.
    @Test func destinationIsOnlyAStop() throws {
        #expect(try state(.onBoardTransit(vehicle: 1), at: "06:09:00").destination == "Koeln Hbf")
        let hidden = try helper.journey(replacing: [
            (#""destination": { "kind": "stop", "id": "de-DELFI_de:05315:11201", "name": "Koeln Hbf""#,
             #""destination": { "kind": "coordinate", "id": null, "name": "Zuhause""#),
        ])
        let state = TripActivityState(journey: hidden, step: .onBoardTransit(vehicle: 1), leaveAt: nil, broken: false, now: helper.at("06:09:00"))
        #expect(state.destination == nil)
    }

    /// Unbekanntes Ziel beim Umstieg: die Leg-Bar bleibt am Ende stehen, nicht am Anfang.
    @Test func unknownVehicleKeepsTheLastPlace() throws {
        let state = try state(.transferRouting(from: 1, to: 99), at: "06:17:00")
        #expect(state.ride == nil && state.current == 1)
    }

    /// Nach dem Ausstieg gelten Ziel und letztes Fahrzeug: weder Gleis noch Verspaetung, und ein frueherer Ausfall zaehlt nicht mehr.
    @Test func afterTheLastVehicleOnlyTheDestinationCounts() throws {
        for step in [NavigationStep.finalWalkToDestination, .arrived] {
            let done = try state(step, at: "06:40:00")
            #expect(done.ride == nil && done.delayMinutes == nil && done.stop == "Koeln Hbf" && done.current == 1)
            #expect(TripActivityState(journey: try helper.journey(replacing: [Self.cancelledTram]), step: step, leaveAt: nil, broken: false,
                                      now: helper.at("06:40:00")).problem == nil)
        }
    }

    @Test func delayFollowsTheCountdown() throws {
        let late = try helper.journey(replacing: [Self.lateTramArrival])
        func delay(_ step: NavigationStep, _ time: String) -> Int? {
            TripActivityState(journey: late, step: step, leaveAt: nil, broken: false, now: helper.at(time)).delayMinutes
        }
        #expect(delay(.approachingFirstStop(vehicle: 1), "06:03:00") == 2)
        #expect(delay(.onBoardTransit(vehicle: 1), "06:09:00") == 5)
        #expect(delay(.onBoardTransit(vehicle: 1), "06:17:00") == 5) // Nächster Halt aussteigen
    }

    @Test func titlesWithoutPlatformOrLine() throws {
        let plain = try helper.journey(replacing: [
            (#""departurePlatform": "2", "plannedDeparturePlatform": "1""#, #""departurePlatform": null, "plannedDeparturePlatform": null"#),
            (##""line": { "name": "STR 704", "productName": "STR", "fahrtNr": "123", "operator": "Rheinbahn", "color": "#E2001A", "textColor": "#FFFFFF" }"##, #""line": null"#),
            (#""line": { "name": "RE 5", "productName": "RE", "fahrtNr": "28517", "operator": "National Express", "color": null, "textColor": null }"#, #""line": null"#),
        ])
        func title(_ step: NavigationStep, _ time: String) -> String {
            TripActivityState(journey: plain, step: step, leaveAt: nil, broken: false, now: helper.at(time)).title(stale: false)
        }
        #expect(title(.approachingFirstStop(vehicle: 1), "06:03:00") == "Zum Halt")
        #expect(title(.waitingAtPlatform(vehicle: 1), "06:05:00") == "Am Halt")
        #expect(title(.onBoardTransit(vehicle: 1), "06:09:00") == "Im Fahrzeug")
        #expect(title(.transferRouting(from: 1, to: 3), "06:17:00") == "Umstieg")
        #expect(try state(.approachingFirstStop(vehicle: 1), at: "06:03:00").title(stale: false) == "Zum Gleis")
        #expect(try state(.onBoardTransit(vehicle: 3), at: "06:25:00").title(stale: false) == "Im RE 5")
        #expect(try state(.transferRouting(from: 1, to: 3), at: "06:17:00").title(stale: false) == "Umstieg in RE 5")
    }

    /// Nur das eigene Fahrzeug zaehlt, solange die Verbindung als Ganzes nicht ausfaellt.
    @Test func cancelledVehicleIsTheOneWeAreOn() throws {
        let journey = try helper.journey(replacing: [Self.cancelledTram])
        func problem(_ vehicle: Int) -> TripActivityState.Problem? {
            TripActivityState(journey: journey, step: .approachingFirstStop(vehicle: vehicle), leaveAt: nil, broken: false, now: helper.at("06:03:00")).problem
        }
        #expect(problem(1) == .cancelled)
        #expect(problem(3) == nil)
    }

    /// Mit Problem kein "Los in": die Abfahrt steht als Uhrzeit da, die Ankunft zaehlt weiter.
    @Test func problemShowsDepartureInsteadOfLeaving() throws {
        var lost = try helper.plan()
        _ = lost.apply(try helper.journey(replacing: [Self.cancelledJourney]), now: helper.at("05:40:00"))
        let state = TripActivityState(plan: lost)
        #expect(state.problem != nil && !state.countsDown)
        #expect(state.target == lost.scheduled.firstDeparture)
        #expect(state.targetLabel == "Abfahrt")
        let waiting = TripActivityState(journey: try helper.journey(), step: .waitingToLeave(vehicle: 1), leaveAt: nil, broken: true, now: helper.at("05:00:00"))
        #expect(waiting.target == helper.at("06:08:00") && waiting.targetLabel == "Abfahrt")
        let riding = try self.state(.onBoardTransit(vehicle: 1), at: "06:09:00", broken: true)
        #expect(riding.countsDown && riding.targetLabel == "Ankunft in")
        #expect(try self.state(.waitingAtPlatform(vehicle: 1), at: "06:05:00").targetLabel == "Abfahrt in")
    }

    @Test func spokenNamesTheCountdownAndAnOldState() throws {
        let walk = try state(.approachingFirstStop(vehicle: 1), at: "06:03:00")
        #expect(walk.spoken(stale: false, includeStops: false).contains("Abfahrt \(helper.at("06:08:00").clockText)"))
        let riding = try state(.onBoardTransit(vehicle: 1), at: "06:09:00")
        #expect(riding.spoken(stale: false, includeStops: false).contains("Ankunft \(helper.at("06:18:00").clockText)"))
        let leaving = TripActivityState(plan: try helper.plan())
        #expect(leaving.spoken(stale: false, includeStops: false).contains("Losgehen \(try #require(leaving.target).clockText)"))
        #expect(try state(.arrived, at: "06:45:00").spoken(stale: false, includeStops: false) == "Angekommen")
        #expect(!walk.spoken(stale: false, includeStops: false).contains("Stand evtl. nicht aktuell"))
        #expect(walk.spoken(stale: true, includeStops: false).contains("Stand evtl. nicht aktuell"))
        #expect(!TripActivityState(plan: try helper.plan()).spoken(stale: true, includeStops: false).contains("Stand evtl. nicht aktuell"))
    }

    // MARK: Veraltet

    @Test func staleDateFollowsTheCountdownOnlyWhereItMeansSomething() throws {
        func stale(_ step: NavigationStep, _ time: String) throws -> Date? {
            TripActivityPlanner.navigation(key: "n", state: try state(step, at: time), now: helper.at(time)).staleDate
        }
        #expect(try stale(.approachingFirstStop(vehicle: 1), "06:03:00") == helper.at("06:10:00"))
        #expect(try stale(.finalWalkToDestination, "06:40:00") == nil)
        #expect(try stale(.missedDeparture(vehicle: 1), "06:12:00") == nil) // Abfahrt 06:08 liegt zurueck
        #expect(try stale(.arrived, "06:45:00") == nil)
    }

    // MARK: Obergrenze

    @Test func trackingEndsAfterArrivalOrWhenMissedInTheBackground() throws {
        let journey = try journey()
        let started = helper.at("06:00:00")
        #expect(NavigationEngine.trackingEnd(journey: journey, startedAt: started, missedInBackgroundSince: nil) == helper.at("07:12:00"))
        #expect(NavigationEngine.trackingEnd(journey: journey, startedAt: started, missedInBackgroundSince: helper.at("06:10:00")) == helper.at("06:15:00"))
        #expect(NavigationEngine.trackingEnd(journey: journey, startedAt: started, missedInBackgroundSince: helper.at("07:10:00")) == helper.at("07:12:00"))
        // Fahrt nach ihrer Ankunft gestartet: nicht sofort wieder beenden.
        #expect(NavigationEngine.trackingEnd(journey: journey, startedAt: helper.at("08:00:00"), missedInBackgroundSince: nil) == helper.at("08:30:00"))
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

    /// Navigation im Wartezustand zeigt sich sofort (SPEZIFIKATION 5.1), nie erst geplant.
    @Test func navigationIsNeverScheduled() throws {
        let wish = TripActivityPlanner.navigation(key: "n", state: try state(.waitingToLeave(vehicle: 1), at: "05:00:00"), now: helper.at("05:00:00"))
        #expect(wish.startAt == nil)
    }

    @Test func dismissedActivityStaysAwayForThisTrip() throws {
        let wish = try #require(try wish("05:50:00"))
        #expect(TripActivityPlanner.actions(running: [], desired: [wish], canStart: true, rejected: ["a"]).isEmpty)
        #expect(TripActivityPlanner.actions(running: [], desired: [wish], canStart: true, rejected: ["b"]) == [.start(wish)])
    }

    @Test func arrivalFinishesAndNeverStarts() throws {
        let walk = try state(.finalWalkToDestination, at: "06:40:00")
        let wish = TripActivityPlanner.navigation(key: "a", state: try state(.arrived, at: "06:41:00"), now: helper.at("06:41:00"))
        let running = TripActivityRunning(key: "a", state: walk, startAt: nil, isPending: false)
        #expect(TripActivityPlanner.actions(running: [running], desired: [wish], canStart: false) == [.finish(wish)])
        #expect(TripActivityPlanner.actions(running: [], desired: [wish], canStart: true).isEmpty)
        let planned = TripActivityRunning(key: "a", state: walk, startAt: helper.at("07:00:00"), isPending: true)
        #expect(TripActivityPlanner.actions(running: [planned], desired: [wish], canStart: true) == [.end(key: "a")])
    }

    /// Im Hintergrund laesst sich nichts neu planen: Falsches endet, ein nur verstrichener Start bleibt stehen.
    @Test func plannedActivityEndsInTheBackgroundWhenWrong() throws {
        let planned = try #require(try wish("05:00:00"))
        var lost = try helper.plan()
        _ = lost.apply(try helper.journey(replacing: [Self.cancelledJourney]), now: helper.at("05:40:00"))
        let cancelled = try #require(try wish("05:40:00", plan: lost))
        #expect(TripActivityPlanner.actions(running: [running(planned, pending: true)], desired: [cancelled], canStart: false) == [.end(key: "a")])
        let moved = try #require(try wish("05:00:00", plan: try helper.plan(earlier: 5)))
        #expect(TripActivityPlanner.actions(running: [running(planned, pending: true)], desired: [moved], canStart: false) == [.end(key: "a")])
        // Spaeter bleibt stehen: neu anlegen ginge hier nicht, und zu frueh schadet nicht.
        #expect(TripActivityPlanner.actions(running: [running(moved, pending: true)], desired: [planned], canStart: false).isEmpty)
    }

    @Test func dismissedMeansSeenAndGoneAfterItsStart() {
        let now = helper.at("05:50:00")
        let immediate = ["a": Date.distantPast]
        #expect(TripActivityPlanner.dismissed(seen: immediate, live: [], now: now) == ["a"]) // weggewischt
        #expect(TripActivityPlanner.dismissed(seen: immediate, live: ["a"], now: now).isEmpty) // laeuft
        #expect(TripActivityPlanner.dismissed(seen: [:], live: [], now: now).isEmpty) // App-Ende: `end` nahm den Key heraus
        #expect(TripActivityPlanner.dismissed(seen: ["a": helper.at("05:51:00")], live: [], now: now).isEmpty) // vor dem Start
        #expect(TripActivityPlanner.dismissed(seen: ["a": now], live: [], now: now) == ["a"]) // ab dem Start sichtbar gewesen
    }

    @Test func onlyExitAndNewProblemsAlert() throws {
        func update(from old: TripActivityState, to new: TripActivityState) -> [TripActivityAction] {
            let wish = TripActivityPlanner.navigation(key: "a", state: new, now: helper.at("06:00:00"))
            return TripActivityPlanner.actions(running: [TripActivityRunning(key: "a", state: old, startAt: nil, isPending: false)],
                                               desired: [wish], canStart: false)
        }
        func alerted(_ actions: [TripActivityAction]) -> Bool {
            if case .update(_, let alert)? = actions.first { return alert }
            return false
        }
        let walk = try state(.approachingFirstStop(vehicle: 1), at: "06:03:00")
        let riding = try state(.onBoardTransit(vehicle: 1), at: "06:09:00")
        let exit = try state(.onBoardTransit(vehicle: 1), at: "06:17:00")
        let broken = try state(.onBoardTransit(vehicle: 1), at: "06:09:00", broken: true)
        #expect(exit.phase == .exitNext)
        #expect(!alerted(update(from: walk, to: riding)))
        #expect(alerted(update(from: riding, to: exit)))
        #expect(alerted(update(from: riding, to: broken)))
        // Bleibt das Problem, meldet sich nur der Wechsel nach "aussteigen".
        let brokenExit = try state(.onBoardTransit(vehicle: 1), at: "06:17:00", broken: true)
        #expect(alerted(update(from: exit, to: brokenExit))) // neues Problem
        #expect(!alerted(update(from: brokenExit, to: exit)))
        let brokenLater = try state(.onBoardTransit(vehicle: 3), at: "06:25:00", broken: true)
        #expect(!alerted(update(from: broken, to: brokenLater))) // gleiches Problem
        // Letzter Zwischenhalt 90 s vor dem Umstieg: "aussteigen" entfaellt, der Umstieg meldet sich.
        let late = try helper.journey(replacing: [(#""arrival": "2026-10-24T06:12:00Z""#, #""arrival": "2026-10-24T06:16:30Z""#)])
        func inTram(_ step: NavigationStep, _ time: String) -> TripActivityState {
            TripActivityState(journey: late, step: step, leaveAt: nil, broken: false, now: helper.at(time))
        }
        let before = inTram(.onBoardTransit(vehicle: 1), "06:15:30")
        #expect(before.phase == .riding)
        #expect(alerted(update(from: before, to: inTram(.transferRouting(from: 1, to: 3), "06:16:00"))))
        #expect(!alerted(update(from: exit, to: inTram(.transferRouting(from: 1, to: 3), "06:16:00")))) // "aussteigen" kam schon
    }

    @Test func strandedActivitiesAreOnlyThosePastLeaving() throws {
        let leaving = TripActivityRunning(key: "a", state: TripActivityState(plan: try helper.plan()), startAt: nil, isPending: false)
        let walking = TripActivityRunning(key: "b", state: try state(.approachingFirstStop(vehicle: 1), at: "06:03:00"), startAt: nil, isPending: false)
        #expect(TripActivityPlanner.stranded([leaving, walking]) == [.end(key: "b")])
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
