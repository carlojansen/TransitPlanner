import CoreLocation
import Foundation
import MapKit

/// Suchgebiet fuer MKLocalSearch, immer aus einem CoreLocation-Fix abgeleitet.
public struct SearchRegion: Sendable, Hashable {
    public let center: GeoCoordinate
    public let radiusMeters: Double

    public init(around fix: LocationFix, radiusMeters: Double = 50_000) {
        center = fix.coordinate
        self.radiusMeters = radiusMeters
    }

    public var mapRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
            latitudinalMeters: radiusMeters * 2,
            longitudinalMeters: radiusMeters * 2
        )
    }
}

/// Adress-/POI-Treffer. Bleibt auf dem Geraet; ans Backend geht nur `coordinate`.
public struct AddressResult: Sendable, Hashable {
    public let name: String
    public let subtitle: String?
    public let coordinate: GeoCoordinate

    public init(name: String, subtitle: String?, coordinate: GeoCoordinate) {
        self.name = name
        self.subtitle = subtitle
        self.coordinate = coordinate
    }
}

/// Lokale Adresssuche. Die Region ist Pflichtparameter, damit nie eine IP-basierte Region greift.
public protocol LocalSearching: Sendable {
    func search(_ text: String, in region: SearchRegion) async throws -> [AddressResult]
}

public struct MapKitLocalSearch: LocalSearching {
    public init() {}

    public func search(_ text: String, in region: SearchRegion) async throws -> [AddressResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = region.mapRegion
        request.resultTypes = [.address, .pointOfInterest]
        // Nur Treffer im GPS-Suchgebiet, kein Ausweichen auf eine andere (z. B. IP-basierte) Region.
        request.regionPriority = .required
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.map { item in
            let c = item.location.coordinate
            return AddressResult(
                name: item.name ?? "",
                subtitle: item.address?.shortAddress,
                coordinate: GeoCoordinate(latitude: c.latitude, longitude: c.longitude)
            )
        }
    }
}

public struct SearchResults: Sendable {
    public var addresses: [AddressResult] = []
    public var stops: [Place] = []
    public var attribution: Attribution?
    /// Gesetzt, wenn ein Teil ausfiel; der andere Teil wird trotzdem angezeigt.
    public var addressError: TransitError?
    public var stopError: TransitError?
}

/// Pflichtschalter in der Oberflaeche: Ein Suchtext geht nur im Modus `.stops` ans Backend.
public enum SearchScope: Sendable, Hashable {
    /// Adressen und Orte, nur lokal per MKLocalSearch.
    case address
    /// Nutzer hat ausdruecklich "Haltestelle" gewaehlt: nur Backend-Haltestellensuche, ohne Standort.
    case stops
}

/// Kombinierte Suche: Adressen nur lokal (MKLocalSearch, Region aus GPS), Haltestellen ueber das Backend
/// (ohne Standort), nur im Modus `.stops`. Adresstexte verlassen das Geraet nie (docs/API.md, Zero-Knowledge-Regeln).
public struct SearchService: Sendable {
    private let location: any LocationProviding
    private let localSearch: any LocalSearching
    private let api: TransitAPIClient

    public init(location: any LocationProviding, localSearch: any LocalSearching = MapKitLocalSearch(), api: TransitAPIClient) {
        self.location = location
        self.localSearch = localSearch
        self.api = api
    }

    public func search(_ text: String, scope: SearchScope) async throws(TransitError) -> SearchResults {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return SearchResults() }
        let sendToBackend = scope == .stops
        let searchLocally = scope == .address

        async let stops: Result<LocationsResponse, TransitError>? = sendToBackend
            ? Self.capture { () async throws(TransitError) -> LocationsResponse in try await api.searchStops(q) }
            : nil
        async let addresses: Result<[AddressResult], TransitError>? = searchLocally
            ? Self.capture { () async throws(TransitError) -> [AddressResult] in
                // Ohne GPS-Fix keine Adresssuche (VPN-Schutz, AGENT.md 3.2.4).
                let fix = try await location.currentFix()
                do { return try await localSearch.search(q, in: SearchRegion(around: fix)) }
                catch is CancellationError { throw .cancelled }
                catch { throw .upstreamUnavailable }
            }
            : nil

        var out = SearchResults()
        switch await stops {
        case .success(let r): out.stops = r.places; out.attribution = r.attribution
        case .failure(let e): out.stopError = e
        case nil: break
        }
        switch await addresses {
        case .success(let a): out.addresses = a
        case .failure(let e): out.addressError = e
        case nil: break
        }
        let stopsOK = sendToBackend && out.stopError == nil
        let addressesOK = searchLocally && out.addressError == nil
        if !stopsOK, !addressesOK, let error = out.stopError ?? out.addressError { throw error }
        return out
    }

    private static func capture<T>(_ op: () async throws(TransitError) -> T) async -> Result<T, TransitError> {
        do { return .success(try await op()) } catch { return .failure(error) }
    }
}
