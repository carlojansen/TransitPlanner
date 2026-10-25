import Foundation
import Observation
import TransitCore

/// Welcher Endpunkt gerade gesucht wird.
enum EndpointSlot: Sendable, Hashable {
    case origin, destination
}

/// Phasen der Oberflaeche (RESEARCH-M3 Abschnitt 6). Fahrtdetails sind ein Zustand im Sheet, kein Push.
enum Phase: Sendable, Hashable {
    case start
    case search(EndpointSlot)
    case routeSelection
    /// Index der Verbindung in der aktuellen Antwort.
    case tripDetails(Int)
    /// Platzhalter; Unterzustaende (SPEZIFIKATION 4.2) folgen in einer spaeteren Etappe.
    case navigation(Int)
    case arrival

    /// Laufende Arbeit gehoert zu einem Kontext. Verlaesst die Phase ihn, wird die Arbeit abgebrochen.
    /// Routenauswahl und Fahrtdetails teilen sich die Planung (Kalibrierung laeuft weiter, wenn man eine Fahrt oeffnet).
    enum WorkContext: Hashable { case none, search, route }

    var workContext: WorkContext {
        switch self {
        case .search: .search
        case .routeSelection, .tripDetails: .route
        case .start, .navigation, .arrival: .none
        }
    }
}

enum FlowEvent: Sendable, Hashable {
    case editEndpoint(EndpointSlot)
    case endpointChosen
    /// "Verbindungen suchen" (2c: neu gesucht wird nur auf Knopfdruck), auch als Erneut-Versuch in der Routenauswahl.
    case planTapped
    case journeySelected(Int)
    case startNavigation
    case arrived
    case back
    case reset
}

/// Aktionen, die ein Inline-Banner anbietet (RESEARCH-M3 Abschnitt 7). Keine Alerts.
enum BannerAction: Sendable, Hashable {
    case retry, enterKey, openSettings, switchToStops, newSearch
}

extension TransitError {
    /// `cancelled` zeigt nichts; `noConnections` erscheint als Leerzustand in der Liste statt als Banner.
    var showsBanner: Bool { self != .cancelled && self != .noConnections }

    var bannerActions: [BannerAction] {
        switch self {
        case .offline, .upstreamUnavailable, .upstreamTimeout: [.retry]
        case .missingToken, .unauthorized: [.enterKey]
        case .locationDenied: [.openSettings, .switchToStops]
        case .locationUnavailable: [.retry, .switchToStops]
        case .refreshExpired, .notFound: [.newSearch]
        // rateLimited: Restzeit statt Knopf (kein Neuversuch-Haemmern); pinningFailed: keine Umgehung anbieten.
        case .rateLimited, .pinningFailed, .noConnections, .cancelled,
             .invalidRequest, .internal, .decodingFailed, .keychainFailure: []
        }
    }
}

@Observable @MainActor
final class AppFlow {
    private(set) var phase: Phase = .start

    // Suche
    /// Pflichtschalter, Standard "Adresse" (nichts geht an das eigene Backend). Aendern nur ueber `setScope`.
    private(set) var scope: SearchScope = .address
    var query = ""
    private(set) var results = SearchResults()
    private(set) var isSearching = false

    // Fahrt
    private(set) var origin: TripEndpoint?
    private(set) var destination: TripEndpoint?
    /// nil = jetzt (beim Tippen auf "Verbindungen suchen" bestimmt).
    var customTime: Date?
    var isArrivalTime = false
    private(set) var routes: RoutesResponse?
    /// nil, solange nur das Skelett vorliegt.
    private(set) var calibrated: [CalibratedJourney]?
    private(set) var isPlanning = false

    // Status
    private(set) var banner: TransitError?
    private(set) var blockedUntil: Date?
    private(set) var attribution: Attribution?
    private(set) var hasServerKey: Bool
    var showsSettings = false

