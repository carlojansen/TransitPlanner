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

/// Verkehrsmittel-Pillen der App; Rohwerte wie `modes` in docs/API.md.
public enum ModeFilter: String, Sendable, Hashable, Codable, CaseIterable {
    case tram, subway, suburban, regional, bus
}

/// Stufenfrei reisen (Einstellung); Rohwerte wie `accessibility` in docs/API.md. Wirkt auf die Fusswege, nicht auf Fahrzeuge.
public enum Accessibility: String, Sendable, Hashable, Codable, CaseIterable {
    case none, stepFree
}

/// Zwischenstopp einer Fahrt. Ans Backend gehen nur `id` und `stayMinutes` (docs/API.md `via`);
/// `label` (z. B. Geschaeft) und `coordinate` bleiben auf dem Geraet und dienen der Anzeige und der Erkennung in der Antwort.
public struct ViaStop: Codable, Sendable, Hashable {
    public var id: String
    /// 1-180 Min. (Backend-Regel), immer begrenzt.
    public var stayMinutes: Int { didSet { stayMinutes = min(max(stayMinutes, 1), 180) } }
    public var label: String
    public var coordinate: GeoCoordinate?

    public init(id: String, stayMinutes: Int, label: String, coordinate: GeoCoordinate? = nil) {
        self.id = id
        self.stayMinutes = min(max(stayMinutes, 1), 180)
        self.label = label
        self.coordinate = coordinate
    }

    private enum CodingKeys: String, CodingKey { case id, stayMinutes, label, coordinate }

    /// Auch gespeicherte Werte werden begrenzt (sonst lehnt das Backend den Request ab).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), stayMinutes: try c.decode(Int.self, forKey: .stayMinutes),
                  label: try c.decode(String.self, forKey: .label), coordinate: try c.decodeIfPresent(GeoCoordinate.self, forKey: .coordinate))
    }

    /// MOTIS liefert Bahnsteig-IDs "<station>:7:73": exakt oder mit Praefix "<id>:".
    public func matches(stopID: String) -> Bool { stopID == id || stopID.hasPrefix(id + ":") }

    fileprivate struct Wire: Encodable { let id: String; let stayMinutes: Int }
    fileprivate var wire: Wire { Wire(id: id, stayMinutes: stayMinutes) }
}

/// Aufenthalt an einem Zwischenstopp innerhalb einer Verbindung: Ankunft mit Fahrzeug `arrivalLeg`,
/// weiter mit dem naechsten Fahrzeug (der Umstiegsweg dazwischen gehoert zum Aufenthalt).
public struct ViaStay: Sendable, Hashable {
    public let via: ViaStop
    public let arrivalLeg: Int
    public let arrival: Date?
    public let departure: Date?
}

extension Journey {
    /// Findet je Zwischenstopp (in Reihenfolge) die Grenze, an der der Aufenthalt liegt.
    /// MOTIS liefert an der Grenze eine Bahnsteig-ID ("<station>:7:73") ohne `parentId` (live geprueft 16.11.):
    /// Zuerst zaehlt die ID (exakt oder Praefix "<id>:"). Nur ohne ID-Treffer die Naehe (unter 300 m von `coordinate`),
    /// und nie an einer Grenze, deren ID zu einem anderen Stopp gehoert. Mehrere Treffer: die laengste Pause bis zum
    /// naechsten Fahrzeug (oder, am letzten Fahrzeug, bis zum Fussweg). Kein Treffer: der Stopp fehlt im Ergebnis.
    public func viaStays(_ via: [ViaStop]) -> [ViaStay] {
        var stays: [ViaStay] = []
        var start = 0
        for stop in via {
            let open = legs.indices.dropLast().filter { $0 >= start }
            var candidates = open.filter { Self.idMatches(legs[$0].destination, stop) }
            if candidates.isEmpty {
                candidates = open.filter { pos in
                    Self.isNear(legs[pos].destination, stop)
                        && !via.contains { $0 != stop && Self.idMatches(legs[pos].destination, $0) }
                }
            }
            var best: (pos: Int, stay: ViaStay, gap: TimeInterval)?
            for pos in candidates {
                let leg = legs[pos]
                let next = legs[(pos + 1)...].first(where: { !$0.isWalk }) ?? legs[pos + 1]
                let arrival = leg.arrival ?? leg.plannedArrival
                let departure = next.departure ?? next.plannedDeparture
                let gap = (departure ?? .distantPast).timeIntervalSince(arrival ?? .distantFuture)
                if gap > best?.gap ?? -.infinity {
                    best = (pos, ViaStay(via: stop, arrivalLeg: leg.index, arrival: arrival, departure: departure), gap)
                }
            }
            guard let best else { continue }
            stays.append(best.stay)
            start = best.pos + 1
        }
        return stays
    }

