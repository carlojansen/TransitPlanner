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
    @Test func tightOrMissedTransferIsPenalized() throws {
        let ok = try routes(replacing: []).journeys[0]
        let tight = try routes(replacing: [("\"durationSeconds\": 180,", "\"durationSeconds\": 240,")]).journeys[0]
        let zero = try routes(replacing: [("\"durationSeconds\": 180,", "\"durationSeconds\": 300,")]).journeys[0]
        #expect(tight.rank(arrivalSearch: false) - ok.rank(arrivalSearch: false) == 15 * 60)
        #expect(zero.rank(arrivalSearch: false) - ok.rank(arrivalSearch: false) >= 24 * 3600)
        #expect(tight.rank(arrivalSearch: true) - ok.rank(arrivalSearch: true) == 15 * 60)
    }

    /// Ohne knappen Umstieg gewinnt Verbindung 0 (06:42 + 8 Min.) gegen 06:55; mit 60 s Puffer nicht mehr.
    @Test func bestFirstDoesNotPromoteTightTransfer() throws {
        let later = ("06:40:00Z", "06:55:00Z")
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
}
