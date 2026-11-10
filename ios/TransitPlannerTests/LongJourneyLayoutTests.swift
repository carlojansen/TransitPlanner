#if DEBUG
import SwiftUI
import Testing
import TransitCore
@testable import TransitPlanner

/// Lange Verbindungen mit vielen Linien: Zeile "Weitere Verbindungen" und Gleis am Ausstieg.
@MainActor @Suite struct LongJourneyLayoutTests {
    /// Breite der Zeile im Ergebnis-Sheet auf einem 402-pt-iPhone (Listenrand 16 + Innenabstand 16 je Seite).
    static let rowWidth: CGFloat = 338

    func height(_ view: some View, width: CGFloat = rowWidth) -> CGFloat {
        UIHostingController(rootView: view.frame(width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// Vor dem Umbau 170 pt: der Status neben vier festen Badges bekam fast keine Breite und brach zeichenweise um.
    /// Jetzt Zeiten mit Status oben, darunter hoechstens zwei Badge-Zeilen.
    @Test func fourLinesWrapInsteadOfStretching() throws {
        let four = try #require(PreviewData.long?.journeys.first)
        let one = try #require(PreviewData.short?.journeys.first)
        #expect(height(AlternativeRow(journey: one, calibrated: nil)) <= 56)
        #expect(height(AlternativeRow(journey: four, calibrated: nil)) < 100)
    }

    /// Schmaler oder groesser: die Zeile waechst um Badge-Zeilen, nie um zeichenweise gebrochenen Status.
    @Test(arguments: [DynamicTypeSize.large, .accessibility3, .accessibility5])
    func rowStaysBoundedAtEveryTypeSize(_ size: DynamicTypeSize) throws {
        let four = try #require(PreviewData.long?.journeys.first)
        let row = AlternativeRow(journey: four, calibrated: nil).dynamicTypeSize(size)
        // Obergrenze: vier Badge-Zeilen plus Zeiten und Status untereinander, bei AX zusaetzlich die Dauer darunter
        // (gemessen 170 / 281 / 364 pt bei 200 pt Breite, AX plus eine Zeile Dauer).
        let limit: CGFloat = size == .large ? 180 : size == .accessibility3 ? 360 : 470
        #expect(height(row, width: 200) < limit)
        #expect(height(row) <= height(row, width: 200))
    }

    /// Der einzeilige Status darf die Zeile nicht breiter machen als den Platz, auch nicht "Ersatzverkehr" bei AX5.
    @Test(arguments: [DynamicTypeSize.large, .accessibility3, .accessibility5])
    func statusNeverWidensRow(_ size: DynamicTypeSize) throws {
        let sev = try #require(FakeData.routes?.journeys.first { $0.legs.contains(where: \.replacement) })
        for journey in [sev, try #require(PreviewData.long?.journeys.first)] {
            let row = AlternativeRow(journey: journey, calibrated: nil).dynamicTypeSize(size)
            let width = UIHostingController(rootView: row)
                .sizeThatFits(in: CGSize(width: Self.rowWidth, height: .greatestFiniteMagnitude)).width
            #expect(width <= Self.rowWidth)
        }
    }

    @Test func arrivalPlatformOnlyForTrains() throws {
        let long = try #require(PreviewData.long?.journeys.first)
        let deutz = try #require(FakeData.deutz()?.journeys.first)
        let sev = try #require(FakeData.routes?.journeys.first?.legs.first { $0.replacement })
        let shown = Dictionary((long.legs + deutz.legs).filter { !$0.isWalk }.map { ($0.mode, $0.showsArrivalPlatform) },
                               uniquingKeysWith: { first, _ in first })
        #expect(shown == [.regional: true, .nationalExpress: true, .subway: false, .bus: false, .tram: false])
        #expect(sev.showsArrivalPlatform == false)
    }
}
#endif
