import Foundation

// Codable-Modelle exakt nach docs/API.md (v0.3). Felder, die das Backend `null` liefern kann, sind optional.

public enum TransitMode: String, Codable, Sendable, CaseIterable {
    case walk, tram, bus, subway, suburban, regional, regionalExpress, ferry, funicular, aerialLift
    case onDemand, airplane, other, national, nationalExpress, unknown

    /// Unbekannte, kuenftige Modi brechen das Dekodieren nicht.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TransitMode(rawValue: raw) ?? .unknown
    }
}

public struct AttributionLink: Codable, Sendable, Hashable {
    public let label: String
    public let url: URL
}

/// Quellenangabe (Transitous, OpenStreetMap). Muss in der App sichtbar sein.
public struct Attribution: Codable, Sendable, Hashable {
    public let text: String
    public let links: [AttributionLink]

    /// Nur https-Links anzeigen (Antwortinhalt ist fremdbestimmt).
    public var httpsLinks: [AttributionLink] {
        links.filter { $0.url.scheme?.lowercased() == "https" && $0.url.host() != nil }
    }
}

public struct Place: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case stop, coordinate }
    public let kind: Kind
    public let id: String?
    public let name: String?
    public let latitude: Double?
    public let longitude: Double?
    public let modes: [TransitMode]?
    /// Nur in /api/locations.
    public let area: String?
    /// Nur in /api/locations (Umkreis oder Naehe-Sortierung).
    public let distanceMeters: Int?

    public var coordinate: GeoCoordinate? {
        guard let latitude, let longitude else { return nil }
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }
}

/// GeoJSON LineString, Koordinaten als [lon, lat].
public struct Polyline: Codable, Sendable, Hashable {
    public let type: String
    public let coordinates: [[Double]]

    public var points: [GeoCoordinate] {
        coordinates.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return GeoCoordinate(latitude: pair[1], longitude: pair[0])
        }
    }
}

public struct Line: Codable, Sendable, Hashable {
    public let name: String?
    public let productName: String?
    public let fahrtNr: String?
    public let `operator`: String?
    /// `#RRGGBB` oder nil
    public let color: String?
    public let textColor: String?
}

public struct Remark: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case hint, warning, unknown

        /// Unbekannte Meldungsarten brechen das Dekodieren nicht.
        public init(from decoder: any Decoder) throws {
            let raw = try? decoder.singleValueContainer().decode(String.self)
            self = raw.flatMap(Kind.init(rawValue:)) ?? .unknown
        }
    }
    public let type: Kind
    public let code: String?
    public let summary: String?
    public let text: String
    /// GTFS-RT-Werte unveraendert (z. B. `CONSTRUCTION`, `STRIKE`) oder nil; unbekannte Werte bleiben String.
    public let cause: String?
    /// GTFS-RT-Werte unveraendert (z. B. `NO_SERVICE`, `DETOUR`, `STOP_MOVED`) oder nil.
    public let effect: String?
}

/// Wegschritt eines Fusswegs (OSM). Geometrie steht in `Leg.polyline`, nicht pro Schritt.
public struct Step: Codable, Sendable, Hashable {
    public enum Direction: String, Codable, Sendable, CaseIterable {
        case depart, `continue`, left, slightlyLeft, hardLeft, right, slightlyRight, hardRight
        case uturnLeft, uturnRight, circleClockwise, circleCounterclockwise, stairs, elevator, unknown

        /// Unbekannte, kuenftige Richtungen brechen das Dekodieren nicht.
        public init(from decoder: any Decoder) throws {
            let raw = try? decoder.singleValueContainer().decode(String.self)
            self = raw.flatMap(Direction.init(rawValue:)) ?? .unknown
        }
    }

    public let direction: Direction
    public let distanceMeters: Int?
    /// OSM-Ebene (auch halbe Ebenen) oder nil. Ein Wechsel heisst Treppe, Rampe oder Aufzug.
    public let fromLevel: Double?
    public let toLevel: Double?
    public let streetName: String?

    private enum CodingKeys: String, CodingKey { case direction, distanceMeters, fromLevel, toLevel, streetName }

    public init(from decoder: any Decoder) throws {
        // Tolerant: ein Feld mit falschem Typ wird nil, statt die ganze Antwort zu brechen.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = ((try? c.decodeIfPresent(Direction.self, forKey: .direction)) ?? nil) ?? .unknown
        distanceMeters = (try? c.decodeIfPresent(Int.self, forKey: .distanceMeters)) ?? nil
        fromLevel = (try? c.decodeIfPresent(Double.self, forKey: .fromLevel)) ?? nil
        toLevel = (try? c.decodeIfPresent(Double.self, forKey: .toLevel)) ?? nil
        streetName = (try? c.decodeIfPresent(String.self, forKey: .streetName)) ?? nil
    }
}

public struct Stopover: Codable, Sendable, Hashable {
    public let stop: Place
    public let arrival: Date?
    public let plannedArrival: Date?
    public let arrivalDelaySeconds: Int?
    public let departure: Date?
    public let plannedDeparture: Date?
    public let departureDelaySeconds: Int?
    public let platform: String?
    public let plannedPlatform: String?
    public let cancelled: Bool
}

/// Ein Abschnitt. Fussweg- und Fahrzeugfelder sind je nach `mode` gesetzt.
public struct Leg: Codable, Sendable, Hashable {
    public let index: Int
    public let mode: TransitMode
    public let origin: Place
    public let destination: Place
    public let departure: Date?
    public let plannedDeparture: Date?
    /// nil = keine Echtzeitdaten (nicht 0)
    public let departureDelaySeconds: Int?
    public let arrival: Date?
    public let plannedArrival: Date?
    public let arrivalDelaySeconds: Int?
    public let durationSeconds: Int?
    public let realtime: Bool
    public let cancelled: Bool
    public let polyline: Polyline?

