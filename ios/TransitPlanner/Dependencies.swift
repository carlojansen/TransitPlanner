import Foundation
import TransitCore

/// Schmale App-Protokolle ueber den TransitCore-Diensten (RESEARCH-M3 Befund 0.4): Previews und UI-Tests faken hier,
/// der gepinnte Transport von `TransitAPIClient` bleibt intern.
protocol StopSearching: Sendable {
    func search(_ text: String, scope: SearchScope) async throws(TransitError) -> SearchResults
}

protocol RoutePlanning: Sendable {
    func plan(_ trip: some TripRequest, pace: WalkingPaceFactor) -> AsyncThrowingStream<HybridRouteCalculator.Stage, any Error>
}

extension SearchService: StopSearching {}
extension HybridRouteCalculator: RoutePlanning {}

/// Alles, was `AppFlow` von aussen braucht. Produktiv nur gepinnte Dienste; Fakes nur in Debug-Builds.
struct AppDependencies: Sendable {
    var search: any StopSearching
    var planner: any RoutePlanning
    var secrets: any SecretStore
    /// Sperre nach Retry-After (429/502/503/504), aus `TransitAPIClient.blocked`.
    var blockedUntil: @Sendable () async -> Date?
    var now: @Sendable () -> Date = { Date() }
    /// Entprellung der Suche (API.md: mindestens 300 ms).
    var debounce: Duration = .milliseconds(300)

    static func live() -> AppDependencies {
        let api = TransitAPIClient()
        return AppDependencies(
            search: SearchService(location: CoreLocationService(), api: api),
            planner: HybridRouteCalculator(api: api),
            secrets: KeychainSecretStore(),
            blockedUntil: { await api.blocked?.until }
        )
    }

    /// Launch-Argument `-uiTestFakes` schaltet in Debug-Builds auf Fakes um; Release spricht nie ohne Pinning.
    static func forLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppDependencies {
        #if DEBUG
        if arguments.contains("-uiTestFakes") { return .fakes() }
        #endif
        return .live()
    }
}

#if DEBUG
import Synchronization

extension AppDependencies {
    static func fakes(search: FakeStopSearch = FakeStopSearch(), planner: FakeRoutePlanner = FakeRoutePlanner(),
                      secrets: InMemorySecretStore = InMemorySecretStore(), blockedUntil: Date? = nil,
                      debounce: Duration = .milliseconds(300)) -> AppDependencies {
        AppDependencies(search: search, planner: planner, secrets: secrets,
                        blockedUntil: { blockedUntil }, debounce: debounce)
    }
}

/// Fake-Suche ohne Netz und ohne Standort. Protokolliert Aufrufe fuer Tests.
final class FakeStopSearch: StopSearching {
    let calls = Mutex<[String]>([])
    let failure: TransitError?
    let delay: Duration

    init(failure: TransitError? = nil, delay: Duration = .zero) {
        self.failure = failure
        self.delay = delay
    }

    var recorded: [String] { calls.withLock { $0 } }

    func search(_ text: String, scope: SearchScope) async throws(TransitError) -> SearchResults {
        calls.withLock { $0.append(text) }
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { throw .cancelled }
        }
        if let failure { throw failure }
        var r = SearchResults()
        switch scope {
        case .address:
            r.addresses = [AddressResult(name: "Musterstraße 1", subtitle: "Düsseldorf",
                                         coordinate: GeoCoordinate(latitude: 51.2201, longitude: 6.7905))]
        case .stops:
            r.stops = FakeData.stops
            r.attribution = FakeData.routes?.attribution
        }
        return r
    }
}

/// Fake-Planung: Skelett aus eingebettetem JSON, kalibriert ueber den echten Rechner mit Fake-Gehzeiten.
final class FakeRoutePlanner: RoutePlanning {
    let calls = Mutex(0)
    let failure: TransitError?

    init(failure: TransitError? = nil) { self.failure = failure }

    var callCount: Int { calls.withLock { $0 } }

