import Foundation
import MapKit
import Observation
import TransitCore

/// Welcher Endpunkt gerade gesucht wird.
enum EndpointSlot: Sendable, Hashable {
    case origin, destination
}

/// Von wo die Suche geoeffnet wurde: aus 1 Start (Treffer = Ziel, sofort planen) oder aus 2c (zurueck zu den Optionen).
enum SearchReturn: Sendable, Hashable {
    case start, options
}

/// Phasen im persistenten Sheet (DESIGN.md B). Fahrtdetails sind ein Zustand im Sheet, kein Push.
enum Phase: Sendable, Hashable {
    case start
    case search(EndpointSlot, SearchReturn)
    /// 2c Von/Nach und Zeit
    case options
    case routeSelection
    /// Index der Verbindung in der aktuellen Antwort.
    case tripDetails(Int)
    /// Unterwegs; der Unterzustand (DESIGN.md C) steht in `AppFlow.navStep`.
    case navigation(Int)
    case arrival

    /// Laufende Arbeit gehoert zu einem Kontext. Verlaesst die Phase ihn, wird die Arbeit abgebrochen.
    /// Optionen, Routenauswahl und Fahrtdetails teilen sich die Planung (Kalibrierung laeuft weiter).
    enum WorkContext: Hashable { case none, search, route }

    var workContext: WorkContext {
        switch self {
        case .search: .search
        case .options, .routeSelection, .tripDetails: .route
        case .start, .navigation, .arrival: .none
        }
    }

    /// Navigation oder Ankunft (Layout C).
    var isGuiding: Bool {
        switch self {
        case .navigation, .arrival: true
        default: false
        }
    }

    /// Verbindung, die die Karte zeigt.
    var journeyIndex: Int? {
        switch self {
        case .routeSelection, .options: 0
        case .tripDetails(let i), .navigation(let i): i
        case .start, .search, .arrival: nil
        }
    }
}

enum FlowEvent: Sendable, Hashable {
    case editEndpoint(EndpointSlot)
    case endpointChosen
    /// "Jetzt" im Kopf der Routenauswahl oder Tipp auf Von/Nach (2c).
    case editOptions
    /// "Verbindungen suchen" (2c: neu gesucht wird nur auf Knopfdruck), auch als Erneut-Versuch.
    case planTapped
    case journeySelected(Int)
    case startNavigation(Int)
    case arrived
    /// "Nächste Verbindung" aus der Navigation (Ausfall, Anschluss verpasst): neu ab "Mein Standort", jetzt.
    case replan
    case back
    case reset

    /// Rueckwaerts-Ereignisse; die View laesst den Inhalt dann von links einblenden.
    var isBackward: Bool { self == .back || self == .reset }
}

/// Schritte des ersten Starts (DESIGN.md A1, A2).
enum OnboardingStep: Sendable, Hashable {
    case welcome, serverKey
}

/// Aktionen, die ein Inline-Banner anbietet (DESIGN.md H1). Keine Alerts.
enum BannerAction: Sendable, Hashable {
    case retry, enterKey, openSettings, allowLocation, switchToStops, newSearch
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

/// Ergebnis von "Verbindung prüfen" (A2).
enum ConnectionCheck: Sendable, Hashable {
    case checking, connected, failed(TransitError)
}

/// Polylines einer Verbindung, einmal pro Antwort umgerechnet (nicht in `body`).
struct RouteOverlay: Sendable {
    struct Segment: Sendable, Identifiable {
        let id: Int
        let mode: TransitMode
        let isWalk: Bool
        let coordinates: [CLLocationCoordinate2D]
    }

    /// Wechselt mit Antwort und gezeigter Verbindung (Ausloeser fuer die Kamerafahrt).
    let id: String
    let segments: [Segment]
    let rect: MKMapRect

    /// Ohne Polyline (z. B. Refresh ohne Geometrie) gerade Linie von Halt zu Halt.
    /// `nonisolated async`: laeuft abseits des MainActors (AGENT.md Checkliste 2).
    nonisolated static func make(_ journey: Journey, id: String) async -> RouteOverlay? {
        let segments = journey.legs.compactMap { leg -> Segment? in
            let points = leg.polyline?.points ?? [leg.origin.coordinate, leg.destination.coordinate].compactMap { $0 }
            guard points.count >= 2 else { return nil }
            return Segment(id: leg.index, mode: leg.mode, isWalk: leg.isWalk,
                           coordinates: points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
        }
        let mapPoints = segments.flatMap(\.coordinates).map(MKMapPoint.init)
        guard let first = mapPoints.first else { return nil }
        let rect = mapPoints.dropFirst().reduce(MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))) {
            $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 0, height: 0)))
        }
        return RouteOverlay(id: id, segments: segments, rect: rect)
    }
}

