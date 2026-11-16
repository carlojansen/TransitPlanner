import Foundation
import Testing
@testable import TransitCore

/// Zwischenstopps: was ans Backend geht, und wo der Aufenthalt in einer echten Antwort liegt.
@Suite struct ViaTests {
    static let leverkusen = ViaStop(id: "de-DELFI_de:05316:21101", stayMinutes: 20, label: "Apotheke am Markt",
                                    coordinate: GeoCoordinate(latitude: 51.0318, longitude: 6.9905))

    /// Zero-Knowledge: nur ID und Minuten, kein Label, keine Koordinate. Ohne Stopp fehlt das Feld ganz.
    @Test func requestSendsOnlyIdAndMinutes() throws {
        var req = RoutesRequest(origin: .stop(id: "a"), destination: .stop(id: "b"))
        #expect(try jsonObject(TransitJSON.encoder().encode(req))["via"] == nil)
        req.via = [Self.leverkusen]
        let body = try TransitJSON.encoder().encode(req)
        let via = try jsonObject(body)["via"] as? [[String: Any]]
        #expect(via?.count == 1)
        #expect(via?.first?["id"] as? String == "de-DELFI_de:05316:21101")
        #expect(via?.first?["stayMinutes"] as? Int == 20)
        #expect(via?.first?.count == 2)
        let text = String(decoding: body, as: UTF8.self)
        for secret in ["Apotheke", "label", "latitude", "51.03"] { #expect(!text.contains(secret)) }
    }

    /// Fahrt mit Stopp: der Stopp geht in den Request und ueberlebt das Speichern (Label lokal).
    /// Gespeicherte Fahrten von vor dem Feature (ohne "via") bleiben lesbar.
    @Test func tripCarriesViaAndOldTripsStillDecode() throws {
        let trip = ManualTripRequest(origin: .stop(id: "a", label: "A"), destination: .stop(id: "b", label: "B"),
                                     targetTime: Date.iso("2026-10-24T08:00:00Z"), via: [Self.leverkusen])
        #expect(trip.routesRequest().via == [Self.leverkusen])
        let stored = try JSONEncoder().encode(trip)
        #expect(try JSONDecoder().decode(ManualTripRequest.self, from: stored).via?.first?.label == "Apotheke am Markt")

        var old = try jsonObject(stored)
        old.removeValue(forKey: "via")
        let decoded = try JSONDecoder().decode(ManualTripRequest.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.via == nil)
        #expect(decoded.routesRequest().via == nil)
    }

    /// Echte Antwort (Transitous 16.11., Duesseldorf -> Koeln ueber Leverkusen Mitte, 20 Min.).
    /// Die Grenze traegt die Bahnsteig-ID "...:21101:7:73", angefragt war die Station "...:21101".
    /// Verbindung 1 steigt danach am selben Bahnhof in einen Bus um und spaeter in Opladen ("...:22101") noch einmal:
    /// Opladen ist kein Zwischenstopp, obwohl die ID aehnlich beginnt.
    static func viaRoutes() throws -> RoutesResponse {
        try TransitJSON.decoder().decode(RoutesResponse.self, from: Fixture.data("routes-via", "json"))
    }

    @Test func findsStayByStationIdPrefix() throws {
        let journeys = try Self.viaRoutes().journeys
        let first = journeys[0].viaStays([Self.leverkusen])
        #expect(first.map(\.arrivalLeg) == [1])
        #expect(first.first?.arrival == Date.iso("2026-11-16T11:43:00Z"))
        #expect(first.first?.departure == Date.iso("2026-11-16T12:14:00Z")) // naechstes Fahrzeug, nicht der Umstiegsweg
        #expect(journeys[1].viaStays([Self.leverkusen]).map(\.arrivalLeg) == [1])
        #expect(journeys[1].viaStays([Self.leverkusen]).first?.departure == Date.iso("2026-11-16T12:29:00Z"))
    }

    /// Fremde ID (MOTIS bildet z. B. eine Flixbus-ID auf den DELFI-Bahnhof ab): Rueckfall auf die Naehe.
    /// Ohne Koordinate und ohne passende ID: kein Treffer statt einer geratenen Grenze.
    @Test func fallsBackToProximityAndOtherwiseFindsNothing() throws {
        let journey = try Self.viaRoutes().journeys[0]
        let flix = ViaStop(id: "eu-flixbus_dcbac956", stayMinutes: 20, label: "x", coordinate: Self.leverkusen.coordinate)
        #expect(journey.viaStays([flix]).map(\.arrivalLeg) == [1])
        let unknown = ViaStop(id: "eu-flixbus_dcbac956", stayMinutes: 20, label: "x")
        #expect(journey.viaStays([unknown]).isEmpty)
        let far = ViaStop(id: "de-DELFI_de:05316:2110", stayMinutes: 20, label: "x", coordinate: GeoCoordinate(latitude: 50.0, longitude: 7.0))
        #expect(journey.viaStays([far]).isEmpty) // "...:2110" ist kein Praefix-Treffer fuer "...:21101"
    }

    static let opladen = ViaStop(id: "de-DELFI_de:05316:22101", stayMinutes: 5, label: "Opladen")
    static let opladenCoordinate = GeoCoordinate(latitude: 51.0678, longitude: 7.0049)

    /// Zwei Stopps in Reihenfolge. Die Naehe darf keinem Stopp die Grenze nehmen, die per ID einem anderen gehoert.
    @Test func twoStopsAndIdBeatsProximity() throws {
        let journey = try Self.viaRoutes().journeys[1]
        #expect(journey.viaStays([Self.leverkusen, Self.opladen]).map(\.arrivalLeg) == [1, 3])
        let foreignNearOpladen = ViaStop(id: "eu-flixbus_x", stayMinutes: 5, label: "x", coordinate: Self.opladenCoordinate)
        let stays = journey.viaStays([foreignNearOpladen, Self.opladen])
        #expect(stays.map(\.arrivalLeg) == [3])
        #expect(stays.first?.via.id == Self.opladen.id)
    }

    /// Stopp am letzten Fahrzeug: weiter geht es zu Fuss, die Abfahrt ist der Start des Fusswegs.
    @Test func stopAtLastVehicleUsesFollowingWalk() throws {
        let journey = try Self.viaRoutes().journeys[0]
        let koeln = ViaStop(id: "de-DELFI_de:05315:11201", stayMinutes: 1, label: "Koeln")
        let stay = journey.viaStays([koeln]).first
        #expect(stay?.arrivalLeg == 3)
        #expect(stay?.departure == Date.iso("2026-11-16T12:29:00Z"))
    }

    /// Gespeicherte oder manipulierte Werte: Minuten werden auch beim Dekodieren begrenzt. Der Request schickt
    /// hoechstens 2 Stopps, ohne Doppelte und ohne Start/Ziel (sonst lehnt das Backend ab). Paging behaelt `via`.
    @Test func clampsAndSanitizesBeforeSending() throws {
        let low = try JSONDecoder().decode(ViaStop.self, from: Data(#"{"id":"a","stayMinutes":0,"label":"x"}"#.utf8))
        let high = try JSONDecoder().decode(ViaStop.self, from: Data(#"{"id":"a","stayMinutes":999,"label":"x"}"#.utf8))
        #expect(low.stayMinutes == 1)
        #expect(high.stayMinutes == 180)

        let v = { (id: String) in ViaStop(id: id, stayMinutes: 10, label: id) }
        let req = RoutesRequest(origin: .stop(id: "a"), destination: .stop(id: "b"), via: [v("a"), v("x"), v("x"), v("b"), v("y"), v("z")])
        let ids = try jsonObject(TransitJSON.encoder().encode(req.later("ref")))["via"] as? [[String: Any]]
        let sent: [String] = ids?.compactMap { $0["id"] as? String } ?? []
        #expect(sent == ["x", "y"])
    }
}
