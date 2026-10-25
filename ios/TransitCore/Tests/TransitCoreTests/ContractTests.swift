import Foundation
import Testing
@testable import TransitCore

/// Vertrag mit docs/API.md: Fehlercodes, Dekodierung, Request-Form.
@Suite struct ContractTests {
    static let repoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func transitErrorMirrorsAPIDocExactly() throws {
        let doc = try String(contentsOf: Self.repoRoot.appending(path: "docs/API.md"), encoding: .utf8)
        let regex = /^\| `([A-Z_]+)` \| (\d{3}) \|/
        let documented = doc.split(separator: "\n").compactMap { line in
            (try? regex.firstMatch(in: String(line))).flatMap { $0 }.map { (code: String($0.1), status: Int($0.2) ?? 0) }
        }
        #expect(documented.count == 9)
        #expect(Set(documented.map(\.code)) == Set(TransitError.backendCodes.map(\.rawValue)))
        for entry in documented {
            let error = try #require(TransitError(rawValue: entry.code))
            // Statusfallback trifft den Code oder (bei 404) den Geschwister-Code mit gleichem Status.
            #expect(TransitError.fromHTTPStatus(entry.status) == error || entry.status == 404)
        }
        // Lokale Faelle kollidieren nie mit Backend-Codes.
        for local in TransitError.allCases where !TransitError.backendCodes.contains(local) {
            #expect(local.rawValue.hasPrefix("CLIENT_"))
        }
    }

