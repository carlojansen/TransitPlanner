import Foundation
import MapKit
import Observation
import TransitCore

/// Welcher Endpunkt gerade gesucht wird.
enum EndpointSlot: Sendable, Hashable {
    case origin, destination
}

/// Phasen im persistenten Sheet (DESIGN.md B). Fahrtdetails sind ein Zustand im Sheet, kein Push.
enum Phase: Sendable, Hashable {
    case start
    /// Planen: Von/Nach, Zeit und Vorschlaege auf einem Bildschirm. Der Slot ist das Feld mit Fokus,
    /// nil = keins (Rueckkehr aus den Ergebnissen, die Tastatur bleibt zu).
    case plan(EndpointSlot?)
    case routeSelection
    /// Index der Verbindung in der aktuellen Antwort.
    case tripDetails(Int)
    /// Unterwegs; der Unterzustand (DESIGN.md C) steht in `AppFlow.navStep`.
    case navigation(Int)
    case arrival

    /// Laufende Arbeit gehoert zu einem Kontext. Verlaesst die Phase ihn, wird die Arbeit abgebrochen.
    /// Routenauswahl und Fahrtdetails teilen sich die Planung (Kalibrierung laeuft weiter).
    enum WorkContext: Hashable { case none, search, route }

    var workContext: WorkContext {
        switch self {
        case .plan: .search
        case .routeSelection, .tripDetails: .route
        case .start, .navigation, .arrival: .none
        }
    }

    var isPlan: Bool {
        if case .plan = self { return true }
        return false
    }

    /// Identitaet der Ansicht: Fokuswechsel zwischen Von und Nach ersetzt den Bildschirm nicht.
    var viewID: Phase { isPlan ? .plan(nil) : self }

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
        case .routeSelection: 0
        case .tripDetails(let i), .navigation(let i): i
        // Planen zeigt keine alte Route auf der Karte; die Ergebnisse bleiben fuer den Weg zurueck erhalten.
        case .start, .plan, .arrival: nil
        }
    }
}

enum FlowEvent: Sendable, Hashable {
    case editEndpoint(EndpointSlot)
    case endpointChosen
    /// Kopf der Routenauswahl: zurueck zur Planung (Eingaben bleiben).
    case editOptions
    /// "Verbindungen suchen", auch als Erneut-Versuch.
    case planTapped
    case journeySelected(Int)
    case startNavigation(Int)
    /// Tipp auf eine Erinnerung: die gespeicherte Verbindung steht als einzige in `routes`, aus jeder Phase.
    case resumeTrip
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
    case retry, enterKey, openSettings, allowLocation, chooseOrigin, newSearch
}

extension TransitError {
    /// `cancelled` zeigt nichts; `noConnections` erscheint als Leerzustand in der Liste statt als Banner.
    var showsBanner: Bool { self != .cancelled && self != .noConnections }

    var bannerActions: [BannerAction] {
        switch self {
        case .offline, .upstreamUnavailable, .upstreamTimeout: [.retry]
        case .missingToken, .unauthorized: [.enterKey]
        case .locationDenied: [.openSettings, .chooseOrigin]
        case .locationUnavailable: [.retry, .chooseOrigin]
        case .refreshExpired, .notFound: [.newSearch]
        // rateLimited: Restzeit statt Knopf (kein Neuversuch-Haemmern); pinningFailed: keine Umgehung anbieten.
        case .rateLimited, .pinningFailed, .noConnections, .cancelled,
             .invalidRequest, .internal, .decodingFailed, .keychainFailure, .storageUnavailable: []
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

    /// Start, Umstiegshalte und Ziel als Punkte auf der Linie.
    struct Marker: Sendable, Identifiable {
        enum Kind: Sendable {
            case start, transfer, destination

            /// VoiceOver-Name, wenn der Halt keinen Namen hat.
            var fallbackTitle: String {
                switch self {
                case .start: String(localized: "Start")
                case .transfer: String(localized: "Umstieg")
                case .destination: String(localized: "Ziel")
                }
            }
        }
        let id: Int
        let kind: Kind
        let title: String
        let coordinate: CLLocationCoordinate2D
    }

    /// Wechselt mit Antwort und gezeigter Verbindung (Ausloeser fuer die Kamerafahrt).
    let id: String
    let segments: [Segment]
    let markers: [Marker]
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
        func marker(_ id: Int, _ kind: Marker.Kind, _ place: Place?) -> Marker? {
            guard let place, let c = place.coordinate else { return nil }
            return Marker(id: id, kind: kind, title: place.name ?? kind.fallbackTitle, coordinate: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude))
        }
        // Umstieg = Einstieg in ein weiteres Fahrzeug; der erste Einstieg liegt am Ende des Zugangswegs.
        let transfers = journey.legs.filter { !$0.isWalk }.dropFirst().compactMap { marker($0.index, .transfer, $0.origin) }
        let markers = [marker(-1, .start, journey.legs.first?.origin)].compactMap { $0 } + transfers
            + [marker(-2, .destination, journey.legs.last?.destination)].compactMap { $0 }
        return RouteOverlay(id: id, segments: segments, markers: markers, rect: rect)
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
    let modes: Set<ModeFilter>
    let accessibility: Accessibility
}

@Observable @MainActor
final class AppFlow {
    private(set) var phase: Phase = .start
    /// Richtung des letzten Wechsels (zurueck = Inhalt kommt von links).
    private(set) var movedBackward = false
    private(set) var onboarding: OnboardingStep?

