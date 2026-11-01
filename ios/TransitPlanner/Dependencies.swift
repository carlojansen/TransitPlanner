import BackgroundTasks
import CoreLocation
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

/// Ergebnis des ersten Starts (A1). nil = noch nicht durchlaufen. Sagt nur "schon gefragt",
/// ob der Standort erlaubt ist, kommt immer aus iOS (`LocationAuthorization`).
enum OnboardingChoice: String, Sendable {
    case withLocation, withoutLocation
}

/// Echter Berechtigungsstatus aus iOS.
enum LocationAuthorization: Sendable, Hashable {
    case notDetermined, allowed, denied
}

/// Alles, was `AppFlow` von aussen braucht. Produktiv nur gepinnte Dienste; Fakes nur in Debug-Builds.
struct AppDependencies: Sendable {
    var search: any StopSearching
    var planner: any RoutePlanning
    var secrets: any SecretStore
    /// Nur CoreLocation (VPN-sicher). Der Fix bleibt im Speicher, nie auf der Platte.
    var location: any LocationProviding
    /// Aktueller iOS-Status (CLLocationManager.authorizationStatus); bei scenePhase .active neu gelesen.
    var authorization: @MainActor @Sendable () -> LocationAuthorization
    /// Gemerkter Einstieg (UserDefaults, Required-Reason CA92.1 in PrivacyInfo).
    var loadOnboarding: @Sendable () -> OnboardingChoice?
    var saveOnboarding: @Sendable (OnboardingChoice) -> Void
    /// Gelernter Gehzeit-Faktor (UserDefaults, JSON); nur der Faktor, keine Wege oder Orte.
    var loadPace: @Sendable () -> WalkingPaceFactor
    var savePace: @Sendable (WalkingPaceFactor) -> Void
    /// Live-Standort fuer die Navigation (nur Vordergrund, when-in-use); Fixes bleiben im RAM.
    var positions: @Sendable () -> AsyncStream<LocationFix>
    /// POST /api/refresh ohne Polylines (Polling braucht keine Geometrie, API.md).
    var refresh: @Sendable (String) async throws(TransitError) -> Journey
    /// Sperre nach Retry-After (429/502/503/504), aus `TransitAPIClient.blocked`.
    var blockedUntil: @Sendable () async -> Date?
    /// Haltestellen im Umkreis (Planen-Ansicht, leeres Feld); das Backend bekommt nur die gerundete Koordinate.
    var nearby: @Sendable (GeoCoordinate) async throws(TransitError) -> LocationsResponse
    /// Favoriten und Verlauf (lokal, verschluesselt).
    var places: any PlaceStoring
    /// Erinnerungen (lokal, verschluesselt) und ihre lokalen Mitteilungen.
    var reminders: any ReminderStoring
    var notifier: any ReminderNotifying
    /// Naechsten Hintergrund-Lauf anmelden (BGAppRefreshTask); nil = keiner noetig.
    var scheduleBackgroundCheck: @Sendable (Date?) -> Void
    var now: @Sendable () -> Date = { Date() }
    /// Entprellung der Suche (API.md: mindestens 300 ms).
    var debounce: Duration = .milliseconds(300)
    /// Ab hier zeigt 3a "Warte auf Verbindung" (waitsForConnectivity kann bis 45 s dauern).
    var waitingHint: Duration = .seconds(3)
    /// Zeitgesteuerte Neubewertung der Navigation (Zustaende haengen auch an Abfahrtszeiten).
    var navigationTick: Duration = .seconds(5)
    /// So lange bietet D2 "Rückgängig" an.
    var undoWindow: Duration = .seconds(5)

    static let onboardingKey = "onboarding"
    static let paceKey = "walkingPace"

