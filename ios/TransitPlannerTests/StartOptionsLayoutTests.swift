#if DEBUG
import SwiftUI
import Testing
import TransitCore
@testable import TransitPlanner

/// Plan Teil A: Options-Chips im Start-Kopf und die gemeinsamen Pillen (Planen und Start).
@MainActor @Suite struct StartOptionsLayoutTests {
    /// Sheet-Breite auf einem 402-pt-iPhone minus 2 x 16 Rand.
    static let width: CGFloat = 370

    func size(_ view: some View, _ flow: AppFlow, typeSize: DynamicTypeSize = .large) -> CGSize {
        UIHostingController(rootView: view.environment(flow).dynamicTypeSize(typeSize))
            .sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
    }

    func flow(time: TimeInterval? = nil, modes: Set<ModeFilter> = Set(ModeFilter.allCases)) -> AppFlow {
        let env = ReminderFlowTests.Env()
        env.clock.set("05:00:00") // feste Uhr: "heute" haengt nicht an der Uhrzeit des Testlaufs
        let f = AppFlow(env.deps())
        f.modeFilter = modes
        if let time {
            f.customTime = f.now.addingTimeInterval(time)
            f.isArrivalTime = true
        }
        return f
    }

    /// Normale Schrift: eine Zeile (44 pt) fuer typische Werte ("Ankunft 06:00", "Nur S-Bahn"). Lange Werte (anderer
    /// Tag, mehrere Verkehrsmittel) stehen untereinander statt abgeschnitten. Im kleinsten Detent (140 pt) blendet der
    /// Start die Chips aus.
    @Test func chipsStayOneRowForTypicalValues() {
        let chips = StartOptionChips(open: .constant(nil))
        #expect(size(chips, flow()).height <= 48)
        #expect(size(chips, flow()).height >= 44, "Tippflaeche 44 pt")
        #expect(size(chips, flow(time: 3600, modes: [.suburban])).height <= 48)
        let long = size(chips, flow(time: 2 * 24 * 3600, modes: [.bus, .tram]))
        #expect(long.width <= Self.width)
        #expect(long.height <= 2 * 44 + 8 + 1)
    }

    /// AX3: untereinander, nie breiter als das Sheet; jede Tippflaeche mindestens 44 pt.
    @Test(arguments: [DynamicTypeSize.accessibility3, .accessibility5])
    func chipsStackAtAccessibilitySizes(_ typeSize: DynamicTypeSize) {
        let measured = size(StartOptionChips(open: .constant(nil)), flow(time: 2 * 24 * 3600, modes: [.suburban]), typeSize: typeSize)
        #expect(measured.width <= Self.width)
        #expect(measured.height >= 2 * 44 + 8)
    }

    /// Abstand Ueberschrift zu Pillen (Fehler vom 25.11.): genau `headingSpacing`, Block fuellt die Breite linksbuendig.
    @Test(arguments: [DynamicTypeSize.large, .accessibility3])
    func headingSitsTightAbovePills(_ typeSize: DynamicTypeSize) {
        let f = flow()
        let with = size(ModePills(), f, typeSize: typeSize)
        let without = size(ModePills(showsHeading: false), f, typeSize: typeSize)
        let heading = size(ModePills.heading.frame(maxWidth: .infinity), f, typeSize: typeSize)
        #expect(abs(with.height - without.height - heading.height - ModePills.headingSpacing) < 0.5)
        #expect(with.width == Self.width)
    }
}
#endif