    // Suche
    /// Ein Feld, kein Schalter: `.address` sucht nur auf dem Geraet. `.stops` gilt erst nach dem Tipp auf
    /// "beim Fahrplan-Server suchen" (`searchOnServer`) und endet mit der naechsten Eingabe.
    private(set) var scope: SearchScope = .address
    var query = ""
    private(set) var results = SearchResults()
    private(set) var isSearching = false
    // Vorschlaege bei leerem Feld
    private(set) var favorites: [SavedPlace] = []
    private(set) var recents: [SavedPlace] = []
    /// Oeffentliche Haltestellendaten ohne Koordinate des Nutzers; beim Wechsel in den Hintergrund verworfen.
    private(set) var nearby: [Place] = []
    /// Leere Favoriten-Kachel angetippt: die naechste Wahl in Planen wird dieser Favorit (keine Suche).
    private(set) var assigningRole: FavoritePlace.Role?

    // Fahrt
    /// Standard "Mein Standort" (aufgeloest erst beim Planen; ohne Erlaubnis muss ein Start gewaehlt werden).
    private(set) var origin: PlanEndpoint = .currentLocation
    private(set) var destination: PlanEndpoint?
    /// nil = jetzt (beim Tippen auf "Verbindungen suchen" bestimmt).
    var customTime: Date?
    /// Verkehrsmittel-Pillen (Figma); alle an = voller Nahverkehrsfilter. Mindestens eine bleibt an.
    var modeFilter = Set(ModeFilter.allCases)
    /// Stufenfrei reisen (Einstellungen); lokal gespeichert, geht nur als Parameter ans Backend.
    var accessibility = Accessibility.stored {
        didSet { UserDefaults.standard.set(accessibility.rawValue, forKey: Accessibility.key) }
    }
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
    @ObservationIgnored private var endBackgroundLocation: (@MainActor @Sendable () -> Void)?
    /// Einmal in `beginNavigation` bestimmt und bis `endNavigation` gehalten: die Erinnerung kann unterwegs wegfallen.
    @ObservationIgnored private var navActivityKey: String?
    @ObservationIgnored private var inBackground = false
    /// Seit wann die Fahrt verpasst ist und niemand hinsieht (`NavigationEngine.missedGrace`).
    @ObservationIgnored private var navMissedSince: Date?
    /// Fahrzeuge, die laut Puffer nicht mehr reichen; eingerastet bis zum naechsten neuen Stand (DESIGN: einmal je Anschluss).
    @ObservationIgnored private var navMissedVehicles: Set<Int> = []
    @ObservationIgnored private var navRefreshing = false
    @ObservationIgnored private var lastNavRefresh: Date?
    /// Start gescheitert: Neuversuch erst beim naechsten Aktivwerden, nicht im Takt der Navigation.
    @ObservationIgnored private var activityStartFailed = false
    @ObservationIgnored private var departureSync: (at: Date, task: Task<Void, Never>)?
    @ObservationIgnored private var positionTask: Task<Void, Never>?
    /// Fahrzeuge, fuer die die Puffer-/Anschluss-Haptik schon kam (einmal je Fahrzeug).
    @ObservationIgnored private var warnedVehicles: Set<Int> = []
    /// Zeile der Restfahrt angetippt: Karte zeigt diesen Punkt (MapScreen), Folgen pausiert bis "Zentrieren".
    var navFocus: NavMapFocus?
    /// Karte ganz frei: Jetzt-Karte weg, Sheet nur eine Leiste. Zurueck per "Anweisung" oder automatisch bei neuem Schritt.
    var navMapOnly = false
    /// "Alternativen" unterwegs: Suche ab Standort, waehrend die Fahrt im Hintergrund weiterlaeuft.
    enum Peek { case loading, loaded(RoutesResponse, [CalibratedJourney]?), failed(TransitError) }
    private(set) var peek: Peek?
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    var showsSettings = false
    /// Index der Verbindung, fuer die das Erinnerungs-Sheet offen ist (D1).
    var reminderJourneyIndex: Int?
    /// D2: Liste der Erinnerungen.
    var showsReminders = false
    /// Einstellungen direkt auf "Dein Server" oeffnen (Banner-Aktion).
    var settingsOpensServer = false

    nonisolated static let maxQueryLength = 80
    /// Kleinere Standortsprünge gelten als GPS-Rauschen (Meter).
    nonisolated static let positionThreshold: Double = 3
    /// Mindestabstand fuer "Aktualisieren" in der Live Activity (Limit 12/min, 429 sperrt auch die Routensuche).
    nonisolated static let activityRefreshGap: TimeInterval = 30

    /// Erinnerungen (Liste, Mitteilungen, Neuberechnung); beobachtet sich selbst.
    @ObservationIgnored let reminders: ReminderCenter
    /// Tipp auf eine Mitteilung, bevor die App bereit ist (erster Start noch nicht durchlaufen).
    @ObservationIgnored private var pendingReminder: UUID?
    /// Suche ueber "Nächste Verbindung": startet daraus eine andere Fahrt, darf deren Wecker nicht weiterlaufen.
    @ObservationIgnored private var replacedReminder: UUID?
    @ObservationIgnored private var reminderCheck: Task<Void, Never>?
    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var waitingTask: Task<Void, Never>?
    @ObservationIgnored private var unblock: Task<Void, Never>?
    @ObservationIgnored private var fixTask: Task<Void, Never>?
    @ObservationIgnored private var nearbyTask: Task<Void, Never>?
    @ObservationIgnored private var nearbyLoadedAt: Date?
    @ObservationIgnored private var overlayTask: Task<Void, Never>?
    @ObservationIgnored private var lastPlanKey: PlanKey?
    /// Gelernter Gehzeit-Faktor (UserDefaults); lernt aus dem Fussweg zum Ziel, siehe `recordFinalWalk`.
    @ObservationIgnored private(set) var pace: WalkingPaceFactor

