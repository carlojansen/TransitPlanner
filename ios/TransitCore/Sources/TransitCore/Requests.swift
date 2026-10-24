import Foundation

public struct GeoCoordinate: Codable, Sendable, Hashable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Coordinate Fuzzing (AGENT.md 3.1.3, docs/API.md): 3 Stellen ~110 m (Umkreis), 4 Stellen ~11 m (Routing).
    public func rounded(decimals: Int) -> GeoCoordinate {
        let f = pow(10.0, Double(decimals))
        return GeoCoordinate(latitude: (latitude * f).rounded() / f, longitude: (longitude * f).rounded() / f)
    }

    /// Grossraum-Distanz (Haversine) in Metern.
    public func distance(to other: GeoCoordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(other.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}

public enum PrivacyRounding {
    public static let nearbyDecimals = 3
    public static let routingDecimals = 4
}

/// Start/Ziel fuer /api/routes. Nur Stop-ID oder (gerundete) Koordinate, nie Name oder Adresse.
public enum RoutePoint: Sendable, Hashable, Encodable {
    case stop(id: String)
    case coordinate(GeoCoordinate)

    private enum CodingKeys: String, CodingKey { case type, id, latitude, longitude }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stop(let id):
            try c.encode("stop", forKey: .type)
            try c.encode(id, forKey: .id)
        case .coordinate(let coord):
            let r = coord.rounded(decimals: PrivacyRounding.routingDecimals)
            try c.encode("coordinate", forKey: .type)
            try c.encode(r.latitude, forKey: .latitude)
            try c.encode(r.longitude, forKey: .longitude)
        }
    }
}

/// Body fuer POST /api/routes. Optionale Felder werden weggelassen (Backend lehnt `null` und unbekannte Felder ab).
public struct RoutesRequest: Sendable, Hashable, Encodable {
    public var origin: RoutePoint
    public var destination: RoutePoint
    public var targetTime: Date?
    public var isArrivalTime: Bool
    public var onlyNahverkehr: Bool
    /// 1-6, beim Init begrenzt.
    public private(set) var results: Int
    public var laterThan: String?
    public var earlierThan: String?

    public init(origin: RoutePoint, destination: RoutePoint, targetTime: Date? = nil,
                isArrivalTime: Bool = false, onlyNahverkehr: Bool = true, results: Int = 4) {
        self.origin = origin
        self.destination = destination
        self.targetTime = targetTime
        self.isArrivalTime = isArrivalTime
        self.onlyNahverkehr = onlyNahverkehr
        self.results = min(max(results, 1), 6)
    }

    /// Paging: alle uebrigen Felder bleiben unveraendert (MOTIS-Regel).
    public func later(_ ref: String) -> RoutesRequest {
        var r = self; r.laterThan = ref; r.earlierThan = nil; return r
    }

    public func earlier(_ ref: String) -> RoutesRequest {
        var r = self; r.earlierThan = ref; r.laterThan = nil; return r
    }

    private enum CodingKeys: String, CodingKey {
        case origin, destination, targetTime, isArrivalTime, onlyNahverkehr, results, laterThan, earlierThan
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(origin, forKey: .origin)
        try c.encode(destination, forKey: .destination)
        // UTC mit "Z": gueltiges ISO-8601 mit Offset, verraet keine Zeitzone.
        try c.encodeIfPresent(targetTime?.formatted(.iso8601), forKey: .targetTime)
        try c.encode(isArrivalTime, forKey: .isArrivalTime)
        try c.encode(onlyNahverkehr, forKey: .onlyNahverkehr)
        try c.encode(results, forKey: .results)
        try c.encodeIfPresent(laterThan, forKey: .laterThan)
        try c.encodeIfPresent(earlierThan, forKey: .earlierThan)
    }
}

struct RefreshRequest: Encodable {
    let refreshToken: String
    let polylines: Bool
}

// MARK: - TripRequest (Kalender-Hook, SPEZIFIKATION 8 Punkt 7)

/// Lokaler Endpunkt einer Fahrt. `label` bleibt auf dem Geraet.
public enum TripEndpoint: Sendable, Hashable, Codable {
    case stop(id: String, label: String)
    case coordinate(GeoCoordinate, label: String)

    public var routePoint: RoutePoint {
        switch self {
        case .stop(let id, _): .stop(id: id)
        case .coordinate(let c, _): .coordinate(c)
        }
    }

    public var label: String {
        switch self {
        case .stop(_, let l), .coordinate(_, let l): l
        }
    }
}

/// Woher eine Fahrt stammt. Kalenderdaten (Kennung) bleiben lokal und gehen nie ans Backend.
public enum TripTrigger: Sendable, Hashable, Codable {
    case manual
    case favorite(id: UUID)
    case calendar(eventIdentifier: String)
}

/// Offen fuer spaetere Quellen (Kalender, Kurzbefehle): Routing und Erinnerungen kennen nur dieses Protokoll.
public protocol TripRequest: Sendable {
    var origin: TripEndpoint { get }
    var destination: TripEndpoint { get }
    var targetTime: Date { get }
    var isArrivalTime: Bool { get }
    var trigger: TripTrigger { get }
}

public extension TripRequest {
    /// Einzige Stelle, an der aus einer Fahrt ein Backend-Request wird: nur Punkte, Zeit, Filter.
    func routesRequest(onlyNahverkehr: Bool = true, results: Int = 4) -> RoutesRequest {
        RoutesRequest(origin: origin.routePoint, destination: destination.routePoint, targetTime: targetTime,
                      isArrivalTime: isArrivalTime, onlyNahverkehr: onlyNahverkehr, results: results)
    }
}

/// Liefert Fahrten aus einer externen Quelle, z. B. spaeter EventKit (Meilenstein 4).
public protocol TripRequestProvider: Sendable {
    func tripRequests(in interval: DateInterval) async throws(TransitError) -> [any TripRequest]
}

public struct ManualTripRequest: TripRequest, Hashable, Codable {
    public var origin: TripEndpoint
    public var destination: TripEndpoint
    public var targetTime: Date
    public var isArrivalTime: Bool
    public var trigger: TripTrigger

    public init(origin: TripEndpoint, destination: TripEndpoint, targetTime: Date,
                isArrivalTime: Bool = false, trigger: TripTrigger = .manual) {
        self.origin = origin
        self.destination = destination
        self.targetTime = targetTime
        self.isArrivalTime = isArrivalTime
        self.trigger = trigger
    }
}