    private static func idMatches(_ place: Place, _ stop: ViaStop) -> Bool {
        place.id.map(stop.matches(stopID:)) ?? false
    }

    private static func isNear(_ place: Place, _ stop: ViaStop) -> Bool {
        guard let a = place.coordinate, let b = stop.coordinate else { return false }
        return a.distance(to: b) < 300
    }
}

/// Body fuer POST /api/routes. Optionale Felder werden weggelassen (Backend lehnt `null` und unbekannte Felder ab).
public struct RoutesRequest: Sendable, Hashable, Encodable {
    public var origin: RoutePoint
    public var destination: RoutePoint
    public var targetTime: Date?
    public var isArrivalTime: Bool
    public var onlyNahverkehr: Bool
    /// Teilmenge der Pillen; nil = voller Nahverkehrsfilter.
    public var modes: [ModeFilter]?
    public var accessibility: Accessibility
    /// 1-6, beim Init begrenzt.
    public private(set) var results: Int
    public var laterThan: String?
    public var earlierThan: String?
    /// Zwischenstopps (max. 2); nil oder leer = keine.
    public var via: [ViaStop]?

    public init(origin: RoutePoint, destination: RoutePoint, targetTime: Date? = nil,
                isArrivalTime: Bool = false, onlyNahverkehr: Bool = true, modes: [ModeFilter]? = nil,
                accessibility: Accessibility = .none, results: Int = 4, via: [ViaStop]? = nil) {
        self.via = via
        self.accessibility = accessibility
        self.origin = origin
        self.destination = destination
        self.targetTime = targetTime
        self.isArrivalTime = isArrivalTime
        self.onlyNahverkehr = onlyNahverkehr
        self.modes = modes
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
        case origin, destination, targetTime, isArrivalTime, onlyNahverkehr, modes, accessibility, results, laterThan, earlierThan, via
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(origin, forKey: .origin)
        try c.encode(destination, forKey: .destination)
        // UTC mit "Z": gueltiges ISO-8601 mit Offset, verraet keine Zeitzone.
        try c.encodeIfPresent(targetTime?.formatted(.iso8601), forKey: .targetTime)
        try c.encode(isArrivalTime, forKey: .isArrivalTime)
        try c.encode(onlyNahverkehr, forKey: .onlyNahverkehr)
        try c.encodeIfPresent(modes, forKey: .modes)
        if accessibility != .none { try c.encode(accessibility, forKey: .accessibility) }
        try c.encode(results, forKey: .results)
        try c.encodeIfPresent(laterThan, forKey: .laterThan)
        try c.encodeIfPresent(earlierThan, forKey: .earlierThan)
        // Backend-Regeln (docs/API.md): max. 2, keine Doppelten, nicht gleich Start/Ziel.
        var seen = Set<String>()
        for case .stop(let id) in [origin, destination] { seen.insert(id) }
        let wire = (via ?? []).filter { seen.insert($0.id).inserted }.prefix(2).map(\.wire)
        if !wire.isEmpty { try c.encode(wire, forKey: .via) }
    }
}

struct RefreshRequest: Encodable {
    let refreshToken: String
    let polylines: Bool
    let accessibility: Accessibility

    private enum CodingKeys: String, CodingKey { case refreshToken, polylines, accessibility }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(refreshToken, forKey: .refreshToken)
        try c.encode(polylines, forKey: .polylines)
        if accessibility != .none { try c.encode(accessibility, forKey: .accessibility) }
    }
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
    var modes: [ModeFilter]? { get }
    var accessibility: Accessibility { get }
    var via: [ViaStop]? { get }
}

public extension TripRequest {
    var accessibility: Accessibility { .none }
    var via: [ViaStop]? { nil }

    /// Einzige Stelle, an der aus einer Fahrt ein Backend-Request wird: nur Punkte, Zeit, Filter.
    func routesRequest(onlyNahverkehr: Bool = true, results: Int = 4) -> RoutesRequest {
        RoutesRequest(origin: origin.routePoint, destination: destination.routePoint, targetTime: targetTime,
                      isArrivalTime: isArrivalTime, onlyNahverkehr: onlyNahverkehr, modes: modes,
                      accessibility: accessibility, results: results, via: via)
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
    public var modes: [ModeFilter]?
    public var accessibility: Accessibility
    /// Optional, damit vor dem Feature gespeicherte Fahrten dekodierbar bleiben.
    public var via: [ViaStop]?

    public init(origin: TripEndpoint, destination: TripEndpoint, targetTime: Date,
                isArrivalTime: Bool = false, trigger: TripTrigger = .manual, modes: [ModeFilter]? = nil,
                accessibility: Accessibility = .none, via: [ViaStop]? = nil) {
        self.via = via
        self.modes = modes
        self.accessibility = accessibility
        self.origin = origin
        self.destination = destination
        self.targetTime = targetTime
        self.isArrivalTime = isArrivalTime
        self.trigger = trigger
    }
}
