import Foundation
import Testing
@testable import TransitCore

/// Name eines Favoriten: eine Regel in TransitCore, vom Umbenennen genutzt.
@Suite struct FavoriteLabelTests {
    @Test func normalizedLabelTrimsRejectsEmptyAndLimitsLength() {
        #expect(TripEndpoint.normalizedLabel("  Wohnung Oma \n") == "Wohnung Oma")
        #expect(TripEndpoint.normalizedLabel("   \n") == nil)
        #expect(TripEndpoint.normalizedLabel("Wohnung\nOma") == "Wohnung Oma")
        #expect(TripEndpoint.normalizedLabel("") == nil)
        let long = String(repeating: "a", count: 200)
        #expect(TripEndpoint.normalizedLabel(long)?.count == TripEndpoint.maxLabelLength)
    }

    /// Nur der Name wechselt; Ort und Art (Haltestelle oder Koordinate) bleiben, also auch der `routePoint`.
    @Test func relabeledKeepsThePlace() {
        let stop = TripEndpoint.stop(id: "de-DELFI_de:05315:11201", label: "Köln Hbf")
        let spot = TripEndpoint.coordinate(GeoCoordinate(latitude: 51.2, longitude: 6.8), label: "Musterstraße 1")
        #expect(stop.relabeled("Uni").label == "Uni")
        #expect(stop.relabeled("Uni").routePoint == stop.routePoint)
        #expect(spot.relabeled("Zuhause").label == "Zuhause")
        #expect(spot.relabeled("Zuhause").routePoint == spot.routePoint)
    }
}