/// Start oder Ziel im Zustand. "Mein Standort" ist ein Platzhalter, der erst beim Planen zu einer Koordinate wird;
/// GPS-Koordinaten stehen nie im Zustand oder im Verlauf (AGENT.md 3.1.2).
enum PlanEndpoint: Sendable, Hashable {
    case currentLocation
    case place(TripEndpoint)

    var label: String {
        switch self {
        case .currentLocation: String(localized: "Mein Standort")
        case .place(let p): p.label
        }
    }

    var place: TripEndpoint? {
        if case .place(let p) = self { return p }
        return nil
    }
}

/// Was eine Planung ausmacht; nur bei gleicher Anfrage darf die alte Antwort als Offline-Stand stehen bleiben.
private struct PlanKey: Hashable {
    let origin: PlanEndpoint
    let destination: PlanEndpoint
    let time: Date?
    let isArrivalTime: Bool
}

@Observable @MainActor
final class AppFlow {
    private(set) var phase: Phase = .start
    /// Richtung des letzten Wechsels (zurueck = Inhalt kommt von links).
    private(set) var movedBackward = false
    private(set) var onboarding: OnboardingStep?

    // Suche
    /// Pflichtschalter, Standard "Adresse" (nichts geht an das eigene Backend). Aendern nur ueber `setScope`.
    private(set) var scope: SearchScope = .address
    var query = ""
    private(set) var results = SearchResults()
    private(set) var isSearching = false

    // Fahrt
    /// Standard "Mein Standort" (aufgeloest erst beim Planen; ohne Erlaubnis muss ein Start gewaehlt werden).
    private(set) var origin: PlanEndpoint = .currentLocation
    private(set) var destination: PlanEndpoint?
    /// nil = jetzt (beim Tippen auf "Verbindungen suchen" bestimmt).
    var customTime: Date?
    var isArrivalTime = false
    private(set) var routes: RoutesResponse?
    /// nil, solange nur das Skelett vorliegt.
    private(set) var calibrated: [CalibratedJourney]?
    private(set) var isPlanning = false
    /// 3a: nach `waitingHint` ohne Antwort.
    private(set) var isWaitingForNetwork = false
    /// H3: letzte Antwort bleibt nach Offline-Fehler sichtbar (abgeblendet).
    private(set) var isStale = false
    private(set) var overlay: RouteOverlay?

    // Status
    private(set) var banner: TransitError?
    private(set) var blockedUntil: Date?
    private(set) var attribution: Attribution?
    private(set) var hasServerKey: Bool
    /// Echter iOS-Status; bei jeder Rueckkehr in die App neu gelesen.
    private(set) var locationAuthorization: LocationAuthorization
    /// Nur die Genauigkeit des letzten Fixes fuer den Status; die Koordinate wird nie gehalten (AGENT.md 3.1.2).
    private(set) var lastAccuracy: Double?
    private(set) var connectionCheck: ConnectionCheck?

    // Navigation (DESIGN.md C). Live-Standort nur im RAM und nur waehrend der Navigation.
    private(set) var navStep: NavigationStep?
    /// Verbindung mit aktuellen Zeiten (nach jedem Refresh ersetzt).
    private(set) var navJourney: Journey?
    /// Original mit Polylines und Wegschritten (Refresh liefert ohne Geometrie).
    private(set) var navGeometry: Journey?
    private(set) var navWalks: [Int: WalkEstimate] = [:]
    private(set) var navPosition: GeoCoordinate?
    /// Zeitpunkt der letzten Auswertung; Ansichten zaehlen daran (gleiche Uhr wie die Logik).
    private(set) var navNow = Date()
    private(set) var navStartedAt: Date?
    /// Letzter Stand bleibt sichtbar, Echtzeit pausiert (H3), z. B. offline oder Rate-Limit.
    private(set) var navIsStale = false
    /// Verbindung laesst sich nicht mehr aktualisieren (410): naechste Verbindung anbieten.
    private(set) var navExpired = false
    /// Zaehler fuer `.sensoryFeedback(.warning)`: Gleiswechsel, Puffer unter 90 s.
    private(set) var navWarnings = 0
    /// Letzter Roh-Fix mit Empfangszeit (Uhr `deps.now`) und Genauigkeit fuer "verpasst"; nur im RAM, nie beobachtet.
    @ObservationIgnored private var navFix: LocationFix?
    @ObservationIgnored private var navTasks: [Task<Void, Never>] = []
    /// Fahrzeuge, fuer die die Puffer-/Anschluss-Haptik schon kam (einmal je Fahrzeug).
    @ObservationIgnored private var warnedVehicles: Set<Int> = []
    /// Zeile der Restfahrt angetippt: Karte zeigt diesen Punkt (MapScreen), Folgen pausiert bis "Zentrieren".
    var navFocus: NavMapFocus?
    var showsSettings = false
    /// Einstellungen direkt auf "Dein Server" oeffnen (Banner-Aktion).
    var settingsOpensServer = false

