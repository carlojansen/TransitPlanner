import Foundation
import Synchronization
@testable import TransitCore

enum Fixture {
    static func data(_ name: String, _ ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw TransitError.internal
        }
        return try Data(contentsOf: url)
    }

    static func routes() throws -> RoutesResponse {
        try TransitJSON.decoder().decode(RoutesResponse.self, from: data("routes", "json"))
    }

    static let attributionJSON = #"{"text":"t","links":[{"label":"Transitous-Datenquellen","url":"https://transitous.org/sources/"}]}"#
    static let emptyLocations = Data(#"{"places":[],"attribution":\#(attributionJSON)}"#.utf8)
}

/// Fake-Netz: liefert vorbereitete Antworten und protokolliert Requests. Kein echter Socket.
final class FakeTransport: HTTPTransport {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var error: URLError?
    }

    private let state: Mutex<(replies: [Reply], requests: [URLRequest])>

    init(_ replies: [Reply]) { state = Mutex((replies, [])) }
    convenience init(json: Data, status: Int = 200, headers: [String: String] = [:]) {
        self.init([Reply(status: status, body: json, headers: headers)])
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = state.withLock { s -> Reply in
            s.requests.append(request)
            return s.replies.count > 1 ? s.replies.removeFirst() : (s.replies.first ?? Reply(status: 500))
        }
        if let error = reply.error { throw error }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else { throw URLError(.badURL) }
        return (reply.body, response)
    }
}

final class InMemorySecretStore: SecretStore {
    private let items: Mutex<[String: Data]>

    init(token: String? = "test-token") {
        items = Mutex(token.map { ["api-token": Data($0.utf8)] } ?? [:])
    }

    func read(_ key: SecretKey) throws(TransitError) -> Data? { items.withLock { $0[key.account] } }
    func write(_ data: Data, for key: SecretKey) throws(TransitError) { items.withLock { $0[key.account] = data } }
    func delete(_ key: SecretKey) throws(TransitError) { _ = items.withLock { $0.removeValue(forKey: key.account) } }
}

struct FakeLocation: LocationProviding {
    var result: Result<LocationFix, TransitError>

    static let duesseldorf = LocationFix(coordinate: GeoCoordinate(latitude: 51.220123, longitude: 6.790456),
                                         horizontalAccuracy: 8, timestamp: Date())

    func currentFix() async throws(TransitError) -> LocationFix { try result.get() }
}

final class FakeLocalSearch: LocalSearching {
    let regions = Mutex<[SearchRegion]>([])
    var recorded: [SearchRegion] { regions.withLock { $0 } }

    func search(_ text: String, in region: SearchRegion) async throws -> [AddressResult] {
        regions.withLock { $0.append(region) }
        return [AddressResult(name: "Musterstrasse 1", subtitle: nil, coordinate: region.center)]
    }
}

/// Fake-MKDirections: Gehzeit = Luftlinie / 1.2 m/s; optional Fehler fuer bestimmte Ziele.
final class FakeDirections: WalkingDirectionsProviding {
    let calls = Mutex<[(GeoCoordinate, GeoCoordinate)]>([])
    var recorded: [(GeoCoordinate, GeoCoordinate)] { calls.withLock { $0 } }
    let failingDestinations: Set<GeoCoordinate>

    init(failing: Set<GeoCoordinate> = []) { failingDestinations = failing }

    func walkingETA(from: GeoCoordinate, to: GeoCoordinate) async throws -> WalkingETA {
        calls.withLock { $0.append((from, to)) }
        if failingDestinations.contains(to.rounded(decimals: 5)) { throw URLError(.notConnectedToInternet) }
        let d = from.distance(to: to)
        return WalkingETA(seconds: d / 1.2, distanceMeters: d)
    }
}

extension Date {
    static func iso(_ s: String) -> Date {
        (try? Date.ISO8601FormatStyle().parse(s)) ?? .distantPast
    }
}

func client(_ transport: FakeTransport, secrets: any SecretStore = InMemorySecretStore(),
            now: @escaping @Sendable () -> Date = { Date() }) -> TransitAPIClient {
    TransitAPIClient(config: .production, transport: transport, secrets: secrets, now: now)
}

func jsonObject(_ data: Data?) throws -> [String: Any] {
    guard let data, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TransitError.decodingFailed
    }
    return obj
}