    nonisolated static let maxQueryLength = 80

    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var unblock: Task<Void, Never>?
    // ponytail: fester Standardwert; SwiftData-PaceProfile anbinden, sobald die Gehzeit-Messung (Navigation) existiert.
    @ObservationIgnored private let pace = WalkingPaceFactor()

    init(_ deps: AppDependencies) {
        self.deps = deps
        do {
            hasServerKey = try deps.secrets.read(.apiToken) != nil
        } catch {
            hasServerKey = false
            banner = error
        }
    }

    var canPlan: Bool { origin != nil && destination != nil && blockedUntil == nil }

    func endpoint(_ slot: EndpointSlot) -> TripEndpoint? {
        slot == .origin ? origin : destination
    }

    // MARK: Uebergaenge

    /// Reine Uebergangsfunktion ohne Seiteneffekte. nil = ungueltiger Uebergang, wird ignoriert.
    nonisolated static func next(_ phase: Phase, _ event: FlowEvent) -> Phase? {
        switch (phase, event) {
        case (.start, .reset): nil
        case (_, .reset): .start
        case (.start, .editEndpoint(let slot)), (.routeSelection, .editEndpoint(let slot)): .search(slot)
        case (.start, .planTapped), (.routeSelection, .planTapped): .routeSelection
        case (.search, .endpointChosen), (.search, .back): .start
        case (.routeSelection, .journeySelected(let i)): .tripDetails(i)
        case (.routeSelection, .back): .start
        case (.tripDetails(let i), .startNavigation): .navigation(i)
        case (.tripDetails, .back): .routeSelection
        case (.navigation, .arrived): .arrival
        case (.navigation(let i), .back): .tripDetails(i)
        case (.arrival, .back): .start
        default: nil
        }
    }

    /// Animation setzt die View (sie kennt Reduce Motion); das Modell bleibt SwiftUI-frei.
    func send(_ event: FlowEvent) {
        guard let new = Self.next(phase, event) else { return }
        // Bei Sperre (Retry-After) oder fehlendem Start/Ziel nicht still in eine leere Liste wechseln.
        if event == .planTapped, !canPlan { return }
        if new.workContext != phase.workContext { cancelWork() }
        if case .search = new, phase != new { query = ""; results = SearchResults() }
        phase = new
        if event == .planTapped { startPlanning() }
    }

    private func cancelWork() {
        work?.cancel()
        work = nil
        isSearching = false
        isPlanning = false
        if banner != .rateLimited { banner = nil }
    }

    // MARK: Suche

    /// Bei jeder Eingabe: entprellt.
    func queryChanged() { scheduleSearch(immediately: false) }

    /// Moduswechsel. Zero-Knowledge: Text aus dem Adressmodus (auch AutoFill-Adressen) darf nie als
    /// Haltestellen-Suchtext ans Backend gehen. Beim Wechsel auf "Haltestelle" wird das Feld geleert, der Nutzer tippt neu.
    func setScope(_ new: SearchScope) {
        guard new != scope else { return }
        scope = new
        work?.cancel()
        results = SearchResults()
        isSearching = false
        switch new {
        case .stops: query = ""
        case .address: queryChanged() // bleibt lokal (MKLocalSearch)
        }
    }

    /// Return: sofort.
    func submitSearch() { scheduleSearch(immediately: true) }