    nonisolated static let maxQueryLength = 80
    /// Kleinere Standortsprünge gelten als GPS-Rauschen (Meter).
    nonisolated static let positionThreshold: Double = 3

    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var waitingTask: Task<Void, Never>?
    @ObservationIgnored private var unblock: Task<Void, Never>?
    @ObservationIgnored private var fixTask: Task<Void, Never>?
    @ObservationIgnored private var overlayTask: Task<Void, Never>?
    @ObservationIgnored private var lastPlanKey: PlanKey?
    // ponytail: fester Standardwert; SwiftData-PaceProfile anbinden, sobald die Gehzeit-Messung (Navigation) existiert.
    @ObservationIgnored let pace = WalkingPaceFactor()

    init(_ deps: AppDependencies) {
        self.deps = deps
        let choice = deps.loadOnboarding()
        locationAuthorization = deps.authorization()
        do {
            hasServerKey = try deps.secrets.read(.apiToken) != nil
        } catch {
            hasServerKey = false
            banner = error
        }
        onboarding = choice == nil ? .welcome : nil
    }

    var locationAllowed: Bool { locationAuthorization == .allowed }

    /// "Mein Standort" ist nur nutzbar, wenn iOS den Standort erlaubt.
    private func usable(_ endpoint: PlanEndpoint) -> Bool {
        endpoint != .currentLocation || locationAllowed
    }

    var canPlan: Bool {
        guard let destination else { return false }
        return usable(origin) && usable(destination) && origin != destination && blockedUntil == nil
    }

    /// Tauschen nur, wenn beide Seiten bekannt und nutzbar sind (kein Fix noetig: Platzhalter wandert mit).
    var canSwap: Bool {
        guard let destination else { return false }
        return usable(origin) && usable(destination)
    }

    func endpoint(_ slot: EndpointSlot) -> PlanEndpoint? {
        slot == .origin ? origin : destination
    }

    // MARK: Erster Start (A1, A2)

    /// "Weiter": loest den System-Dialog aus (CLServiceSession in CoreLocationService).
    func finishWelcome(allowLocation: Bool) async {
        deps.saveOnboarding(allowLocation ? .withLocation : .withoutLocation)
        if allowLocation { await refreshFix() }
        locationAuthorization = deps.authorization()
        onboarding = hasServerKey ? nil : .serverKey
    }

    func finishServerKeyStep() {
        onboarding = nil
    }

    /// Standort nachtraeglich erlauben (Banner im Adressmodus nach "Ohne Standort fortfahren").
    func allowLocation() async {
        deps.saveOnboarding(.withLocation)
        await refreshFix()
        locationAuthorization = deps.authorization()
    }

    /// scenePhase .active: Status neu aus iOS lesen (Nutzer kann ihn in den Einstellungen geaendert haben),
    /// Genauigkeit fuer den Status auffrischen (kein Netz, nur CoreLocation).
    func becameActive() {
        locationAuthorization = deps.authorization()
        guard locationAllowed, onboarding == nil else {
            lastAccuracy = nil
            return
        }
        fixTask?.cancel()
        fixTask = Task { await refreshFix() }
    }

    /// Hintergrund: nichts Standortbezogenes behalten.
    func movedToBackground() {
        fixTask?.cancel()
        lastAccuracy = nil
    }

    private func refreshFix() async {
        do {
            lastAccuracy = try await deps.location.currentFix().horizontalAccuracy
        } catch {
            lastAccuracy = nil
        }
    }