    init(_ deps: AppDependencies) {
        self.deps = deps
        reminders = ReminderCenter(deps)
        pace = deps.loadPace()
        let choice = deps.loadOnboarding()
        locationAuthorization = deps.authorization()
        do {
            hasServerKey = try deps.secrets.read(.apiToken) != nil
        } catch {
            hasServerKey = false
            banner = error
        }
        onboarding = choice == nil ? .welcome : nil
        reminders.onChange = { [weak self] in self?.syncActivities() }
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

    /// Feld mit Fokus in der Planen-Ansicht.
    var activeSlot: EndpointSlot? {
        if case .plan(let slot) = phase { slot } else { nil }
    }

    /// Beide Felder gefuellt und nutzbar: dann (und erst dann) zeigt Planen den Hauptknopf.
    var endpointsFilled: Bool { canSwap }

    /// Feld ist leer oder "Mein Standort" ohne Erlaubnis.
    private func needs(_ slot: EndpointSlot) -> Bool {
        endpoint(slot).map { !usable($0) } ?? true
    }

    // MARK: Erster Start (A1, A2)

    /// "Weiter": loest den System-Dialog aus (CLServiceSession in CoreLocationService).
    func finishWelcome(allowLocation: Bool) async {
        deps.saveOnboarding(allowLocation ? .withLocation : .withoutLocation)
        if allowLocation { await refreshFix() }
        locationAuthorization = deps.authorization()
        onboarding = hasServerKey ? nil : .serverKey
        openPendingReminder()
    }

    func finishServerKeyStep() {
        onboarding = nil
        openPendingReminder()
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
        inBackground = false
        activityStartFailed = false
        if !locationAllowed {
            endBackgroundLocation?()
            endBackgroundLocation = nil
        }
        // Rueckfall fuer den geplanten Start und Aufraeumen verwaister Activities; starten geht nur im Vordergrund.
        syncActivities()
        // Vor dem Standort-Guard: Erinnerungen funktionieren auch ohne Standort.
        if reminderCheck == nil {
            reminderCheck = Task {
                await reminders.checkDue()
                reminderCheck = nil
            }
        }
        guard locationAllowed, onboarding == nil else {
            lastAccuracy = nil
            return
        }
        fixTask?.cancel()
        fixTask = Task { await refreshFix() }
        // Nach dem Hintergrund ist die Naehe verworfen; der Start fragt neu (hoechstens alle 2 Min.).
        if phase == .start { loadSuggestions() }
    }

    /// Hintergrund: nichts Standortbezogenes behalten.
    func movedToBackground() {
        inBackground = true
        reminders.scheduleBackgroundCheck()
        fixTask?.cancel()
        nearbyTask?.cancel()
        nearby = []
        nearbyLoadedAt = nil
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
        case (.start, .editEndpoint(let slot)), (.plan, .editEndpoint(let slot)): .plan(slot)
        // Start: Tipp auf Favorit, Verlauf oder Haltestelle in der Naehe sucht sofort (DESIGN.md B1).
        case (.start, .endpointChosen), (.plan, .endpointChosen), (.plan, .planTapped), (.routeSelection, .planTapped): .routeSelection
        case (.plan, .back): .start
        // Eine Richtung zurueck: Details > Ergebnisse > Planen > Karte. Eingaben und Zeit bleiben im Zustand.
        case (.routeSelection, .editOptions), (.routeSelection, .back): .plan(nil)
        // Start waehrend der Rate-Limit-Sperre: Planen mit den Eingaben (AppFlow.set).
        case (.start, .editOptions): .plan(nil)
        case (.routeSelection, .journeySelected(let i)): .tripDetails(i)
        case (.routeSelection, .startNavigation(let i)), (.tripDetails, .startNavigation(let i)): .navigation(i)
        case (.tripDetails, .back): .routeSelection
        case (.navigation, .arrived): .arrival
        case (.navigation, .replan): .routeSelection
        // Beenden fuehrt zu den Ergebnissen derselben Suche, nicht zum leeren Start.
        case (.navigation, .back): .routeSelection
        // Wechsel auf eine Alternative aus der Fahrt ("Alternativen"): neue Verbindung, Navigation startet neu.
        case (.navigation, .startNavigation(let i)): .navigation(i)
        case (.arrival, .back): .start
        case (_, .resumeTrip): .navigation(0)
        default: nil
        }
    }

    /// Animation setzt die View (sie kennt Reduce Motion); das Modell bleibt SwiftUI-frei.
    func send(_ event: FlowEvent) {
        guard let new = Self.next(phase, event) else { return }
        let plans = event == .planTapped || event == .replan || (event == .endpointChosen && new == .routeSelection)
        if plans, !canPlan { return }
        let old = phase
        if new.workContext != phase.workContext { cancelWork() }
        if new == .start { discardRoutes() }
        if new.isPlan, phase != new { resetSearch() }
        if new.isPlan, !old.isPlan { loadSuggestions() }
        if new == .start || new.isPlan { replacedReminder = nil }
        // Start und Planen zeigen beide die Naehe; erst danach wird der Abruf abgebrochen.
        if !new.isPlan, new != .start { nearbyTask?.cancel() }
        if !new.isPlan { assigningRole = nil }
        movedBackward = event.isBackward
        phase = new
        if plans, new == .routeSelection { startPlanning() }
        if case .navigation(let i) = new, event == .startNavigation(i) || event == .resumeTrip { beginNavigation(i) }
        if case .startNavigation(let i) = event { retireReplacedReminder(journey(at: i)) }
        if new == .arrival {
            // Angekommen: Live-Standort sofort verwerfen (AGENT.md 3.1.2), die Zusammenfassung braucht ihn nicht.
            closeAlternatives()
            stopNavigationTasks()
            navPosition = nil
            navFix = nil
        }
        if old.isGuiding, !new.isGuiding { endNavigation() }
        updateOverlay()
        syncActivities()
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

    /// Bei jeder Eingabe: entprellt. Zero-Knowledge: Bearbeiten nimmt den Server-Stand zurueck, geaenderter Text
    /// geht nie unbemerkt ans Backend; die lokale Suche laeuft weiter.
    func queryChanged() {
        scope = .address
        scheduleSearch(immediately: false)
    }

    /// Return: sofort (lokal; nach "beim Server suchen" nochmal mit demselben Text).
    func submitSearch() {
        if scope == .stops { searchOnServer() } else { scheduleSearch(immediately: true) }
    }

    /// Erst dieser Tipp sendet den Suchtext an den Fahrplan-Server (ohne Standort).
    func searchOnServer() {
        guard phase.isPlan else { return }
        let text = searchText
        guard text.count >= 2 else { return }
        work?.cancel()
        scope = .stops
        results = SearchResults()
        isSearching = true
        work = Task { await runSearch(text, scope: .stops) }
    }

    var searchText: String {
        String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxQueryLength))
    }