    /// CLLocationUpdate.liveUpdates mit CLServiceSession (when-in-use). Kein Hintergrund-Modus: endet mit der App im Hintergrund.
    static func livePositions() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            let task = Task {
                let session = CLServiceSession(authorization: .whenInUse)
                defer { session.invalidate() }
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                        guard !Task.isCancelled else { break }
                        // Ungueltig, zu ungenau oder zwischengespeichert alt (> 30 s): verwerfen.
                    guard let l = update.location, l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 100,
                          l.timestamp.timeIntervalSinceNow > -NavigationEngine.freshFix else { continue }
                        continuation.yield(LocationFix(coordinate: GeoCoordinate(latitude: l.coordinate.latitude,
                                                                                 longitude: l.coordinate.longitude),
                                                       horizontalAccuracy: l.horizontalAccuracy, timestamp: l.timestamp))
                    }
                } catch {
                    // Abbruch oder Fehler: Stream endet, die Navigation laeuft nach Zeit weiter.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor static func live() -> AppDependencies {
        let api = TransitAPIClient()
        let location = CoreLocationService()
        let secrets = KeychainSecretStore()
        // Ein Container fuer alles; faellt der Store aus, bleiben Orte fuer diese Sitzung im Speicher. Erinnerungen nicht:
        // eine Mitteilung ohne gespeicherte Fahrt liefe ins Leere, also sperrt `ReminderCenter.set` das Scharfschalten.
        let stored = try? TransitStore.makeContainer()
        let container = stored ?? (try? TransitStore.makeContainer(inMemory: true))
        let sealer = LocalSealer(secrets: secrets)
        return AppDependencies(
            search: SearchService(location: location, api: api),
            planner: HybridRouteCalculator(api: api),
            secrets: secrets,
            location: location,
            authorization: {
                switch CLLocationManager().authorizationStatus {
                case .notDetermined: .notDetermined
                case .authorizedWhenInUse, .authorizedAlways: .allowed
                default: .denied
                }
            },
            loadOnboarding: { UserDefaults.standard.string(forKey: onboardingKey).flatMap(OnboardingChoice.init(rawValue:)) },
            saveOnboarding: { UserDefaults.standard.set($0.rawValue, forKey: onboardingKey) },
            loadPace: { UserDefaults.standard.data(forKey: paceKey).flatMap { try? JSONDecoder().decode(WalkingPaceFactor.self, from: $0) } ?? WalkingPaceFactor() },
            savePace: { if let data = try? JSONEncoder().encode($0) { UserDefaults.standard.set(data, forKey: paceKey) } },
            positions: { livePositions() },
            refresh: { token throws(TransitError) in try await api.refresh(refreshToken: token, polylines: false, accessibility: .stored).journey },
            blockedUntil: { await api.blocked?.until },
            nearby: { coordinate throws(TransitError) in try await api.nearbyStops(around: coordinate) },
            places: container.map { SwiftDataPlaces(container: $0, sealer: sealer) } ?? MemoryPlaces(),
            reminders: stored.map { SwiftDataReminders(container: $0, sealer: sealer) } ?? MemoryReminders(isDurable: false),
            notifier: SystemNotifier(),
            scheduleBackgroundCheck: { date in
                guard let date else {
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: ReminderCenter.backgroundTaskID)
                    return
                }
                let request = BGAppRefreshTaskRequest(identifier: ReminderCenter.backgroundTaskID)
                request.earliestBeginDate = date
                // Schlaegt fehl im Simulator oder ohne Hintergrundaktualisierung; dann prueft die App beim Aktivwerden.
                try? BGTaskScheduler.shared.submit(request)
            }
        )
    }

    /// Launch-Argument `-uiTestFakes` schaltet in Debug-Builds auf Fakes um; Release spricht nie ohne Pinning.
    @MainActor static func forLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppDependencies {
        #if DEBUG
        if arguments.contains("-uiTestFakes") { return .uiTest(arguments: arguments) }
        #endif
        return .live()
    }
}

#if DEBUG
import Synchronization