    // MARK: Uebergaenge

    /// Reine Uebergangsfunktion ohne Seiteneffekte. nil = ungueltiger Uebergang, wird ignoriert.
    nonisolated static func next(_ phase: Phase, _ event: FlowEvent) -> Phase? {
        switch (phase, event) {
        case (.start, .reset): nil
        case (_, .reset): .start
        case (.start, .editEndpoint(let slot)): .search(slot, .start)
        case (.options, .editEndpoint(let slot)): .search(slot, .options)
        case (.search(_, .start), .endpointChosen): .routeSelection
        case (.search(_, .options), .endpointChosen), (.search(_, .options), .back): .options
        case (.search(_, .start), .back): .start
        case (.routeSelection, .editOptions): .options
        case (.options, .planTapped), (.routeSelection, .planTapped): .routeSelection
        case (.options, .back): .routeSelection
        case (.routeSelection, .journeySelected(let i)): .tripDetails(i)
        case (.routeSelection, .back): .start
        case (.routeSelection, .startNavigation(let i)), (.tripDetails, .startNavigation(let i)): .navigation(i)
        case (.tripDetails, .back): .routeSelection
        case (.navigation, .arrived): .arrival
        case (.navigation, .replan): .routeSelection
        case (.navigation(let i), .back): .tripDetails(i)
        case (.arrival, .back): .start
        default: nil
        }
    }

    /// Animation setzt die View (sie kennt Reduce Motion); das Modell bleibt SwiftUI-frei.
    func send(_ event: FlowEvent) {
        guard var new = Self.next(phase, event) else { return }
        let plans = event == .planTapped || event == .replan || (event == .endpointChosen && new == .routeSelection)
        if plans, !canPlan {
            // Ziel aus 1 Start, aber kein Start bekannt (ohne Standort): erst 2c statt leerer Liste.
            guard event == .endpointChosen, blockedUntil == nil else { return }
            new = .options
        }
        if new.workContext != phase.workContext { cancelWork() }
        if new == .start { discardRoutes() }
        if case .search = new, phase != new { query = ""; results = SearchResults() }
        movedBackward = event.isBackward
        let old = phase
        phase = new
        if plans, new == .routeSelection { startPlanning() }
        if case .navigation(let i) = new, event == .startNavigation(i) { beginNavigation(i) }
        if new == .arrival {
            // Angekommen: Live-Standort sofort verwerfen (AGENT.md 3.1.2), die Zusammenfassung braucht ihn nicht.
            stopNavigationTasks()
            navPosition = nil
            navFix = nil
        }
        if old.isGuiding, !new.isGuiding { endNavigation() }
        updateOverlay()
    }

    /// Zurueck zum Start: Verbindungen enthalten (gerundete) Start-Koordinaten und werden nicht laenger gehalten.
    private func discardRoutes() {
        overlayTask?.cancel()
        routes = nil
        calibrated = nil
        overlay = nil
        lastPlanKey = nil
        isStale = false
    }

    private func cancelWork() {
        work?.cancel()
        work = nil
        stopWaitingHint()
        isSearching = false
        isPlanning = false
        if banner != .rateLimited && banner != .keychainFailure { banner = nil }
    }

    // MARK: Suche

    /// Bei jeder Eingabe: entprellt.
    func queryChanged() { scheduleSearch(immediately: false) }

    /// Return: sofort.
    func submitSearch() { scheduleSearch(immediately: true) }

    /// Moduswechsel. Zero-Knowledge: Text aus dem Adressmodus (auch AutoFill-Adressen) darf nie als
    /// Haltestellen-Suchtext ans Backend gehen. Beim Wechsel auf "Haltestelle" wird das Feld geleert, der Nutzer tippt neu.
    func setScope(_ new: SearchScope) {
        guard new != scope else { return }
        scope = new
        work?.cancel()
        results = SearchResults()
        isSearching = false
        if banner == .locationDenied || banner == .locationUnavailable { banner = nil }
        switch new {
        case .stops: query = ""
        case .address: queryChanged() // bleibt lokal (MKLocalSearch)
        }
    }

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
        // Ohne Standort-Erlaubnis keine Adresssuche (VPN-Schutz: nie ohne GPS-Region); Hinweis statt Dialog.
        guard scope == .stops || locationAllowed else {
            results = SearchResults()
            isSearching = false
            banner = .locationDenied
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
        guard case .search(let slot, _) = phase else { return }
        set(.place(endpoint), for: slot)
    }

