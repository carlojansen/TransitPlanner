import Foundation

// Codable-Modelle exakt nach docs/API.md (v0.2). Felder, die das Backend `null` liefern kann, sind optional.

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
    public enum Kind: String, Codable, Sendable { case hint, warning }
    public let type: Kind
    public let code: String?
    public let summary: String?
    public let text: String
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

    // Fahrzeug
    public let line: Line?
    public let direction: String?
    public let tripId: String?
    public let departurePlatform: String?
    public let plannedDeparturePlatform: String?
    public let arrivalPlatform: String?
    public let plannedArrivalPlatform: String?
    public let platformChanged: Bool?
    /// Derzeit immer nil (Transitous liefert keine Auslastung).
    public let loadFactor: String?
    public let stopovers: [Stopover]?
    public let remarks: [Remark]?

    public var isWalk: Bool { mode == .walk }
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

enum TransitJSON {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    /// Backend-Zeiten kommen mit und ohne Sekundenbruchteile (`fetchedAt` hat `.000Z`).
    static func decoder() -> JSONDecoder {
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