extension AppDependencies {
    /// UI-Tests und Screenshot-Tour: `-fakeOnboarded` ueberspringt A1/A2, `-fakeScenario <name>` waehlt den Zustand.
    static func uiTest(arguments: [String]) -> AppDependencies {
        let onboarded = arguments.contains("-fakeOnboarded")
        let scenario = arguments.firstIndex(of: "-fakeScenario").flatMap { i in
            arguments.indices.contains(i + 1) ? arguments[i + 1] : nil
        }
        let planner: FakeRoutePlanner = switch scenario {
        case "slow": FakeRoutePlanner(delay: .seconds(60))
        case "noConnections": FakeRoutePlanner(failure: .noConnections)
        case "serverDown": FakeRoutePlanner(failure: .upstreamUnavailable)
        case "offlineAfterFirst": FakeRoutePlanner(failAfterFirst: .offline)
        case "plainFirst": FakeRoutePlanner(reversed: true)
        case "deutz": FakeRoutePlanner(response: FakeData.deutz())
        default: FakeRoutePlanner()
        }
        var deps = AppDependencies.fakes(planner: planner,
                                         secrets: InMemorySecretStore(token: onboarded ? String(repeating: "k", count: 40) : nil),
                                         onboarding: onboarded ? .withLocation : nil)
        // Navigation (Screenshot-Tour): feste Uhrzeit und fester Standort, z. B. `-fakeNow 2026-10-24T06:05:00Z -fakePosition 51.21996,6.79432`.
        if let raw = value(after: "-fakeNow", in: arguments), let base = try? Date.ISO8601FormatStyle().parse(raw) {
            let offset = base.timeIntervalSince(Date())
            deps.now = { Date().addingTimeInterval(offset) }
        }
        if let raw = value(after: "-fakePosition", in: arguments) {
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                let fix = LocationFix(coordinate: GeoCoordinate(latitude: parts[0], longitude: parts[1]),
                                      horizontalAccuracy: 5, timestamp: Date())
                deps.positions = { AsyncStream { $0.yield(fix) } }
            }
        }
        return deps
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    static func fakes(search: FakeStopSearch = FakeStopSearch(), planner: FakeRoutePlanner = FakeRoutePlanner(),
                      secrets: InMemorySecretStore = InMemorySecretStore(),
                      location: FakeLocation = FakeLocation(),
                      onboarding: OnboardingChoice? = nil,
                      pace: WalkingPaceFactor = WalkingPaceFactor(),
                      blockedUntil: Date? = nil,
                      places: MemoryPlaces = MemoryPlaces(),
                      debounce: Duration = .milliseconds(300),
                      waitingHint: Duration = .seconds(3),
                      refresher: FakeRefresher = FakeRefresher(),
                      reminders: MemoryReminders = MemoryReminders(),
                      notifier: FakeNotifier = FakeNotifier()) -> AppDependencies {
        let stored = Mutex(onboarding)
        let storedPace = Mutex(pace)
        return AppDependencies(search: search, planner: planner, secrets: secrets, location: location,
                               authorization: { location.status },
                               loadOnboarding: { stored.withLock { $0 } },
                               saveOnboarding: { value in stored.withLock { $0 = value } },
                               loadPace: { storedPace.withLock { $0 } },
                               savePace: { value in storedPace.withLock { $0 = value } },
                               positions: { AsyncStream { _ in } },
                               refresh: { token throws(TransitError) in try await refresher.refresh(token) },
                               blockedUntil: { blockedUntil },
                               nearby: { _ throws(TransitError) in
                                   guard let nearby = FakeData.nearby else { throw .decodingFailed }
                                   return nearby
                               },
                               places: places, reminders: reminders, notifier: notifier,
                               scheduleBackgroundCheck: { _ in },
                               debounce: debounce, waitingHint: waitingHint)
    }
}

/// Fake-Mitteilungen: merkt sich, was iOS gerade einplanen wuerde.
final class FakeNotifier: ReminderNotifying {
    let pending = Mutex<[String: ReminderAlert]>([:])
    let granted: Bool

    init(granted: Bool = true) { self.granted = granted }

    var alerts: [ReminderAlert] { pending.withLock { $0.values.sorted { $0.fireAt < $1.fireAt } } }

    func requestAuthorization() async -> Bool { granted }
    func add(_ alerts: [ReminderAlert]) async throws(TransitError) {
        pending.withLock { for alert in alerts { $0[alert.identifier] = alert } }
    }
    func remove(_ identifiers: [String]) { pending.withLock { for id in identifiers { $0[id] = nil } } }
}