    /// "Mein Standort" als Start oder Ziel (Platzhalter, aufgeloest erst beim Planen).
    func useCurrentLocation() {
        guard case .search(let slot, _) = phase, locationAllowed else { return }
        set(.currentLocation, for: slot)
    }

    private func set(_ endpoint: PlanEndpoint, for slot: EndpointSlot) {
        switch slot {
        case .origin: origin = endpoint
        case .destination: destination = endpoint
        }
        send(.endpointChosen)
    }

    /// Tauschen dreht Von und Nach; "Mein Standort" bleibt Platzhalter, das Ziel geht nie verloren.
    func swapEndpoints() {
        guard canSwap, let destination else { return }
        (origin, self.destination) = (destination, origin)
    }

    // MARK: Planung

    private func startPlanning() {
        work?.cancel()
        guard let destination, blockedUntil == nil else { return }
        let origin = self.origin
        let key = PlanKey(origin: origin, destination: destination, time: customTime, isArrivalTime: isArrivalTime)
        // H3: bei gleicher Anfrage bleibt die letzte Antwort fuer den Offline-Fall in Reserve.
        let previous = key == lastPlanKey ? (routes, calibrated) : (nil, nil)
        routes = nil
        calibrated = nil
        isStale = false
        isPlanning = true
        banner = nil
        startWaitingHint()
        let time = customTime ?? deps.now()
        let arrival = isArrivalTime
        work = Task {
            do throws(TransitError) {
                // "Mein Standort": nur die Koordinate geht (gerundet) ans Backend, das Label bleibt lokal.
                // Die Koordinate lebt nur in diesem Task (Dauer der Berechnung), gespeichert wird nur die Genauigkeit.
                var here: TripEndpoint?
                if origin == .currentLocation || destination == .currentLocation {
                    let fix = try await deps.location.currentFix()
                    lastAccuracy = fix.horizontalAccuracy
                    here = .coordinate(fix.coordinate, label: PlanEndpoint.currentLocation.label)
                }
                guard let start = origin.place ?? here, let end = destination.place ?? here else { throw .locationUnavailable }
                let trip = ManualTripRequest(origin: start, destination: end, targetTime: time, isArrivalTime: arrival)
                try await consume(deps.planner.plan(trip, pace: pace))
                guard !Task.isCancelled else { return }
                lastPlanKey = key
                isPlanning = false
                stopWaitingHint()
            } catch {
                guard !Task.isCancelled else { return }
                isPlanning = false
                stopWaitingHint()
                if error.isTransient, let old = previous.0 {
                    routes = old
                    calibrated = previous.1
                    isStale = true
                    updateOverlay()
                }
                await show(error)
            }
        }
    }

    private func consume(_ stream: AsyncThrowingStream<HybridRouteCalculator.Stage, any Error>) async throws(TransitError) {
        do {
            for try await stage in stream {
                guard !Task.isCancelled else { return }
                switch stage {
                case .skeleton(let r):
                    routes = r
                    attribution = r.attribution
                    stopWaitingHint()
                case .calibrated(let r, let c):
                    routes = r
                    calibrated = c
                }
                updateOverlay()
            }
        } catch let error as TransitError {
            throw error
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .internal
        }
    }