    // Fussweg
    public let isTransfer: Bool?
    public let distanceMeters: Int?
    public let durationSource: String?
    /// Wegbeschreibung (v0.3); leer bei Fahrzeugen, im Polling und wenn MOTIS keine liefert.
    public let steps: [Step]

    // Fahrzeug
    public let line: Line?
    public let direction: String?
    public let tripId: String?
    public let departurePlatform: String?
    public let plannedDeparturePlatform: String?
    public let arrivalPlatform: String?
    public let plannedArrivalPlatform: String?
    public let platformChanged: Bool?
    /// Schienenersatzverkehr (v0.3); fehlt das Feld, gilt false. `mode` bleibt dabei meist `bus`.
    public let replacement: Bool
    /// Derzeit immer nil (Transitous liefert keine Auslastung).
    public let loadFactor: String?
    public let stopovers: [Stopover]?
    public let remarks: [Remark]?

    public var isWalk: Bool { mode == .walk }

    private enum CodingKeys: String, CodingKey {
        case index, mode, origin, destination, departure, plannedDeparture, departureDelaySeconds
        case arrival, plannedArrival, arrivalDelaySeconds, durationSeconds, realtime, cancelled, polyline
        case isTransfer, distanceMeters, durationSource, steps
        case line, direction, tripId, departurePlatform, plannedDeparturePlatform, arrivalPlatform, plannedArrivalPlatform
        case platformChanged, replacement, loadFactor, stopovers, remarks
    }

    /// Eigener Decoder nur wegen der v0.3-Felder mit Standardwert (`steps` = [], `replacement` = false).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        mode = try c.decode(TransitMode.self, forKey: .mode)
        origin = try c.decode(Place.self, forKey: .origin)
        destination = try c.decode(Place.self, forKey: .destination)
        departure = try c.decodeIfPresent(Date.self, forKey: .departure)
        plannedDeparture = try c.decodeIfPresent(Date.self, forKey: .plannedDeparture)
        departureDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .departureDelaySeconds)
        arrival = try c.decodeIfPresent(Date.self, forKey: .arrival)
        plannedArrival = try c.decodeIfPresent(Date.self, forKey: .plannedArrival)
        arrivalDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .arrivalDelaySeconds)
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds)
        realtime = try c.decode(Bool.self, forKey: .realtime)
        cancelled = try c.decode(Bool.self, forKey: .cancelled)
        polyline = try c.decodeIfPresent(Polyline.self, forKey: .polyline)
        isTransfer = try c.decodeIfPresent(Bool.self, forKey: .isTransfer)
        distanceMeters = try c.decodeIfPresent(Int.self, forKey: .distanceMeters)
        durationSource = try c.decodeIfPresent(String.self, forKey: .durationSource)
        // Wegbeschreibung ist Zusatz: kaputte Schritte kosten nur die Schritte, nicht die Verbindung.
        steps = ((try? c.decodeIfPresent([Step].self, forKey: .steps)) ?? nil) ?? []
        line = try c.decodeIfPresent(Line.self, forKey: .line)
        direction = try c.decodeIfPresent(String.self, forKey: .direction)
        tripId = try c.decodeIfPresent(String.self, forKey: .tripId)
        departurePlatform = try c.decodeIfPresent(String.self, forKey: .departurePlatform)
        plannedDeparturePlatform = try c.decodeIfPresent(String.self, forKey: .plannedDeparturePlatform)
        arrivalPlatform = try c.decodeIfPresent(String.self, forKey: .arrivalPlatform)
        plannedArrivalPlatform = try c.decodeIfPresent(String.self, forKey: .plannedArrivalPlatform)
        platformChanged = try c.decodeIfPresent(Bool.self, forKey: .platformChanged)
        replacement = try c.decodeIfPresent(Bool.self, forKey: .replacement) ?? false
        loadFactor = try c.decodeIfPresent(String.self, forKey: .loadFactor)
        stopovers = try c.decodeIfPresent([Stopover].self, forKey: .stopovers)
        remarks = try c.decodeIfPresent([Remark].self, forKey: .remarks)
    }
}

public struct Journey: Codable, Sendable, Hashable {
    public let refreshToken: String?
    public let departure: Date?
    public let arrival: Date?
    public let durationSeconds: Int?
    public let transfers: Int
    public let modes: [TransitMode]
    public let cancelled: Bool
    public let realtime: Bool
    public let hasPolylines: Bool
    public let legs: [Leg]
    public let remarks: [Remark]
}

public struct LocationsResponse: Codable, Sendable {
    public let places: [Place]
    public let attribution: Attribution
}

public struct RoutesResponse: Codable, Sendable {
    public let journeys: [Journey]
    public let earlierRef: String?
    public let laterRef: String?
    public let walkOnly: Bool
    public let removedLongDistance: Int
    public let fetchedAt: Date
    public let attribution: Attribution
}

public struct RefreshResponse: Codable, Sendable {
    public let journey: Journey
    public let fetchedAt: Date
    public let attribution: Attribution
}

/// `{"error": {"code", "message", "details"?, "retryAfterSeconds"?}}`
struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let retryAfterSeconds: Int?
    }
    let error: Body
}

// MARK: - JSON

public enum TransitJSON {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    /// Backend-Zeiten kommen mit und ohne Sekundenbruchteile (`fetchedAt` hat `.000Z`).
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = try? plain.parse(s) { return date }
            if let date = try? withFraction.parse(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "ISO-8601 erwartet")
        }
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