/// Fake-Refresh: liefert die Verbindung mit gleichem Token aus den Fake-Daten oder einen vorgegebenen Stand/Fehler.
final class FakeRefresher: Sendable {
    let next = Mutex<Result<Journey, TransitError>?>(nil)
    let calls = Mutex(0)

    func set(_ result: Result<Journey, TransitError>?) { next.withLock { $0 = result } }
    var callCount: Int { calls.withLock { $0 } }

    func refresh(_ token: String) async throws(TransitError) -> Journey {
        calls.withLock { $0 += 1 }
        if let result = next.withLock({ $0 }) { return try result.get() }
        let all = (FakeData.routes?.journeys ?? []) + (FakeData.deutz()?.journeys ?? [])
        guard let journey = all.first(where: { $0.refreshToken == token }) else { throw .refreshExpired }
        return journey
    }
}

/// Fester Standort in Duesseldorf, ohne CoreLocation. Die erste Abfrage "erlaubt" (wie der System-Dialog).
final class FakeLocation: LocationProviding {
    let failure: TransitError?
    private let state: Mutex<LocationAuthorization>

    init(failure: TransitError? = nil, status: LocationAuthorization = .allowed) {
        self.failure = failure
        state = Mutex(status)
    }

    static let fix = LocationFix(coordinate: GeoCoordinate(latitude: 51.2201, longitude: 6.7905),
                                 horizontalAccuracy: 8, timestamp: Date())

    var status: LocationAuthorization { state.withLock { $0 } }
    func set(_ status: LocationAuthorization) { state.withLock { $0 = status } }

    func currentFix() async throws(TransitError) -> LocationFix {
        if let failure {
            if failure == .locationDenied { state.withLock { $0 = .denied } }
            throw failure
        }
        state.withLock { if $0 == .notDetermined { $0 = .allowed } }
        guard status == .allowed else { throw .locationDenied }
        return Self.fix
    }
}

/// Fake-Suche ohne Netz und ohne Standort. Protokolliert Text und Modus fuer Tests.
final class FakeStopSearch: StopSearching {
    struct Call: Sendable, Hashable {
        let text: String
        let scope: SearchScope
    }

    let calls = Mutex<[Call]>([])
    let failure: TransitError?
    let delay: Duration

    init(failure: TransitError? = nil, delay: Duration = .zero) {
        self.failure = failure
        self.delay = delay
    }

    var recorded: [Call] { calls.withLock { $0 } }
    var recordedTexts: [String] { recorded.map(\.text) }