    private func startWaitingHint() {
        waitingTask?.cancel()
        isWaitingForNetwork = false
        let delay = deps.waitingHint
        waitingTask = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            if isPlanning, routes == nil { isWaitingForNetwork = true }
        }
    }

    private func stopWaitingHint() {
        waitingTask?.cancel()
        waitingTask = nil
        isWaitingForNetwork = false
    }

    private func updateOverlay() {
        guard let index = phase.journeyIndex, let journey = journey(at: index) else {
            overlayTask?.cancel()
            if overlay != nil { overlay = nil }
            return
        }
        let id = "\(routes?.fetchedAt.timeIntervalSince1970 ?? 0)-\(index)"
        guard overlay?.id != id else { return }
        overlayTask?.cancel()
        overlayTask = Task {
            let made = await RouteOverlay.make(journey, id: id)
            guard !Task.isCancelled else { return }
            overlay = made
        }
    }

    func calibratedJourney(at index: Int) -> CalibratedJourney? {
        calibrated.flatMap { index < $0.count ? $0[index] : nil }
    }

    // MARK: Navigation

    private func beginNavigation(_ index: Int) {
        guard let journey = journey(at: index) else { return }
        stopNavigationTasks()
        navJourney = journey
        navGeometry = journey
        navWalks = calibratedJourney(at: index)?.walks ?? [:]
        navPosition = nil
        navFix = nil
        navStep = nil
        navIsStale = false
        navExpired = false
        warnedVehicles = []
        navStartedAt = deps.now()
        // Gleiswechsel schon beim Start: Hinweis und Haptik
        if journey.legs.contains(where: { $0.platformChanged == true }) { navWarnings += 1 }
        navigationUpdate(position: nil, now: deps.now())

        let tick = deps.navigationTick
        navTasks = [
            Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: tick) } catch { return }
                    navigationUpdate(position: nil, now: deps.now())
                }
            },
            Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: refreshInterval) } catch { return }
                    await refreshNavigation()
                }
            },
        ]
        // Ohne Erlaubnis kein Stream: liveUpdates wuerde bei .notDetermined den System-Dialog ausloesen. Dann nur nach Zeit.
        guard locationAllowed else { return }
        let positions = deps.positions
        navTasks.append(Task {
            for await fix in positions() {
                guard !Task.isCancelled else { return }
                navigationUpdate(position: fix.coordinate, accuracy: fix.horizontalAccuracy, now: deps.now())
            }
        })
    }

    /// 60 s im Normalbetrieb, 20 s vor einem Umstieg (SPEZIFIKATION 2.1).
    var refreshInterval: Duration {
        guard let journey = navJourney, let step = navStep else { return .seconds(60) }
        switch step {
        case .transferRouting: return .seconds(20)
        case .onBoardTransit(let v):
            let vehicles = journey.legs.filter { !$0.isWalk }
            guard let leg = vehicles.first(where: { $0.index == v }), leg.index != vehicles.last?.index,
                  let arrival = leg.arrival else { return .seconds(60) }
            return arrival.timeIntervalSince(navNow) < 300 ? .seconds(20) : .seconds(60)
        default: return .seconds(60)
        }
    }

    /// Neubewertung aus Position (falls neu) und Zeit. Reine Logik in `NavigationEngine.resolve`.
    /// `accuracy` in Metern; Empfangszeit = `now`.
    func navigationUpdate(position: GeoCoordinate?, accuracy: Double = 0, now: Date) {
        guard case .navigation = phase, let journey = navJourney else { return }
        if let position { navFix = LocationFix(coordinate: position, horizontalAccuracy: accuracy, timestamp: now) }
        // Akku und Ruhe: nur beobachtete Werte aendern, wenn sich sichtbar etwas tut. GPS-Rauschen unter 3 m
        // und Ticks innerhalb derselben Minute zeichnen nichts neu (Ausnahme: knapper Puffer zaehlt Sekunden).
        var moved = false
        if let position, navPosition.map({ $0.distance(to: position) >= Self.positionThreshold }) ?? true {
            navPosition = position
            moved = true
        }
        let step = NavigationEngine.resolve(journey: journey, fix: navFix, now: now, previous: navStep)
        let tight = NavigationEngine.targetVehicle(step).flatMap {
            NavigationEngine.buffer(journey: journey, geometry: navGeometry, vehicle: $0, walks: navWalks, position: navPosition, now: now, pace: pace)
        }.map { $0.seconds < 120 } ?? false
        let minute = { (d: Date) in Int(d.timeIntervalSince1970 / 60) }
        if step != navStep || tight || minute(now) != minute(navNow) || moved { navNow = now }
        if step != navStep { navStep = step }
        if let buffer = currentBuffer, buffer.needsWarning, let target = NavigationEngine.targetVehicle(step),
           warnedVehicles.insert(target).inserted {
            navWarnings += 1
        }
        // Im Fahrzeug: spaeterer Anschluss reicht nach Verspaetung nicht mehr -> einmal Haptik je Anschluss.
        if case .onBoardTransit(let v) = step,
           let broken = NavigationEngine.brokenConnection(after: v, journey: journey, walks: navWalks, now: now, pace: pace),
           warnedVehicles.insert(broken).inserted {
            navWarnings += 1
        }
        if step == .arrived { send(.arrived) }
    }

    /// Puffer fuer Fussweg zum Gleis und Umstieg; sonst nil.
    var currentBuffer: WalkBuffer? {
        guard let journey = navJourney, let step = navStep else { return nil }
        switch step {
        case .approachingFirstStop(let v), .transferRouting(_, let v), .missedDeparture(let v):
            return NavigationEngine.buffer(journey: journey, geometry: navGeometry, vehicle: v, walks: navWalks, position: navPosition, now: navNow, pace: pace)
        default:
            return nil
        }
    }

    /// POST /api/refresh (nur refreshToken). Fehler: letzter Stand bleibt, Echtzeit pausiert, Banner wie H1/H3.
    func refreshNavigation() async {
        // Retry-After (H1): kein Polling, bis die Sperre ablaeuft; der letzte Stand bleibt sichtbar.
        guard case .navigation = phase, blockedUntil == nil,
              let token = navJourney?.refreshToken, let old = navJourney else { return }
        do {
            let fresh = try await deps.refresh(token)
            guard case .navigation = phase, !Task.isCancelled else { return }
            if Self.platformChanged(from: old, to: fresh) { navWarnings += 1 }
            navJourney = fresh
            navIsStale = false
            if banner?.isTransient == true { banner = nil }
        } catch {
            guard case .navigation = phase, !Task.isCancelled else { return }
            if error == .refreshExpired { navExpired = true } else { navIsStale = true }
            await show(error)
        }
        navigationUpdate(position: nil, now: deps.now())
    }

    nonisolated static func platformChanged(from old: Journey, to fresh: Journey) -> Bool {
        fresh.legs.contains { leg in
            guard !leg.isWalk, let before = old.legs.first(where: { $0.index == leg.index }) else { return false }
            let moved = leg.departurePlatform != nil && before.departurePlatform != nil && leg.departurePlatform != before.departurePlatform
            return moved || (leg.platformChanged == true && before.platformChanged != true)
        }
    }

    /// "Nächste Verbindung": ab "Mein Standort" (sofern erlaubt), jetzt, gleiches Ziel.
    func nextConnection() {
        if locationAllowed {
            origin = .currentLocation
        } else if let v = navStep.flatMap(NavigationEngine.targetVehicle),
                  let stop = navJourney?.legs.first(where: { $0.index == v })?.origin, let id = stop.id {
            // Ohne Standort: ab dem Halt, an dem man den Anschluss erwischen wollte, nicht ab dem urspruenglichen Start.
            origin = .place(.stop(id: id, label: stop.name ?? id))
        }
        customTime = nil
        isArrivalTime = false
        send(.replan)
    }

    private func stopNavigationTasks() {
        navTasks.forEach { $0.cancel() }
        navTasks = []
    }

    /// Ende der Navigation: Standort und Stand verwerfen (AGENT.md 3.1.2).
    private func endNavigation() {
        stopNavigationTasks()
        navStep = nil
        navPosition = nil
        navFix = nil
        navJourney = nil
        navGeometry = nil
        navWalks = [:]
        navStartedAt = nil
        navIsStale = false
        navExpired = false
        navFocus = nil
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
        var actions = error.bannerActions.filter { $0 != .retry || blockedUntil == nil }
        // Noch nie gefragt: die App fragt selbst, statt in die iOS-Einstellungen zu schicken.
        if error == .locationDenied, locationAuthorization == .notDetermined {
            actions = actions.map { $0 == .openSettings ? .allowLocation : $0 }
        }
        return actions
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
        case .enterKey:
            settingsOpensServer = true
            showsSettings = true
        case .switchToStops: setScope(.stops)
        case .allowLocation:
            banner = nil
            Task { await allowLocation() }
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
        connectionCheck = nil
        if banner == .missingToken || banner == .unauthorized { banner = nil }
    }

    func deleteServerKey() throws(TransitError) {
        try deps.secrets.delete(.apiToken)
        hasServerKey = false
        connectionCheck = nil
    }

    /// "Verbindung prüfen" nur auf Knopfdruck (verbraucht Rate-Limit). Fester Suchtext, keine Nutzerdaten.
    func checkConnection() async {
        connectionCheck = .checking
        do {
            _ = try await deps.search.search("Hauptbahnhof", scope: .stops)
            connectionCheck = .connected
        } catch {
            connectionCheck = error == .cancelled ? nil : .failed(error)
        }
    }

    #if DEBUG
    // MARK: Tests

    /// Wartet auf die laufende Suche/Planung (nur fuer Tests).
    func waitForWork() async {
        await work?.value
        await overlayTask?.value
    }
    #endif
}
