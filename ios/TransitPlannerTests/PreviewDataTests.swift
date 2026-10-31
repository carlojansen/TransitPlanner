#if DEBUG
import Foundation
import Testing
import TransitCore
@testable import TransitPlanner

/// Vorschau-Daten dekodieren still zu nil, wenn das JSON bricht; und die Vorschau-Namen versprechen Zustaende.
@MainActor @Suite struct PreviewDataTests {
    @Test func mockResponsesDecode() throws {
        let short = try #require(PreviewData.short?.journeys.first)
        #expect(short.transfers == 0)
        let long = try #require(PreviewData.long?.journeys.first)
        #expect(long.transfers == 3)
        #expect(long.legs.compactMap(\.stopovers).joined().count >= 15)
        let disrupted = try #require(PreviewData.disrupted?.journeys.first)
        #expect(disrupted.legs.contains { $0.replacement })
        #expect(disrupted.departure.map { $0 > PreviewData.base } == true)
        #expect(PreviewData.tight?.journeys.count == 1)
    }

    func navStep(_ setup: PreviewFlow) async -> (AppFlow, NavigationStep?) {
        let flow = AppFlow(setup.dependencies())
        await setup.drive(flow)
        return (flow, flow.navStep)
    }

    @Test func navigationPreviewsShowTheirState() async {
        #expect(await navStep(.navigation(PreviewData.short, atMinute: 7)).1 == .approachingFirstStop(vehicle: 1))
        #expect(await navStep(.navigation(PreviewData.long, atMinute: 25)).1 == .onBoardTransit(vehicle: 1))
        #expect(await navStep(.navigation(PreviewData.long, atMinute: 44)).1 == .transferRouting(from: 1, to: 3))
        let (disrupted, step) = await navStep(.navigation(PreviewData.disrupted, atMinute: 7))
        #expect(step == .approachingFirstStop(vehicle: 1))
        #expect(disrupted.navJourney?.legs.contains { $0.platformChanged == true } == true)
        #expect(await navStep(.navigation(PreviewData.tight, atMinute: 18)).1 == .onBoardTransit(vehicle: 0))
    }

    @Test func arrivalPreviewArrives() async throws {
        let flow = AppFlow(PreviewFlow.arrival.dependencies())
        await PreviewFlow.arrival.drive(flow)
        for _ in 0..<50 where flow.phase != .arrival { try await Task.sleep(for: .milliseconds(20)) }
        #expect(flow.phase == .arrival)
    }

    @Test func emptyAndLoadingPreviews() async {
        let empty = AppFlow(PreviewFlow.noConnections.dependencies())
        await PreviewFlow.noConnections.drive(empty)
        #expect(empty.banner == .noConnections)
        let loading = AppFlow(PreviewFlow.loading.dependencies())
        await PreviewFlow.loading.drive(loading)
        #expect(loading.isPlanning && loading.routes == nil)
    }
}
#endif