    func plan(_ trip: some TripRequest, pace: WalkingPaceFactor) -> AsyncThrowingStream<HybridRouteCalculator.Stage, any Error> {
        calls.withLock { $0 += 1 }
        let failure = self.failure
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure { continuation.finish(throwing: failure); return }
                guard let response = FakeData.routes else { continuation.finish(throwing: TransitError.decodingFailed); return }
                continuation.yield(.skeleton(response))
                do {
                    // Der Rechner spricht hier nie mit dem Backend: `calibrate` nutzt nur die Fake-Gehzeiten.
                    let calculator = HybridRouteCalculator(api: TransitAPIClient(secrets: InMemorySecretStore()),
                                                           directions: FakeWalking())
                    let calibrated = try await calculator.calibrate(response.journeys, pace: pace)
                    continuation.yield(.calibrated(response, calibrated))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Gehzeit = Luftlinie / 1.3 m/s.
struct FakeWalking: WalkingDirectionsProviding {
    func walkingETA(from: GeoCoordinate, to: GeoCoordinate) async throws -> WalkingETA {
        let d = from.distance(to: to)
        return WalkingETA(seconds: d / 1.3, distanceMeters: d)
    }
}

final class InMemorySecretStore: SecretStore {
    private let items: Mutex<[SecretKey: Data]>

    init(token: String? = nil) {
        items = Mutex(token.map { [.apiToken: Data($0.utf8)] } ?? [:])
    }

    func read(_ key: SecretKey) throws(TransitError) -> Data? { items.withLock { $0[key] } }
    func write(_ data: Data, for key: SecretKey) throws(TransitError) { items.withLock { $0[key] = data } }
    func delete(_ key: SecretKey) throws(TransitError) { _ = items.withLock { $0.removeValue(forKey: key) } }
}

enum FakeData {
    static let attributionJSON = #"""
    {"text":"Fahrplandaten: Transitous (u. a. DELFI). Karten- und Wegdaten: OpenStreetMap-Mitwirkende.",
     "links":[{"label":"Transitous-Datenquellen","url":"https://transitous.org/sources/"},
              {"label":"OpenStreetMap","url":"https://www.openstreetmap.org/copyright"}]}
    """#

    static let stops: [Place] = decode(#"""
    [{"kind":"stop","id":"de-DELFI_de:05315:11201","name":"Köln Hbf","latitude":50.943,"longitude":6.9589,"modes":["regional","suburban"],"area":"Köln"},
     {"kind":"stop","id":"de-DELFI_de:05111:18235","name":"Düsseldorf Hbf","latitude":51.21996,"longitude":6.79432,"modes":["tram"],"area":"Düsseldorf"}]
    """#) ?? []

    /// Eine Verbindung: Fussweg, Strassenbahn, Umstieg mit Treppe, Ersatzbus, Fussweg.
    static let routes: RoutesResponse? = decode(#"""
    {"journeys":[{"refreshToken":"ZmFrZQ==","departure":"2026-10-24T06:00:00Z","arrival":"2026-10-24T06:42:00Z",
      "durationSeconds":2520,"transfers":1,"modes":["tram","bus"],"cancelled":false,"realtime":true,"hasPolylines":false,
      "legs":[
       {"index":0,"mode":"walk","origin":{"kind":"coordinate","latitude":51.2201,"longitude":6.7905},
        "destination":{"kind":"stop","id":"a","name":"Düsseldorf Hbf","latitude":51.21996,"longitude":6.79432},
        "departure":"2026-10-24T06:00:00Z","arrival":"2026-10-24T06:05:00Z","durationSeconds":300,"realtime":false,"cancelled":false,
        "isTransfer":false,"distanceMeters":280,"durationSource":"motis-osm",
        "steps":[{"direction":"depart","distanceMeters":200,"streetName":"Konrad-Adenauer-Platz"},{"direction":"elevator","fromLevel":0,"toLevel":-1}]},
       {"index":1,"mode":"tram","origin":{"kind":"stop","id":"a","name":"Düsseldorf Hbf","latitude":51.21996,"longitude":6.79432},
        "destination":{"kind":"stop","id":"b","name":"Bilk S","latitude":51.2045,"longitude":6.7755},
        "departure":"2026-10-24T06:08:00Z","plannedDeparture":"2026-10-24T06:06:00Z","departureDelaySeconds":120,
        "arrival":"2026-10-24T06:18:00Z","durationSeconds":600,"realtime":true,"cancelled":false,
        "line":{"name":"STR 704","productName":"STR","color":"#E2001A","textColor":"#FFFFFF"},"direction":"Derendorf",
        "departurePlatform":"2","plannedDeparturePlatform":"1","platformChanged":true,"replacement":false,
        "remarks":[{"type":"warning","summary":"Umleitung","text":"Umleitung wegen Bauarbeiten","cause":"CONSTRUCTION","effect":"DETOUR"}]},
       {"index":2,"mode":"walk","origin":{"kind":"stop","id":"b","name":"Bilk S","latitude":51.2045,"longitude":6.7755},
        "destination":{"kind":"stop","id":"c","name":"Bilk S Bus","latitude":51.2049,"longitude":6.7761},
        "departure":"2026-10-24T06:18:00Z","arrival":"2026-10-24T06:21:00Z","durationSeconds":180,"realtime":false,"cancelled":false,
        "isTransfer":true,"distanceMeters":90,"durationSource":"motis-osm",
        "steps":[{"direction":"stairs","distanceMeters":20,"fromLevel":1,"toLevel":0}]},
       {"index":3,"mode":"bus","origin":{"kind":"stop","id":"c","name":"Bilk S Bus","latitude":51.2049,"longitude":6.7761},
        "destination":{"kind":"stop","id":"de-DELFI_de:05315:11201","name":"Köln Hbf","latitude":50.943,"longitude":6.9589},
        "departure":"2026-10-24T06:23:00Z","arrival":"2026-10-24T06:38:00Z","durationSeconds":900,"realtime":false,"cancelled":false,
        "line":{"name":"SEV RE 5","productName":"Bus"},"direction":"Köln Hbf","replacement":true},
       {"index":4,"mode":"walk","origin":{"kind":"stop","id":"de-DELFI_de:05315:11201","name":"Köln Hbf","latitude":50.943,"longitude":6.9589},
        "destination":{"kind":"coordinate","latitude":50.9413,"longitude":6.9583},
        "departure":"2026-10-24T06:38:00Z","arrival":"2026-10-24T06:42:00Z","durationSeconds":240,"realtime":false,"cancelled":false,
        "isTransfer":false,"distanceMeters":200,"durationSource":"motis-osm"}],
      "remarks":[]}],
     "earlierRef":null,"laterRef":"later","walkOnly":false,"removedLongDistance":1,
     "fetchedAt":"2026-10-24T06:01:02Z","attribution":\#(attributionJSON)}
    """#)

    private static func decode<T: Decodable>(_ json: String) -> T? {
        try? TransitJSON.decoder().decode(T.self, from: Data(json.utf8))
    }
}
#endif
