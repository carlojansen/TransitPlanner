import Foundation
import Testing
@testable import TransitCore

@Suite struct RankingTests {
    @Test func durationLabelDropsThousandsSeparator() {
        #expect(DurationLabel.short(minutes: 45) == "45 Min.")
        #expect(DurationLabel.short(minutes: 60) == "1 Std.")
        #expect(DurationLabel.short(minutes: 125) == "2 Std. 5 Min.")
        #expect(DurationLabel.short(minutes: 3705) == "2 Tg. 13 Std.")
        #expect(DurationLabel.short(minutes: 2880) == "2 Tg.")
        #expect(DurationLabel.short(minutes: -3) == "0 Min.")
    }

    @Test func bestFirstPrefersEarlierArrivalWithTransferPenalty() throws {
        let response = try Fixture.routes()
        let ranked = response.bestFirst(arrivalSearch: false)
        #expect(ranked.journeys.count == response.journeys.count)
        let best = ranked.journeys[0]
        #expect(response.journeys.allSatisfy { best.rank(arrivalSearch: false) <= $0.rank(arrivalSearch: false) })
    }

    /// Kalibrierte Reihenfolge: movingToFront haelt die uebrigen Verbindungen in ihrer Reihenfolge.
    @Test func movingToFrontKeepsOrderOfRest() throws {
        let response = try Fixture.routes()
        guard response.journeys.count > 2 else { return }
        let moved = response.movingToFront(2)
        #expect(moved.journeys[0] == response.journeys[2])
        #expect(Array(moved.journeys.dropFirst()) == [response.journeys[0], response.journeys[1]] + response.journeys.dropFirst(3))
        #expect(response.movingToFront(0).journeys == response.journeys)
    }

    func routes(replacing pairs: [(String, String)]) throws -> RoutesResponse {
        var text = String(decoding: try Fixture.data("routes", "json"), as: UTF8.self)
        for (a, b) in pairs { text = text.replacingOccurrences(of: a, with: b) }
        return try TransitJSON.decoder().decode(RoutesResponse.self, from: Data(text.utf8))
    }

    /// Verbindung 0: Ankunft 06:18, Abfahrt 06:23, Umstiegsweg 180 s -> 120 s Puffer (gerade noch bequem).
    /// Knapp kostet 15 Min. Strafe plus die 60 s laengeren Fussweg.
    @Test func tightOrMissedTransferIsPenalized() throws {
        let ok = try routes(replacing: []).journeys[0]
        let tight = try routes(replacing: [("\"durationSeconds\": 180,", "\"durationSeconds\": 240,")]).journeys[0]
        let zero = try routes(replacing: [("\"durationSeconds\": 180,", "\"durationSeconds\": 300,")]).journeys[0]
        #expect(tight.rank(arrivalSearch: false) - ok.rank(arrivalSearch: false) == 15 * 60 + 60)
        #expect(zero.rank(arrivalSearch: false) - ok.rank(arrivalSearch: false) >= 24 * 3600)
        #expect(tight.rank(arrivalSearch: true) - ok.rank(arrivalSearch: true) == 15 * 60 + 60)
    }

    /// Ohne knappen Umstieg gewinnt Verbindung 0 (06:42 + 8 Min. + 12 Min. Gehen) gegen 07:00 + 5 Min. Gehen;
    /// mit 60 s Puffer nicht mehr.
    @Test func bestFirstDoesNotPromoteTightTransfer() throws {
        let later = ("06:40:00Z", "07:00:00Z")
        #expect(try routes(replacing: [later]).bestFirst(arrivalSearch: false).journeys[0].transfers == 1)
        let ranked = try routes(replacing: [later, ("\"durationSeconds\": 180,", "\"durationSeconds\": 240,")])
            .bestFirst(arrivalSearch: false)
        #expect(ranked.journeys[0].transfers == 0)
    }

    @Test func zeroSecondsIsMissedEverywhere() {
        #expect(WalkBuffer(seconds: 0).status == .missed)
        #expect(WalkBuffer(seconds: 1).status == .tight)
        #expect(WalkBuffer(seconds: 120).status == .comfortable)
        #expect(TransferCheck(legIndex: 2, slackSeconds: 0).status == .missed)
        #expect(TransferCheck(legIndex: 2, slackSeconds: 0).isAtRisk)
    }