    private func resetSearch() {
        work?.cancel()
        scope = .address
        query = ""
        results = SearchResults()
        isSearching = false
    }

    private func scheduleSearch(immediately: Bool) {
        guard phase.isPlan else { return }
        work?.cancel()
        let text = searchText
        // Ohne Standort-Erlaubnis keine Adresssuche (VPN-Schutz: nie ohne GPS-Region). Kein Banner und kein Dialog:
        // Favoriten, Verlauf und die Server-Zeile bleiben nutzbar.
        guard text.count >= 2, locationAllowed else {
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
            await runSearch(text, scope: .address)
        }
    }

    // MARK: Vorschlaege, Favoriten, Verlauf

    /// Favoriten, Verlauf und Haltestellen in der Naehe fuer Start und Planen.
    func loadSuggestions() {
        reloadSaved()
        loadNearby()
    }

    private func reloadSaved() {
        favorites = deps.places.favorites()
        let saved = Set(favorites.map(\.endpoint))
        recents = deps.places.recents().filter { !saved.contains($0.endpoint) }
    }

    /// Haltestellen in der Naehe: nur die gerundete Koordinate geht ans Backend, nur mit Erlaubnis, hoechstens alle 2 Minuten.
    /// Start und Planen loesen beim Erscheinen und bei Rueckkehr in die App aus; ein laufender Versuch genuegt,
    /// so geht pro Anlass nur eine Anfrage raus.
    private func loadNearby() {
        guard locationAllowed else {
            nearbyTask?.cancel()
            nearby = []
            return
        }
        if let running = nearbyTask, !running.isCancelled { return }
        if let at = nearbyLoadedAt, deps.now().timeIntervalSince(at) < 120 { return }
        nearbyTask = Task {
            // Jeder abgeschlossene Versuch zaehlt fuer die 2-Minuten-Grenze, auch leer oder fehlgeschlagen.
            // Abgebrochen: nichts anfassen, ein neuerer Versuch kann schon laufen.
            defer {
                if !Task.isCancelled {
                    nearbyLoadedAt = deps.now()
                    nearbyTask = nil
                }
            }
            do {
                let fix = try await deps.location.currentFix()
                let response = try await deps.nearby(fix.coordinate)
                guard !Task.isCancelled else { return }
                nearby = Array(response.places.filter { $0.kind == .stop && $0.id != nil && $0.name != nil }.prefix(6))
                attribution = response.attribution
            } catch {
                // Vorschlaege sind optional: kein Banner, die Suche bleibt nutzbar.
            }
        }
    }

    func addFavorite(_ endpoint: TripEndpoint) {
        deps.places.addFavorite(endpoint, role: .other)
        reloadSaved()
    }

    /// Leere Kachel (Zuhause, Uni, Arbeit, "+"): Planen oeffnen; die Wahl dort wird der Favorit.
    func assignFavorite(_ role: FavoritePlace.Role) {
        guard phase == .start else { return }
        assigningRole = role
        send(.editEndpoint(.destination))
    }

    func removeRecent(_ id: UUID) {
        deps.places.removeRecent(id)
        reloadSaved()
    }

    func removeFavorite(_ id: UUID) {
        deps.places.removeFavorite(id)
        reloadSaved()
    }