    @Test func transitErrorDescriptionsAreCalmAndPresent() {
        for e in TransitError.allCases { #expect(e.errorDescription?.isEmpty == false) }
        // Aus dem String Catalog, mit Umlauten
        #expect(TransitError.pinningFailed.errorDescription == "Sichere Verbindung zum Server nicht möglich.")
    }

    @Test func decodesRoutesFixture() throws {
        let r = try Fixture.routes()
        #expect(r.journeys.count == 2)
        #expect(r.laterRef == "cursor-later")
        #expect(r.attribution.links.map(\.url.absoluteString).contains("https://transitous.org/sources/"))
        #expect(r.fetchedAt == Date.iso("2026-10-24T06:01:02Z"))

        let j = r.journeys[0]
        #expect(j.legs.map(\.mode) == [.walk, .tram, .walk, .regional, .walk])
        let walk = j.legs[0]
        #expect(walk.origin.kind == .coordinate && walk.origin.id == nil && walk.origin.name == nil)
        #expect(walk.departureDelaySeconds == nil)
        #expect(walk.durationSource == "motis-osm")
        #expect(walk.polyline?.points.first == GeoCoordinate(latitude: 51.2201, longitude: 6.7905))

        let tram = j.legs[1]
        #expect(tram.line?.color == "#E2001A")
        #expect(tram.platformChanged == true)
        #expect(tram.departureDelaySeconds == 120)
        #expect(tram.stopovers?.first?.departure == Date.iso("2026-10-24T06:12:30Z"))
        #expect(tram.remarks?.first?.type == .warning)
        #expect(j.legs[2].isTransfer == true)
        #expect(j.legs[3].departureDelaySeconds == 0)
    }

    @Test func unknownModeDecodesAsUnknown() throws {
        let j = try Fixture.routes().journeys[1]
        #expect(j.modes == [.unknown])
        #expect(j.legs[1].mode == .unknown)
        #expect(j.legs[1].line == nil)
    }

    /// API v0.3: Wegschritte, Ersatzverkehr, Ursache/Wirkung; tolerant bei unbekannten und fehlenden Werten.
    @Test func decodesV03FieldsTolerantly() throws {
        let r = try Fixture.routes()
        let j = r.journeys[0]

        let steps = j.legs[0].steps
        #expect(steps.map(\.direction) == [.depart, .unknown, .elevator, .unknown, .unknown, .left])
        #expect(steps[0].streetName == "Breslauer Platz" && steps[0].distanceMeters == 40 && steps[0].fromLevel == nil)
        #expect(steps[1].toLevel == 0.5)
        #expect(steps[2].distanceMeters == nil && steps[2].toLevel == -1)
        #expect(steps[4].distanceMeters == 3 && steps[4].streetName == nil)
        // Falsche Typen werden nil, die Antwort bleibt lesbar
        #expect(steps[5].distanceMeters == nil && steps[5].fromLevel == nil && steps[5].streetName == nil)
        #expect(j.legs[2].steps.first?.direction == .stairs)
        // Fehlendes `steps` = leer, bei Fussweg wie bei Fahrzeug
        #expect(j.legs[4].steps.isEmpty)
        #expect(j.legs[1].steps.isEmpty)

        #expect(j.legs[1].replacement == false)
        #expect(j.legs[3].replacement == true)
        // Fehlendes `replacement` = false
        #expect(r.journeys[1].legs[1].replacement == false)
        // Kaputte Elemente fallen einzeln weg, lesbare bleiben, die Verbindung bleibt
        #expect(r.journeys[1].legs[0].steps.map(\.direction) == [.right])

        let remarks = try #require(j.legs[1].remarks)
        #expect(remarks[0].cause == "CONSTRUCTION" && remarks[0].effect == "DETOUR" && remarks[0].code == "DETOUR")
        // Unbekannte Wirkung bleibt String, fehlender Code nil
        #expect(remarks[1].effect == "FUTURE_EFFECT" && remarks[1].cause == nil && remarks[1].code == nil)
        #expect(remarks[1].type == .unknown) // unbekannte Meldungsart
        // Fehlende `cause`/`effect` = nil
        #expect(j.remarks[0].cause == nil && j.remarks[0].effect == nil)
    }

    @Test func attributionShowsOnlyHTTPSLinks() throws {
        let json = #"{"text":"t","links":[{"label":"a","url":"https://transitous.org/sources/"},{"label":"b","url":"http://example.org"},{"label":"c","url":"javascript:alert(1)"},{"label":"d","url":"HTTPS://www.openstreetmap.org/copyright"}]}"#
        let a = try TransitJSON.decoder().decode(Attribution.self, from: Data(json.utf8))
        #expect(a.httpsLinks.map(\.label) == ["a", "d"])
    }

    @Test func routesRequestRoundsCoordinatesAndOmitsNulls() throws {
        let req = RoutesRequest(origin: .coordinate(GeoCoordinate(latitude: 51.220_149_9, longitude: 6.790_550_1)),
                                destination: .stop(id: "de-DELFI_de:05315:11201"), results: 9)
        let json = try jsonObject(TransitJSON.encoder().encode(req))
        #expect(Set(json.keys) == ["origin", "destination", "isArrivalTime", "onlyNahverkehr", "results"])
        #expect(json["results"] as? Int == 6)
        #expect(json["onlyNahverkehr"] as? Bool == true)
        let origin = try #require(json["origin"] as? [String: Any])
        #expect(origin["type"] as? String == "coordinate")
        #expect(origin["latitude"] as? Double == 51.2201)
        #expect(origin["longitude"] as? Double == 6.7906)
        let destination = try #require(json["destination"] as? [String: Any])
        #expect(Set(destination.keys) == ["type", "id"])
    }

    @Test func targetTimeIsISO8601WithOffsetAndPagingKeepsFields() throws {
        let base = RoutesRequest(origin: .stop(id: "a"), destination: .stop(id: "b"),
                                 targetTime: Date.iso("2026-10-24T06:15:00Z"), isArrivalTime: true, results: 3)
        let later = base.later("cursor")
        let json = try jsonObject(TransitJSON.encoder().encode(later))
        #expect(json["targetTime"] as? String == "2026-10-24T06:15:00Z")
        #expect(json["laterThan"] as? String == "cursor")
        #expect(json["earlierThan"] == nil)
        #expect(json["isArrivalTime"] as? Bool == true)
        #expect(json["results"] as? Int == 3)
        #expect(later.earlier("x").laterThan == nil)
    }

    /// Zero-Knowledge: Labels (Adressen) und Kalender-Kennungen gelangen nie in den Backend-Request.
    @Test func tripRequestNeverLeaksLabelsOrCalendarData() throws {
        let trip = ManualTripRequest(
            origin: .coordinate(GeoCoordinate(latitude: 51.22, longitude: 6.79), label: "Musterstrasse 5, Zuhause"),
            destination: .stop(id: "de:stop:1", label: "Arbeit"),
            targetTime: Date.iso("2026-10-24T08:00:00Z"),
            isArrivalTime: true,
            trigger: .calendar(eventIdentifier: "EVENT-SECRET-ID"))
        let body = try TransitJSON.encoder().encode(trip.routesRequest())
        let text = String(decoding: body, as: UTF8.self)
        for secret in ["Musterstrasse", "Zuhause", "Arbeit", "EVENT-SECRET-ID", "label", "trigger"] {
            #expect(!text.contains(secret))
        }
    }

    @Test func coordinateRounding() {
        let c = GeoCoordinate(latitude: 51.219_96, longitude: 6.794_32)
        #expect(c.rounded(decimals: 3) == GeoCoordinate(latitude: 51.22, longitude: 6.794))
        #expect(c.rounded(decimals: 4) == GeoCoordinate(latitude: 51.22, longitude: 6.7943))
    }
}