    /// Fixture-Verbindung `index` mit geaenderten Fusswegen (Leg-Index -> Sekunden), Ankunft und Ausfall.
    func journey(_ index: Int, walks: [Int: Int], arrival: String, cancelled: Bool = false) throws -> [String: Any] {
        let list = try jsonObject(Fixture.data("routes", "json"))["journeys"] as? [[String: Any]] ?? []
        guard list.indices.contains(index) else { throw TransitError.decodingFailed }
        var j = list[index]
        var legs = j["legs"] as? [[String: Any]] ?? []
        for (leg, seconds) in walks where legs.indices.contains(leg) { legs[leg]["durationSeconds"] = seconds }
        j["legs"] = legs
        j["arrival"] = arrival
        j["cancelled"] = cancelled
        return j
    }

    func response(_ journeys: [[String: Any]]) throws -> RoutesResponse {
        var root = try jsonObject(Fixture.data("routes", "json"))
        root["journeys"] = journeys
        return try TransitJSON.decoder().decode(RoutesResponse.self, from: JSONSerialization.data(withJSONObject: root))
    }

    /// Verbindung 0: 1 Umstieg, 3 Min. Gehen, Ankunft 06:42. Verbindung 1: direkt, 20 Min. Gehen.
    func umstieg() throws -> [String: Any] { try journey(0, walks: [0: 60, 2: 60, 4: 60], arrival: "2026-10-24T06:42:00Z") }
    func direkt(_ arrival: String, cancelled: Bool = false) throws -> [String: Any] {
        try journey(1, walks: [0: 1200], arrival: "2026-10-24T\(arrival):00Z", cancelled: cancelled)
    }

    /// 06:37 + 20 Min. Gehen verliert gegen 06:42 + 8 Min. Umstieg + 3 Min. Gehen.
    @Test func longWalkLosesAgainstShortTransfer() throws {
        let ranked = try response([direkt("06:37"), umstieg()]).bestFirst(arrivalSearch: false)
        #expect(ranked.journeys[0].transfers == 1)
    }

    /// 30 Min. frueher reicht, um 20 Min. Gehen aufzuwiegen.
    @Test func longWalkWinsWhenMuchEarlier() throws {
        let ranked = try response([umstieg(), direkt("06:12")]).bestFirst(arrivalSearch: false)
        #expect(ranked.journeys[0].transfers == 0)
    }

    @Test func cancelledJourneyOnlyFirstWhenAlone() throws {
        let ranked = try response([umstieg(), direkt("06:12", cancelled: true)]).bestFirst(arrivalSearch: false)
        #expect(ranked.journeys[0].transfers == 1)
        let alone = try response([direkt("06:12", cancelled: true)]).bestFirst(arrivalSearch: false)
        #expect(alone.journeys.count == 1 && alone.journeys[0].cancelled)
    }

    /// Gleicher Fahrplan, nur die kalibrierte Gehzeit des Zugangswegs der Direktfahrt entscheidet.
    @Test func calibratedWalkDecidesRank() throws {
        let routes = try response([umstieg(), direkt("06:40")])
        let transfer = routes.journeys[0], direct = routes.journeys[1]
        func calibrated(_ j: Journey, _ walks: [Int: Int]) -> CalibratedJourney {
            let estimates = walks.reduce(into: [Int: WalkEstimate]()) {
                $0[$1.key] = WalkEstimate(legIndex: $1.key, seconds: $1.value, distanceMeters: nil, source: .appleMaps)
            }
            return CalibratedJourney(journey: j, walks: estimates, transfers: HybridRouteCalculator.transferChecks(j, walks: estimates))
        }
        // Umstieg: 06:38 + 1 Min. + 8 Min. + 3 Min. = 06:50. Direkt: 06:40 + Zugangsweg.
        let a = calibrated(transfer, [0: 60, 2: 60, 4: 60])
        #expect(CalibratedJourney.bestIndex([a, calibrated(direct, [0: 1200])], arrivalSearch: false) == 0)
        #expect(CalibratedJourney.bestIndex([a, calibrated(direct, [0: 60])], arrivalSearch: false) == 1)
        let cancelledDirect = try response([direkt("06:40", cancelled: true)]).journeys[0]
        #expect(CalibratedJourney.bestIndex([a, calibrated(cancelledDirect, [0: 60])], arrivalSearch: false) == 0)
    }
}