    func clearRecents() {
        deps.places.clearRecents()
        reloadSaved()
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
            // Ein fehlender Standort blockiert die Suche nie: Favoriten, Verlauf und Server-Zeile bleiben.
            if error != .locationDenied, error != .locationUnavailable { await show(error) }
            guard !Task.isCancelled else { return }
        }
        isSearching = false
    }

    /// Wahl eines Orts. Im Start (Favorit, Verlauf, Naehe) wie in Planen, aber immer ab "Mein Standort" und jetzt.
    func choose(_ endpoint: TripEndpoint) {
        let focus: EndpointSlot
        switch phase {
        case .plan(let slot):
            if let role = assigningRole {
                deps.places.addFavorite(endpoint, role: role)
                reloadSaved()
                send(.back)
                return
            }
            focus = slot ?? .destination
        case .start:
            origin = .currentLocation
            customTime = nil
            isArrivalTime = false
            focus = .destination
        default:
            return
        }
        deps.places.remember(endpoint)
        set(.place(endpoint), for: focus)
    }

    /// "Mein Standort" als Start oder Ziel (Platzhalter, aufgeloest erst beim Planen; nie im Verlauf).
    func useCurrentLocation() {
        // "Mein Standort" wird nie Favorit (AGENT.md 3.1.2).
        guard case .plan(let focus) = phase, locationAllowed, assigningRole == nil else { return }
        set(.currentLocation, for: focus ?? .destination)
    }

    /// Wahl eintragen. Sind danach beide Felder nutzbar, startet die Suche sofort; sonst springt der Fokus zum
    /// fehlenden Feld (z. B. ohne Standort erst Ziel, dann Start).
    private func set(_ endpoint: PlanEndpoint, for slot: EndpointSlot) {
        switch slot {
        case .origin: origin = endpoint
        case .destination: destination = endpoint
        }
        resetSearch()
        reloadSaved()
        if canPlan {
            send(.endpointChosen)
        } else if let missing = [EndpointSlot.destination, .origin].first(where: needs) {
            send(.editEndpoint(missing))
        } else if blockedUntil != nil {
            // Sperre nach 429: Planen zeigt die Restzeit, statt den Tipp im Start still zu verwerfen.
            send(.editOptions)
        }
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
        let key = PlanKey(origin: origin, destination: destination, time: customTime, isArrivalTime: isArrivalTime, modes: modeFilter, accessibility: accessibility)
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
        let modes: [ModeFilter]? = modeFilter.count == ModeFilter.allCases.count ? nil : ModeFilter.allCases.filter(modeFilter.contains)
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
                let trip = ManualTripRequest(origin: start, destination: end, targetTime: time, isArrivalTime: arrival, modes: modes, accessibility: accessibility)
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
                    // Neusortierung nach der Kalibrierung: ein schon geoeffnetes Detail bleibt bei derselben Verbindung.
                    if case .tripDetails(let i) = phase, let shown = routes?.journeys[safe: i],
                       let moved = r.journeys.firstIndex(of: shown), moved != i {
                        phase = .tripDetails(moved)
                    }
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
        let key = reminders.reminder(for: journey)?.id.uuidString ?? UUID().uuidString
        navActivityKey = key
        navMissedVehicles = []
        deps.activities.forgive(key)
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
    }

    /// GPS erst ab der Schwelle: im Wartezustand (evtl. Stunden) kein Standortabruf, die Engine braucht ihn dort nicht.
    /// Ohne Erlaubnis kein Stream: liveUpdates wuerde bei .notDetermined den System-Dialog ausloesen. Dann nur nach Zeit.
    private func startPositionsIfNeeded(_ step: NavigationStep) {
        guard locationAllowed else { return }
        if case .waitingToLeave = step { return }
        // Wiederholt sich je Update: faellt die Gehphase in den Hintergrund, klappt es beim naechsten Mal im Vordergrund.
        if endBackgroundLocation == nil { endBackgroundLocation = deps.beginBackgroundLocation() }
        guard positionTask == nil else { return }
        let positions = deps.positions
        positionTask = Task {
            for await fix in positions() {
                guard !Task.isCancelled else { return }
                navigationUpdate(position: fix.coordinate, accuracy: fix.horizontalAccuracy, now: deps.now())
            }
        }
    }

    /// 60 s im Normalbetrieb, 20 s vor einem Umstieg (SPEZIFIKATION 2.1); im Wartezustand erst zur Schwelle.
    var refreshInterval: Duration {
        guard let journey = navJourney, let step = navStep else { return .seconds(60) }
        switch step {
        case .waitingToLeave:
            let due = NavigationEngine.leaveTime(journey)?.addingTimeInterval(-NavigationEngine.leaveLead).timeIntervalSince(navNow)
            // Hoechstens 30 Min. Pause: ein Ausfall waehrend des Wartens faellt so rechtzeitig auf.
            return .seconds(min(30 * 60, max(60, due ?? 60)))
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
        if navStep == .finalWalkToDestination, step == .arrived { recordFinalWalk(journey, now: now) }
        if step != navStep { navStep = step; navMapOnly = false }
        if case .missedDeparture = step, inBackground { navMissedSince = navMissedSince ?? now } else { navMissedSince = nil }
        // Obergrenze: ohne Treffer im Zielradius liefen GPS und Polling sonst unbegrenzt. Nur im Hintergrund: im Vordergrund
        // darf die Navigation nicht ohne Hinweis verschwinden, etwa offline bei langer Verspaetung.
        if inBackground, step != .arrived, let started = navStartedAt,
           now >= NavigationEngine.trackingEnd(journey: journey, startedAt: started, missedInBackgroundSince: navMissedSince) {
            send(.back)
            return
        }
        startPositionsIfNeeded(step)
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
        syncActivities()
    }

    /// Soll-Stand aus Navigation und naechster Erinnerung; Aufraeumen, Ersetzen und Doppelschutz stecken in `TripActivityPlanner`.
    func syncActivities() {
        let now = deps.now()
        var desired: [TripActivityDesire] = []
        if phase.isGuiding, let journey = navJourney, let step = navStep, let key = navActivityKey {
            let state = TripActivityState(journey: journey, step: step, leaveAt: reminders.reminder(for: journey)?.plan.leaveAt,
                                          broken: connectionBroken(journey, step, now: now), now: now)
            desired.append(TripActivityPlanner.navigation(key: key, state: state, now: now))
        }
        let others = reminders.rows.map { (key: $0.id.uuidString, plan: $0.plan) }.filter { $0.key != navActivityKey }
        if let next = TripActivityPlanner.nextReminder(others, now: now) { desired.append(next) }
        let activities = deps.activities
        apply(TripActivityPlanner.actions(running: activities.running(), desired: desired,
                                          canStart: activities.canStart && !activityStartFailed, rejected: activities.rejected()))
        // Vordergrund: ab der Abfahrt endet die Activity auch ohne weiteres Ereignis (Hintergrund: `ReminderPlan.nextCheck`).
        let departure = reminders.rows.map(\.plan.scheduled.firstDeparture).filter { $0 > now }.min()
        guard departureSync?.at != departure else { return }
        departureSync?.task.cancel()
        departureSync = departure.map { date in
            (date, Task { [weak self] in
                do { try await Task.sleep(for: .seconds(date.timeIntervalSince(now))) } catch { return }
                self?.departureSync = nil
                self?.syncActivities()
            })
        }
    }

    /// Rastet je Fahrzeug ein: GPS-Spruenge um Puffer 0 duerfen den Ausfall nicht wiederholt an- und abschalten. Nur mit
    /// Position: ohne Fix rechnet `currentBuffer` mit dem ganzen Fussweg, das zaehlt nur bis zum ersten Fix.
    /// Das Zielfahrzeug im Umstieg kennt nur `currentBuffer`: `brokenConnection` rechnet ohne Position mit dem ganzen Fussweg.
    private func connectionBroken(_ journey: Journey, _ step: NavigationStep, now: Date) -> Bool {
        var ahead = NavigationEngine.targetVehicle(step) ?? .max
        var last: Int?
        switch step {
        case .onBoardTransit(let v):
            last = v
            ahead = v + 1
        case .transferRouting(_, let to): last = to
        case .waitingAtPlatform(let v): ahead = v + 1 // am Gleis: dieses Fahrzeug ist erreicht
        default: break
        }
        let live = currentBuffer?.status == .missed
        if live, navPosition != nil, let target = NavigationEngine.targetVehicle(step) { navMissedVehicles.insert(target) }
        if let last, let broken = NavigationEngine.brokenConnection(after: last, journey: journey, walks: navWalks, now: now, pace: pace) {
            navMissedVehicles.insert(broken)
        }
        return live || navMissedVehicles.contains { $0 >= ahead }
    }

    /// Scheitert ein Start, bleibt es still: die Mitteilungen sind der Rueckfall.
    private func apply(_ actions: [TripActivityAction]) {
        do throws(TransitError) { try deps.activities.apply(actions) } catch { activityStartFailed = true }
    }

    /// Knopf in der Live Activity. Unterwegs mit eigenem Mindestabstand, Erinnerungen drosselt `refreshDue`.
    func refreshFromActivity() async {
        if case .navigation = phase {
            let now = deps.now()
            guard !navRefreshing, lastNavRefresh.map({ now.timeIntervalSince($0) >= Self.activityRefreshGap }) ?? true else { return }
            await refreshNavigation()
        } else {
            if !phase.isGuiding { apply(TripActivityPlanner.stranded(deps.activities.running())) }
            await reminders.checkDue()
        }
        syncActivities()
    }

    /// Misst den Weg vom letzten Ausstieg bis zur Ankunft am Ziel gegen die Apple-Maps-Schaetzung (ohne Faktor).
    /// Nur wenn die Fahrt wirklich bis dort beobachtet wurde; Ausreisser verwirft `record`.
    private func recordFinalWalk(_ journey: Journey, now: Date) {
        guard let walk = journey.legs.last, walk.isWalk, let estimate = navWalks[walk.index],
              let alighted = journey.legs.last(where: { !$0.isWalk })?.arrival else { return }
        let predicted = Double(estimate.seconds) / pace.value
        var updated = pace
        guard updated.record(predictedSeconds: predicted, actualSeconds: now.timeIntervalSince(alighted)) else { return }
        pace = updated
        deps.savePace(updated)
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
        // 410 ist endgueltig: weitere Anfragen koennen nur scheitern.
        guard case .navigation = phase, blockedUntil == nil, !navExpired,
              let token = navJourney?.refreshToken, let old = navJourney else { return }
        navRefreshing = true
        lastNavRefresh = deps.now()
        defer { navRefreshing = false }
        do {
            let fresh = try await deps.refresh(token)
            guard case .navigation = phase, !Task.isCancelled, navJourney?.isSameTrip(as: old) == true else { return }
            if Self.platformChanged(from: old, to: fresh) { navWarnings += 1 }
            releaseMissedVehicles(from: old, to: fresh)
            navJourney = fresh
            navIsStale = false
            if banner?.isTransient == true { banner = nil }
        } catch {
            guard case .navigation = phase, !Task.isCancelled, navJourney?.isSameTrip(as: old) == true else { return }
            if error == .refreshExpired { navExpired = true } else { navIsStale = true }
            await show(error)
        }
        navigationUpdate(position: nil, now: deps.now())
    }

    /// Eingerastet bleibt, was der neue Stand nicht verbessert; jeder Refresh aendert irgendetwas (Halte, Remarks, Polylines).
    private func releaseMissedVehicles(from old: Journey, to fresh: Journey) {
        let now = deps.now()
        func seconds(_ journey: Journey, _ vehicle: Int) -> Int {
            NavigationEngine.buffer(journey: journey, vehicle: vehicle, walks: navWalks, position: nil, now: now, pace: pace)?.seconds ?? .min
        }
        navMissedVehicles = navMissedVehicles.filter { seconds(fresh, $0) <= seconds(old, $0) }
    }

    nonisolated static func platformChanged(from old: Journey, to fresh: Journey) -> Bool {
        fresh.legs.contains { leg in
            guard !leg.isWalk, let before = old.legs.first(where: { $0.index == leg.index }) else { return false }
            let moved = leg.departurePlatform != nil && before.departurePlatform != nil && leg.departurePlatform != before.departurePlatform
            return moved || (leg.platformChanged == true && before.platformChanged != true)
        }
    }

    /// Leere Ergebnisliste: dieselbe Suche 30 Minuten spaeter (aus der gewaehlten Zeit, sonst ab jetzt).
    /// Aktuelle Zeit der App-Uhr (Tests setzen sie).
    var now: Date { deps.now() }

    func searchLater() {
        // Eine verstrichene Wunschzeit zaehlt nicht: "30 Minuten spaeter" meint spaeter als jetzt.
        customTime = max(customTime ?? deps.now(), deps.now()).addingTimeInterval(30 * 60)
        send(.planTapped)
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
        // Laeuft eine Erinnerungsfahrt, gilt wie beim Hinweis: startet eine andere Fahrt, endet ihr Wecker.
        let running = navJourney.flatMap(reminders.reminder(for:))?.id
        send(.replan)
        replacedReminder = isPlanning ? running : nil
    }

    private func stopNavigationTasks() {
        navTasks.forEach { $0.cancel() }
        navTasks = []
        positionTask?.cancel()
        positionTask = nil
        endBackgroundLocation?()
        endBackgroundLocation = nil
    }

    /// Ende der Navigation: Standort und Stand verwerfen (AGENT.md 3.1.2).
    private func endNavigation() {
        closeAlternatives()
        stopNavigationTasks()
        navStep = nil
        navPosition = nil
        navFix = nil
        navJourney = nil
        navGeometry = nil
        navWalks = [:]
        navStartedAt = nil
        navActivityKey = nil
        navMissedVehicles = []
        navMissedSince = nil
        navIsStale = false
        navExpired = false
        navFocus = nil
        navMapOnly = false
    }

    /// Wo die Alternativen starten: am Standort oder an der naechsten Station der Fahrt (Umstieg, Einstieg, Ausstieg).
    enum PeekOrigin: Hashable { case position, nextStation }
    var peekOrigin: PeekOrigin = .position

    /// Naechste Station der laufenden Fahrt mit der Zeit, zu der man dort ist; nil kurz vor dem Ziel.
    var nextStation: (endpoint: TripEndpoint, name: String, time: Date)? {
        guard let journey = navJourney, let step = navStep else { return nil }
        let now = deps.now()
        func stop(_ place: Place, at time: Date?) -> (TripEndpoint, String, Date)? {
            let name = place.name ?? ""
            let when = max(now, time ?? now)
            if let id = place.id { return (.stop(id: id, label: name), name, when) }
            guard let coordinate = place.coordinate else { return nil }
            return (.coordinate(coordinate, label: name), name, when)
        }
        switch step {
        case .onBoardTransit(let v):
            guard let leg = journey.legs.first(where: { $0.index == v }) else { return nil }
            return stop(leg.destination, at: leg.arrival)
        case .waitingToLeave(let v), .approachingFirstStop(let v), .waitingAtPlatform(let v), .missedDeparture(let v):
            guard let leg = journey.legs.first(where: { $0.index == v }) else { return nil }
            return stop(leg.origin, at: leg.departure.map { $0.addingTimeInterval(-300) })
        case .transferRouting(_, let to):
            guard let leg = journey.legs.first(where: { $0.index == to }) else { return nil }
            return stop(leg.origin, at: leg.departure.map { $0.addingTimeInterval(-300) })
        case .finalWalkToDestination, .arrived:
            return nil
        }
    }

    /// Alternativen zum Ziel; Navigation und Karte bleiben unberuehrt.
    func openAlternatives(from origin: PeekOrigin? = nil) {
        guard case .navigation = phase, let target = destination?.place else { return }
        let source = origin ?? peekOrigin
        let next = nextStation
        // Ohne Standorterlaubnis nie currentFix() anfragen (loest sonst den System-Dialog aus): dann ab der naechsten Station.
        peekOrigin = (source == .nextStation || !locationAllowed) && next != nil ? .nextStation : .position
        guard peekOrigin == .nextStation || locationAllowed else { peek = .failed(.locationDenied); return }
        peekTask?.cancel()
        peek = .loading
        let now = deps.now()
        let pace = self.pace
        let useNext = peekOrigin == .nextStation
        let modes: [ModeFilter]? = modeFilter.count == ModeFilter.allCases.count ? nil : ModeFilter.allCases.filter(modeFilter.contains)
        peekTask = Task {
            do {
                let start: TripEndpoint
                let time: Date
                if useNext, let next {
                    start = next.endpoint
                    time = next.time
                } else {
                    let fix = try await deps.location.currentFix()
                    start = .coordinate(fix.coordinate, label: PlanEndpoint.currentLocation.label)
                    time = now
                }
                let trip = ManualTripRequest(origin: start, destination: target, targetTime: time, modes: modes, accessibility: accessibility)
                for try await stage in deps.planner.plan(trip, pace: pace) {
                    guard !Task.isCancelled else { return }
                    switch stage {
                    case .skeleton(let r): peek = .loaded(r, nil)
                    case .calibrated(let r, let c): peek = .loaded(r, c)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                peek = .failed((error as? TransitError) ?? .internal)
            }
        }
    }

    // MARK: Erinnerungen

    /// Scharfschalten fuer diese Verbindung; dieselbe Fahrt wird ersetzt, nicht verdoppelt.
    func setReminder(forJourney index: Int, earlierMinutes: Int, warnMinutes: Int) async throws(TransitError) {
        guard let calibrated = calibratedJourney(at: index), let attribution = routes?.attribution,
              let request = reminderRequest(calibrated.journey) else { throw .internal }
        try await reminders.set(calibrated, request: request, attribution: attribution,
                                earlierMinutes: earlierMinutes, warnMinutes: warnMinutes)
        deps.places.setEarlierMinutes(earlierMinutes, for: request.destination)
        retireReplacedReminder(calibrated.journey)
    }

    /// D1: die gespeicherte Erinnerung derselben Fahrt, sonst der zuletzt gewaehlte Wert fuer dieses Ziel. Passt der nicht
    /// mehr vor das Losgehen, die groesste kleinere Schnellwahl, sonst 0.
    func suggestedEarlierMinutes(forJourney index: Int) -> Int {
        guard let journey = journey(at: index) else { return 0 }
        if let plan = reminders.reminder(for: journey)?.plan { return plan.earlierMinutes }
        let target = reminderRequest(journey)?.destination.routePoint
        guard let remembered = deps.places.recents().first(where: { $0.endpoint.routePoint == target && $0.earlierMinutes != nil })?.earlierMinutes,
              let leave = calibratedJourney(at: index).flatMap({ try? reminders.scheduler.timeToLeave(for: $0).leaveAt }) else { return 0 }
        let fits = { (minutes: Int) in leave.addingTimeInterval(-TimeInterval(minutes * 60)) > self.deps.now() }
        return fits(remembered) ? remembered : ReminderSheet.earlierChoices.last { $0 < remembered && fits($0) } ?? 0
    }

    /// Der Nutzer hat aus "Nächste Verbindung" eine andere Fahrt gewaehlt: der alte Wecker endet. Dieselbe Fahrt behaelt ihn.
    private func retireReplacedReminder(_ chosen: Journey?) {
        guard let id = replacedReminder, let chosen else { return }
        replacedReminder = nil
        if reminders.reminder(id: id)?.plan.calibrated.journey.isSameTrip(as: chosen) == false { reminders.purge(id) }
    }

    /// Erste Mitteilung der gespeicherten Erinnerung fuer diese Verbindung (Neusortierung und Echtzeit inklusive).
    func reminderTime(forJourney index: Int) -> Date? {
        journey(at: index).flatMap(reminders.reminder(for:))?.plan.nextAlarm(now: deps.now())
    }

    /// Was "Nächste Verbindung" spaeter braucht. Bei "Mein Standort" ist der Start der erste Halt der Fahrt, das Ziel der
    /// Endpunkt der Verbindung. Der gerundete Startort liegt nur versiegelt in der Verbindung, bis die Erinnerung aufgeraeumt
    /// wird (AGENT.md 3.1.2).
    private func reminderRequest(_ journey: Journey) -> ManualTripRequest? {
        func endpoint(_ place: Place?) -> TripEndpoint? {
            guard let place else { return nil }
            if let id = place.id { return .stop(id: id, label: place.name ?? id) }
            return place.coordinate.map { .coordinate($0, label: place.name ?? String(localized: "Ziel")) }
        }
        let firstStop = journey.legs.first { !$0.isWalk }?.origin ?? journey.legs.first?.origin
        guard let start = origin.place ?? endpoint(firstStop),
              let end = destination?.place ?? endpoint(journey.legs.last?.destination) else { return nil }
        return ManualTripRequest(origin: start, destination: end, targetTime: journey.departure ?? deps.now(),
                                 modes: modeFilter.count == ModeFilter.allCases.count ? nil : ModeFilter.allCases.filter(modeFilter.contains),
                                 accessibility: accessibility)
    }

    /// Tipp auf eine Mitteilung oder "Starten"; wartet, bis der erste Start durchlaufen ist.
    func openReminder(_ id: UUID) {
        pendingReminder = id
        openPendingReminder()
    }

    /// Navigation der gespeicherten Fahrt, Start-Logik wie bei "Starten". Fehlt die Fahrt, startet die App normal.
    private func openPendingReminder() {
        guard onboarding == nil, let id = pendingReminder else { return }
        pendingReminder = nil
        replacedReminder = nil
        guard let reminder = reminders.reminder(id: id), !reminder.plan.isOver(now: deps.now()) else { return }
        let plan = reminder.plan
        // Laeuft schon: Position und Fortschritt nicht zuruecksetzen.
        if phase.isGuiding, navJourney?.isSameTrip(as: plan.calibrated.journey) == true { return }
        let token = reminders.token(id)
        showsSettings = false
        showsReminders = false
        reminderJourneyIndex = nil
        closeAlternatives()
        // Letzter Stand schon vor der ersten Bewertung (mit alten Zeiten waere die Bahn "weg", und der Zustand geht nie
        // zurueck) und auch in der Liste nach "Beenden".
        let journey = plan.navigationJourney.withRefreshToken(token)
        routes = .single(journey, fetchedAt: deps.now(), attribution: plan.attribution)
        calibrated = [plan.calibrated.replacingJourney(journey)]
        attribution = plan.attribution
        origin = .place(reminder.request.origin)
        destination = .place(reminder.request.destination)
        customTime = nil
        isArrivalTime = false
        lastPlanKey = nil
        isStale = false
        send(.resumeTrip)
        // Die Mitteilung heisst "losgehen": auch mit "frueher losgehen" nicht in der Wartekarte landen.
        if case .waitingToLeave(let vehicle) = navStep { navStep = .approachingFirstStop(vehicle: vehicle) }
        navigationUpdate(position: nil, now: deps.now())
        // In `navTasks`: endet diese Navigation, darf die Antwort keine andere ueberschreiben.
        navTasks.append(Task { await refreshNavigation() })
    }

    /// Hinweis Kritisch: neu suchen, jetzt, gleiches Ziel. Die Erinnerung bleibt, bis eine andere Fahrt gestartet wird.
    func nextConnection(for reminder: StoredReminder) {
        guard !phase.isGuiding else { return }
        showsReminders = false
        origin = locationAllowed ? .currentLocation : .place(reminder.request.origin)
        destination = .place(reminder.request.destination)
        customTime = nil
        isArrivalTime = false
        if case .tripDetails = phase { send(.back) }
        send(phase == .routeSelection ? .planTapped : .endpointChosen)
        replacedReminder = isPlanning ? reminder.id : nil
    }

    func closeAlternatives() {
        peekTask?.cancel()
        peekTask = nil
        peek = nil
    }

    /// Wechsel auf eine Alternative: ersetzt die laufende Verbindung.
    func chooseAlternative(_ index: Int) {
        guard case .loaded(let response, let walks) = peek, index < response.journeys.count else { return }
        routes = response
        calibrated = walks
        attribution = response.attribution
        isStale = false
        closeAlternatives()
        // Wie "Naechste Verbindung": startet eine andere Fahrt, endet der Wecker der laufenden.
        replacedReminder = navJourney.flatMap(reminders.reminder(for:))?.id
        send(.startNavigation(index))
    }

    func toggle(_ mode: ModeFilter) {
        if modeFilter.contains(mode) { if modeFilter.count > 1 { modeFilter.remove(mode) } } else { modeFilter.insert(mode) }
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
            case .plan: submitSearch()
            case .routeSelection: send(.planTapped)
            default: break
            }
        case .enterKey:
            settingsOpensServer = true
            showsSettings = true
        case .chooseOrigin:
            if !phase.isPlan { send(.editOptions) }
            send(.editEndpoint(.origin))
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

    func waitForNearby() async {
        await nearbyTask?.value
    }

    func waitForPeek() async {
        await peekTask?.value
    }

    func waitForReminderCheck() async {
        await reminderCheck?.value
    }
    #endif
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