    func search(_ text: String, scope: SearchScope) async throws(TransitError) -> SearchResults {
        calls.withLock { $0.append(Call(text: text, scope: scope)) }
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
    /// Was ans Backend ginge (Zero-Knowledge-Pruefung in Tests).
    let requests = Mutex<[RoutesRequest]>([])
    let failure: Mutex<TransitError?>
    let delay: Duration
    /// Erste Anfrage gelingt, danach dieser Fehler (H3 Offline mit abgeblendeter letzter Antwort).
    let failAfterFirst: TransitError?
    /// Verbindungen in umgekehrter Reihenfolge (Routenauswahl ohne Ersatzverkehr oben).
    let reversed: Bool
    /// Andere Antwort statt `FakeData.routes` (z. B. `FakeData.deutz()`).
    let response: RoutesResponse?

    init(failure: TransitError? = nil, delay: Duration = .zero, failAfterFirst: TransitError? = nil, reversed: Bool = false,
         response: RoutesResponse? = nil) {
        self.response = response
        self.failure = Mutex(failure)
        self.delay = delay
        self.failAfterFirst = failAfterFirst
        self.reversed = reversed
    }

    var callCount: Int { requests.withLock { $0.count } }
    var recordedRequests: [RoutesRequest] { requests.withLock { $0 } }
    func setFailure(_ error: TransitError?) { failure.withLock { $0 = error } }

    func plan(_ trip: some TripRequest, pace: WalkingPaceFactor) -> AsyncThrowingStream<HybridRouteCalculator.Stage, any Error> {
        let count = requests.withLock { $0.append(trip.routesRequest()); return $0.count }
        let failure = self.failure.withLock { $0 } ?? (count > 1 ? failAfterFirst : nil)
        let delay = self.delay
        let reversed = self.reversed
        let override = self.response
        return AsyncThrowingStream { continuation in
            let task = Task {
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch { continuation.finish(throwing: TransitError.cancelled); return }
                }
                if let failure { continuation.finish(throwing: failure); return }
                guard let base = override ?? FakeData.routes else { continuation.finish(throwing: TransitError.decodingFailed); return }
                let response = reversed ? FakeData.reversed(base) : base
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

    private static let stopsJSON = #"""
    [{"kind":"stop","id":"de-DELFI_de:05315:11201","name":"Köln Hbf","latitude":50.943,"longitude":6.9589,"modes":["regional","suburban"],"area":"Köln","distanceMeters":180},
     {"kind":"stop","id":"de-DELFI_de:05111:18235","name":"Düsseldorf Hbf","latitude":51.21996,"longitude":6.79432,"modes":["tram"],"area":"Düsseldorf","distanceMeters":640}]
    """#

    static let stops: [Place] = decode(stopsJSON) ?? []

    /// Antwort der Umkreissuche (Planen-Ansicht, leeres Feld).
    static let nearby: LocationsResponse? = decode(#"{"places":\#(stopsJSON),"attribution":\#(attributionJSON)}"#)

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
      "remarks":[]},
     {"refreshToken":"ZmFrZTI=","departure":"2026-10-24T06:10:00Z","arrival":"2026-10-24T06:58:00Z",
      "durationSeconds":2880,"transfers":0,"modes":["regional"],"cancelled":false,"realtime":true,"hasPolylines":false,
      "legs":[
       {"index":0,"mode":"walk","origin":{"kind":"coordinate","latitude":51.2201,"longitude":6.7905},
        "destination":{"kind":"stop","id":"a","name":"Düsseldorf Hbf","latitude":51.21996,"longitude":6.79432},
        "departure":"2026-10-24T06:10:00Z","arrival":"2026-10-24T06:15:00Z","durationSeconds":300,"realtime":false,"cancelled":false,
        "isTransfer":false,"distanceMeters":280,"durationSource":"motis-osm"},
       {"index":1,"mode":"regional","origin":{"kind":"stop","id":"a","name":"Düsseldorf Hbf","latitude":51.21996,"longitude":6.79432},
        "destination":{"kind":"stop","id":"de-DELFI_de:05315:11201","name":"Köln Hbf","latitude":50.943,"longitude":6.9589},
        "departure":"2026-10-24T06:20:00Z","plannedDeparture":"2026-10-24T06:20:00Z","departureDelaySeconds":0,
        "arrival":"2026-10-24T06:54:00Z","durationSeconds":2040,"realtime":true,"cancelled":false,
        "line":{"name":"RE 1","productName":"RE"},"direction":"Aachen Hbf","departurePlatform":"9","plannedDeparturePlatform":"9",
        "platformChanged":false,"replacement":false,
        "stopovers":[{"stop":{"kind":"stop","id":"x1","name":"Düsseldorf-Benrath","latitude":51.163,"longitude":6.873},
                      "arrival":"2026-10-24T06:30:00Z","departure":"2026-10-24T06:31:00Z","cancelled":false},
                     {"stop":{"kind":"stop","id":"x2","name":"Leverkusen Mitte","latitude":51.031,"longitude":6.988},
                      "arrival":"2026-10-24T06:42:00Z","departure":"2026-10-24T06:43:00Z","cancelled":false}]},
       {"index":2,"mode":"walk","origin":{"kind":"stop","id":"de-DELFI_de:05315:11201","name":"Köln Hbf","latitude":50.943,"longitude":6.9589},
        "destination":{"kind":"coordinate","latitude":50.9413,"longitude":6.9583},
        "departure":"2026-10-24T06:54:00Z","arrival":"2026-10-24T06:58:00Z","durationSeconds":240,"realtime":false,"cancelled":false,
        "isTransfer":false,"distanceMeters":200,"durationSource":"motis-osm"}],
      "remarks":[]}],
     "earlierRef":null,"laterRef":"later","walkOnly":false,"removedLongDistance":1,
     "fetchedAt":"2026-10-24T06:01:02Z","attribution":\#(attributionJSON)}
    """#)

    /// Echte Fahrt (Mo 26.10.2026, Zeiten in UTC = MEZ - 1 h): Düsseldorf Hbf 08:02 ICE 47 Gleis 9 > Köln Messe/Deutz
    /// 08:32 Gleis 93, 2 Min. zu Fuß zu Gleis 92 > RB 25 08:34 > Köln Hansaring 08:38, 3 Min. zu Fuß > STR 12 08:41 >
    /// Zülpicher Platz 08:47, 3 Min. zu Fuß > STR 9 08:50 > Köln Sülz Weyertal 08:55, 8 Min. zu Fuß zu Weyertal 119a.
    /// Puffer: Deutz 20 s (engster), Hansaring 30 s, Zülpicher Platz 40 s. `iceDelay` (s) verspätet die Ankunft in Deutz.
    static func deutz(iceDelay: Int = 0) -> RoutesResponse? {
        let arrival = Date.ISO8601FormatStyle().format(
            (try? Date.ISO8601FormatStyle().parse("2026-10-26T07:32:00Z"))?.addingTimeInterval(TimeInterval(iceDelay)) ?? .distantPast)
        let json = #"""
        {"journeys":[{"refreshToken":"ZGV1dHo=","departure":"2026-10-26T07:02:00Z","arrival":"2026-10-26T08:03:00Z",
          "durationSeconds":3660,"transfers":3,"modes":["nationalExpress","regional","tram"],"cancelled":false,"realtime":true,
          "hasPolylines":false,"legs":[
          {"index":0,"mode":"nationalExpress","origin":{"kind":"stop","id":"dus","name":"Düsseldorf Hbf","latitude":51.2198,"longitude":6.7944},
           "destination":{"kind":"stop","id":"deutz93","name":"Köln Messe/Deutz","latitude":50.9409,"longitude":6.9750},
           "departure":"2026-10-26T07:02:00Z","plannedDeparture":"2026-10-26T07:02:00Z","departureDelaySeconds":0,
           "arrival":"ICE_ARRIVAL","plannedArrival":"2026-10-26T07:32:00Z","arrivalDelaySeconds":ICE_DELAY,
           "realtime":true,"cancelled":false,"line":{"name":"ICE 47"},"direction":"Köln Hbf",
           "departurePlatform":"9","plannedDeparturePlatform":"9","arrivalPlatform":"93","plannedArrivalPlatform":"93",
           "platformChanged":false,"replacement":false},
          {"index":1,"mode":"walk","origin":{"kind":"stop","id":"deutz93","name":"Köln Messe/Deutz","latitude":50.9409,"longitude":6.9750},
           "destination":{"kind":"stop","id":"deutz92","name":"Köln Messe/Deutz","latitude":50.9406,"longitude":6.9745},
           "departure":"2026-10-26T07:32:00Z","arrival":"2026-10-26T07:34:00Z","durationSeconds":100,"realtime":false,
           "cancelled":false,"isTransfer":true,"distanceMeters":120,"durationSource":"motis-osm"},
          {"index":2,"mode":"regional","origin":{"kind":"stop","id":"deutz92","name":"Köln Messe/Deutz","latitude":50.9406,"longitude":6.9745},
           "destination":{"kind":"stop","id":"hansaring","name":"Köln Hansaring","latitude":50.9483,"longitude":6.9431},
           "departure":"2026-10-26T07:34:00Z","plannedDeparture":"2026-10-26T07:34:00Z","departureDelaySeconds":0,
           "arrival":"2026-10-26T07:38:00Z","realtime":true,"cancelled":false,"line":{"name":"RB 25"},"direction":"Köln Hansaring",
           "departurePlatform":"92","plannedDeparturePlatform":"92","arrivalPlatform":"2","plannedArrivalPlatform":"2",
           "platformChanged":false,"replacement":false},
          {"index":3,"mode":"walk","origin":{"kind":"stop","id":"hansaring","name":"Köln Hansaring","latitude":50.9483,"longitude":6.9431},
           "destination":{"kind":"stop","id":"hansaringTram","name":"Hansaring","latitude":50.9479,"longitude":6.9438},
           "departure":"2026-10-26T07:38:00Z","arrival":"2026-10-26T07:41:00Z","durationSeconds":150,"realtime":false,
           "cancelled":false,"isTransfer":true,"distanceMeters":180,"durationSource":"motis-osm"},
          {"index":4,"mode":"tram","origin":{"kind":"stop","id":"hansaringTram","name":"Hansaring","latitude":50.9479,"longitude":6.9438},
           "destination":{"kind":"stop","id":"zuelpicher12","name":"Zülpicher Platz","latitude":50.9310,"longitude":6.9394},
           "departure":"2026-10-26T07:41:00Z","plannedDeparture":"2026-10-26T07:41:00Z","departureDelaySeconds":0,
           "arrival":"2026-10-26T07:47:00Z","realtime":true,"cancelled":false,"line":{"name":"12"},"direction":"Zollstock",
           "replacement":false},
          {"index":5,"mode":"walk","origin":{"kind":"stop","id":"zuelpicher12","name":"Zülpicher Platz","latitude":50.9310,"longitude":6.9394},
           "destination":{"kind":"stop","id":"zuelpicher9","name":"Zülpicher Platz","latitude":50.9306,"longitude":6.9387},
           "departure":"2026-10-26T07:47:00Z","arrival":"2026-10-26T07:50:00Z","durationSeconds":140,"realtime":false,
           "cancelled":false,"isTransfer":true,"distanceMeters":150,"durationSource":"motis-osm"},
          {"index":6,"mode":"tram","origin":{"kind":"stop","id":"zuelpicher9","name":"Zülpicher Platz","latitude":50.9306,"longitude":6.9387},
           "destination":{"kind":"stop","id":"weyertal","name":"Köln Sülz Weyertal","latitude":50.9258,"longitude":6.9218},
           "departure":"2026-10-26T07:50:00Z","plannedDeparture":"2026-10-26T07:50:00Z","departureDelaySeconds":0,
           "arrival":"2026-10-26T07:55:00Z","realtime":true,"cancelled":false,"line":{"name":"9"},"direction":"Sülz",
           "replacement":false},
          {"index":7,"mode":"walk","origin":{"kind":"stop","id":"weyertal","name":"Köln Sülz Weyertal","latitude":50.9258,"longitude":6.9218},
           "destination":{"kind":"coordinate","latitude":50.9233,"longitude":6.9200},
           "departure":"2026-10-26T07:55:00Z","arrival":"2026-10-26T08:03:00Z","durationSeconds":480,"realtime":false,
           "cancelled":false,"isTransfer":false,"distanceMeters":550,"durationSource":"motis-osm"}],
          "remarks":[]}],
         "earlierRef":null,"laterRef":null,"walkOnly":false,"removedLongDistance":0,
         "fetchedAt":"2026-10-26T06:50:00Z","attribution":\#(attributionJSON)}
        """#
        return decode(json.replacingOccurrences(of: "ICE_ARRIVAL", with: arrival)
            .replacingOccurrences(of: "ICE_DELAY", with: String(iceDelay)))
    }

    /// Gleiche Antwort mit umgekehrter Reihenfolge der Verbindungen (ueber JSON, Modelle haben keinen oeffentlichen Init).
    static func reversed(_ response: RoutesResponse) -> RoutesResponse {
        guard let data = try? JSONEncoder().encode(response),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let journeys = object["journeys"] as? [Any]
        else { return response }
        object["journeys"] = Array(journeys.reversed())
        guard let reencoded = try? JSONSerialization.data(withJSONObject: object),
              let result = try? JSONDecoder().decode(RoutesResponse.self, from: reencoded)
        else { return response }
        return result
    }

    private static func decode<T: Decodable>(_ json: String) -> T? {
        try? TransitJSON.decoder().decode(T.self, from: Data(json.utf8))
    }
}
#endif

extension Accessibility {
    static let key = "accessibility"
    /// Gespeicherte Einstellung (UserDefaults); ohne Eintrag aus.
    static var stored: Accessibility { UserDefaults.standard.string(forKey: key).flatMap(Accessibility.init(rawValue:)) ?? .none }
}