    private func scheduleSearch(immediately: Bool) {
        guard case .search = phase else { return }
        work?.cancel()
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxQueryLength))
        let scope = self.scope
        guard text.count >= 2 else {
            results = SearchResults()
            isSearching = false
            return
        }
        let delay = deps.debounce
        isSearching = true
        work = Task {
            if !immediately {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            await runSearch(text, scope: scope)
        }
    }

    private func runSearch(_ text: String, scope: SearchScope) async {
        isSearching = true
        do {
            let r = try await deps.search.search(text, scope: scope)
            guard !Task.isCancelled else { return }
            results = r
            if let a = r.attribution { attribution = a }
            banner = nil
        } catch {
            guard !Task.isCancelled else { return }
            results = SearchResults()
            await show(error)
            guard !Task.isCancelled else { return }
        }
        isSearching = false
    }

    func choose(_ endpoint: TripEndpoint) {
        guard case .search(let slot) = phase else { return }
        switch slot {
        case .origin: origin = endpoint
        case .destination: destination = endpoint
        }
        send(.endpointChosen)
    }

    func swapEndpoints() {
        (origin, destination) = (destination, origin)
    }

    // MARK: Planung

    private func startPlanning() {
        work?.cancel()
        guard let origin, let destination, blockedUntil == nil else { return }
        let trip = ManualTripRequest(origin: origin, destination: destination,
                                     targetTime: customTime ?? deps.now(), isArrivalTime: isArrivalTime)
        routes = nil
        calibrated = nil
        isPlanning = true
        banner = nil
        let stream = deps.planner.plan(trip, pace: pace)
        work = Task {
            do {
                for try await stage in stream {
                    guard !Task.isCancelled else { return }
                    switch stage {
                    case .skeleton(let r):
                        routes = r
                        attribution = r.attribution
                    case .calibrated(let r, let c):
                        routes = r
                        calibrated = c
                    }
                }
                guard !Task.isCancelled else { return }
                isPlanning = false
            } catch {
                guard !Task.isCancelled else { return }
                isPlanning = false
                await show((error as? TransitError) ?? (error is CancellationError ? .cancelled : .internal))
            }
        }
    }

    func calibratedJourney(at index: Int) -> CalibratedJourney? {
        calibrated.flatMap { index < $0.count ? $0[index] : nil }
    }

    func journey(at index: Int) -> Journey? {
        routes.flatMap { index < $0.journeys.count ? $0.journeys[index] : nil }
    }

    // MARK: Fehler

    private func show(_ error: TransitError) async {
        guard error != .cancelled else { return }
        let until = await deps.blockedUntil()
        // Eine inzwischen abgeloeste Suche/Planung setzt kein Banner mehr.
        guard !Task.isCancelled else { return }
        banner = error
        if let until, until > deps.now() { block(until: until) }
    }

    private func block(until: Date) {
        blockedUntil = until
        unblock?.cancel()
        let seconds = until.timeIntervalSince(deps.now())
        unblock = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            blockedUntil = nil
            if banner == .rateLimited { banner = nil }
        }
    }

    /// Aktionen fuer das Banner; "Erneut versuchen" erst nach Ablauf von Retry-After.
    func actions(for error: TransitError) -> [BannerAction] {
        error.bannerActions.filter { $0 != .retry || blockedUntil == nil }
    }

    func perform(_ action: BannerAction) {
        switch action {
        case .retry:
            guard blockedUntil == nil else { return }
            switch phase {
            case .search: submitSearch()
            case .routeSelection: send(.planTapped)
            default: break
            }
        case .enterKey: showsSettings = true
        case .switchToStops: setScope(.stops)
        case .newSearch: send(.reset)
        case .openSettings: break // oeffnet die View per openURL
        }
    }

    // MARK: Server-Schluessel

    /// Gleiche Regeln wie das Backend: 32-512 Zeichen, druckbares ASCII ohne Leerzeichen. nil = ungueltig.
    nonisolated static func validatedServerKey(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...512).contains(key.count),
              key.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) })
        else { return nil }
        return key
    }

    /// Schreibt nur in die Keychain; der Schluessel wird nie geloggt oder wieder angezeigt.
    func saveServerKey(_ key: String) throws(TransitError) {
        try deps.secrets.write(Data(key.utf8), for: .apiToken)
        hasServerKey = true
        if banner == .missingToken || banner == .unauthorized { banner = nil }
    }

    func deleteServerKey() throws(TransitError) {
        try deps.secrets.delete(.apiToken)
        hasServerKey = false
    }

    #if DEBUG
    // MARK: Tests

    /// Wartet auf die laufende Suche/Planung (nur fuer Tests).
    func waitForWork() async {
        await work?.value
    }
    #endif
}
