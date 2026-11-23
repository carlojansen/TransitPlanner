import Foundation
import MapKit
import Observation
import StoreKit
import TransitCore

/// Welcher Endpunkt gerade gesucht wird.
enum EndpointSlot: Sendable, Hashable {
    /// `via`: neuer Zwischenstopp (bestehende werden entfernt, nicht bearbeitet).
    case origin, destination, via
}

extension Journey {
    /// Umstiege ohne erkannte Aufenthalte an Zwischenstopps (MOTIS zaehlt den Aufenthalt als Umstieg, aber nur, wenn
    /// danach noch ein Fahrzeug kommt; am letzten Fahrzeug folgt nur der Fussweg).
    func transfers(excludingStaysAt via: [ViaStop]) -> Int {
        let counted = viaStays(via).filter { stay in legs.contains { !$0.isWalk && $0.index > stay.arrivalLeg } }
        return max(0, transfers - counted.count)
    }
}

extension ViaStay {
    /// Echte Dauer (Echtzeit), ganze Minuten: Ankunft bis zum Umstiegsweg, der darunter eigens steht; ohne Weg bis zur Abfahrt.
    func minutes(in journey: Journey) -> Int? {
        let walk = journey.legs.first { $0.index > arrivalLeg }.flatMap { $0.isWalk ? $0.departure ?? $0.plannedDeparture : nil }
        guard let arrival, let end = walk ?? departure else { return nil }
        return Int(end.timeIntervalSince(arrival) / 60)
    }
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
    let via: [ViaStop]
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
    /// Zaehlt abgelehnte Zwischenstopps (Adresse, Start/Ziel, dritter Stopp): Ausloeser fuer die Fehler-Haptik.
    private(set) var viaRejections = 0
    /// Leere Favoriten-Kachel angetippt: die naechste Wahl in Planen wird dieser Favorit (keine Suche).
    private(set) var assigningRole: FavoritePlace.Role?

    // Fahrt
    /// Standard "Mein Standort" (aufgeloest erst beim Planen; ohne Erlaubnis muss ein Start gewaehlt werden).
    private(set) var origin: PlanEndpoint = .currentLocation
    private(set) var destination: PlanEndpoint?
    /// Zwischenstopps in Reihenfolge (max. 2), nur Haltestellen; nie in Verlauf oder Favoriten.
    private(set) var via: [ViaStop] = []
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
    /// Fahrzeug, zu dem man geht, dessen Puffer mit Position nicht mehr reicht; eingerastet bis zum naechsten besseren Stand
    /// (GPS-Spruenge um 0 s). Spaetere Anschluesse rasten in `replanLatched` ein.
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
    /// `via`: die Stopps der Anfrage; "Wechseln" uebernimmt sie, damit erreichte nicht zurueckkommen.
    enum Peek { case loading, loaded(RoutesResponse, [CalibratedJourney]?, via: [ViaStop]), failed(TransitError) }
    private(set) var peek: Peek?
    @ObservationIgnored private var peekTask: Task<Void, Never>?

    /// Proaktive Umplanung (SPEZIFIKATION 4.4): Antwort einer Suche ab dem Suchstart, mit Gehzeiten und den gesendeten Stopps.
    struct ReplanAnswer: Sendable {
        let search: ReplanSearch
        let response: RoutesResponse
        let calibrated: [CalibratedJourney]
        let via: [ViaStop]
    }
    /// Vorschlag (zufaellige ID) mit der Antwort, aus der er stammt.
    struct ReplanOffer: Sendable {
        let proposal: ReplanProposal
        let answer: ReplanAnswer
    }
    /// Aktueller Vorschlag; alles zur Umplanung nur im RAM, nie in SwiftData oder Logs, mit der Navigation verworfen.
    /// Die Mitteilung folgt ihm (`syncReplanAlert`): jedes Ende des Vorschlags entfernt sie. Ein neuer ersetzt den Hinweis
    /// nach gescheitertem Wechsel.
    private(set) var replanOffer: ReplanOffer? {
        didSet {
            if replanOffer != nil { replanNotice = nil }
            syncReplanAlert()
        }
    }
    /// "Uebernehmen": Wechsel vorgemerkt. Die laufende Fahrt bleibt bis zur Ankunft am Suchstart, dort startet die Alternative.
    /// Faellt die Vormerkung weg (Verwerfen, Wechsel, Ende), endet auch ein laufender Wechsel-Refresh.
    private(set) var pendingSwitch: ReplanOffer? {
        didSet {
            if pendingSwitch == nil {
                switchTask?.cancel()
                switchTask = nil
            }
        }
    }
    /// Kurzer Hinweis nach Verfall ("Anschluss RB 25 reicht wieder") oder gescheitertem Wechsel, bis `replanExpiredUntil`.
    private(set) var replanExpired: String?
    @ObservationIgnored private var replanExpiredUntil = Date.distantPast
    /// So lange steht der Hinweis nach Verfall (s).
    nonisolated static let replanNoticeSeconds: TimeInterval = 60
    /// Diese Mitteilung steht; Senden und Entfernen laufen nacheinander.
    @ObservationIgnored private var postedAlert: ReplanAlert?
    /// Wechsel am Suchstart gescheitert, waehrend die App im Hintergrund war: Mitteilung ohne Vorschlag (bis Ende oder neuer Vorschlag).
    @ObservationIgnored private var replanNotice: ReplanAlert?
    @ObservationIgnored private var replanAlertTask: Task<Void, Never>?
    /// Blatt "Alternativen" aus dem Vorschlag: Suchstart der Antwort statt der naechsten Station.
    private var peekSearch: ReplanSearch?
    /// Letzte Antwort je Schluessel: loest derselbe Anschluss erneut aus, wird sie ohne neue Suche gezeigt.
    @ObservationIgnored private var replanAnswers: [ReplanKey: ReplanAnswer] = [:]
    @ObservationIgnored private var replanMemory = ReplanMemory()
    /// Eingerastete spaetere Fahrzeuge (`ConnectionWatch.evaluate`): Vorschlag, Live Activity und Haptik lesen dasselbe Set.
    @ObservationIgnored private var replanLatched: Set<Int> = []
    /// Wann ein Anschluss einrastete (RAM): Zeit bis zum Vorschlag fuer das Fall-Protokoll.
    @ObservationIgnored private var latchedAt: [Int: Date] = [:]
    /// Anonymes lokales Fall-Protokoll (nur Zahlen, gerundet) fuer "Bericht senden".
    @ObservationIgnored private var caseLog: CaseLog
    /// Ausloeser des letzten Ticks, frueheste zuerst.
    @ObservationIgnored private var replanSearches: [ReplanSearch] = []
    @ObservationIgnored private var replanTask: Task<Void, Never>?
    @ObservationIgnored private var switchTask: Task<Void, Never>?
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
        caseLog = deps.loadCaseLog()
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
        switch slot {
        case .origin: origin
        case .destination: destination
        case .via: nil
        }
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
        // Ein Vorschlag, der schon im Vordergrund stand, kommt jetzt als Mitteilung.
        syncReplanAlert()
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
            resetReplan()
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
    /// `coordinate`: Lage des Suchtreffers, nur fuer die Erkennung eines Zwischenstopps in der Antwort.
    func choose(_ endpoint: TripEndpoint, coordinate: GeoCoordinate? = nil) {
        let focus: EndpointSlot
        switch phase {
        case .plan(let slot):
            if let role = assigningRole {
                deps.places.addFavorite(endpoint, role: role)
                reloadSaved()
                send(.back)
                return
            }
            if slot == .via { return addVia(endpoint, coordinate: coordinate) }
            focus = slot ?? .destination
        case .start:
            origin = .currentLocation
            via = []
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
        guard case .plan(let focus) = phase, focus != .via, locationAllowed, assigningRole == nil else { return }
        set(.currentLocation, for: focus ?? .destination)
    }

    /// Wahl eintragen. Sind danach beide Felder nutzbar, startet die Suche sofort; sonst springt der Fokus zum
    /// fehlenden Feld (z. B. ohne Standort erst Ziel, dann Start).
    private func set(_ endpoint: PlanEndpoint, for slot: EndpointSlot) {
        switch slot {
        case .origin: origin = endpoint
        case .destination: destination = endpoint
        case .via: return // nur ueber addVia
        }
        advance()
    }

    /// Zwischenstopp: nur Haltestellen (Backend kennt nur Stop-IDs), hoechstens 2, nicht doppelt, nicht Start oder Ziel.
    /// Standard-Aufenthalt 15 Min.; danach wie jede Wahl weiter.
    private func addVia(_ endpoint: TripEndpoint, coordinate: GeoCoordinate?) {
        guard case .stop(let id, let label) = endpoint, via.count < 2, !via.contains(where: { $0.id == id }),
              origin.place?.routePoint != endpoint.routePoint, destination?.place?.routePoint != endpoint.routePoint else {
            viaRejections += 1
            return
        }
        // Favorit/Verlauf ohne Koordinate: die Umkreissuche kennt sie vielleicht (fuer die Erkennung in der Antwort).
        let coordinate = coordinate ?? nearby.first { $0.id == id }?.coordinate
        via.append(ViaStop(id: id, stayMinutes: 15, label: label, coordinate: coordinate))
        advance()
    }

    func removeVia(at index: Int) {
        guard via.indices.contains(index) else { return }
        via.remove(at: index)
    }

    func setStay(_ minutes: Int, at index: Int) {
        guard via.indices.contains(index) else { return }
        via[index].stayMinutes = minutes
    }

    private func advance() {
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
        via.reverse()
    }

    // MARK: Planung

    private func startPlanning() {
        work?.cancel()
        guard let destination, blockedUntil == nil else { return }
        let origin = self.origin
        let key = PlanKey(origin: origin, destination: destination, time: customTime, isArrivalTime: isArrivalTime, modes: modeFilter, accessibility: accessibility, via: via)
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
        let modes = modesParameter
        let via = self.via
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
                let trip = ManualTripRequest(origin: start, destination: end, targetTime: time, isArrivalTime: arrival, modes: modes, accessibility: accessibility,
                                             via: via.isEmpty ? nil : via)
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

    /// Bericht senden: nur in TestFlight (StoreKit-Umgebung `.sandbox`) und in Debug-Builds. Ohne Antwort von StoreKit
    /// (offline) bleibt der Button verborgen.
    private(set) var offersReport: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    func detectTestFlight() async {
        #if !DEBUG
        if let transaction = try? await AppTransaction.shared, case .verified(let app) = transaction, app.environment == .sandbox {
            offersReport = true
        }
        #endif
    }

    var caseCount: Int { caseLog.events.count }

    /// Schreibt die Berichtsdatei in den temporaeren Ordner (zum Teilen); der Aufrufer loescht sie danach.
    func writeReport() -> URL? {
        let info = Bundle.main.infoDictionary
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let report = CaseReport(log: caseLog, app: "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
                                os: "\(v.majorVersion).\(v.minorVersion)")
        return try? report.write(to: FileManager.default.temporaryDirectory)
    }

    /// Loescht das Protokoll (Datei und Speicher).
    func clearCaseLog() {
        caseLog = CaseLog()
        deps.saveCaseLog(caseLog)
    }

    /// Nur wo der Bericht angeboten wird: im App Store gibt es keine Stelle, das Protokoll zu sehen oder zu loeschen.
    private func record(_ events: [CaseEvent?]) {
        guard offersReport else { return }
        let before = caseLog
        events.forEach { caseLog.record($0) }
        if caseLog != before { deps.saveCaseLog(caseLog) }
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
                    record(CaseTrigger.departureNearMisses(in: c, now: deps.now()))
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
        resetReplan()
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
            // Ort: Ausstiegshalt des letzten Fahrzeugs, nie die Live-Position (Standort bleibt im RAM, AGENT.md 3.1.2).
            let target = journey.legs.last?.destination.coordinate
            let stop = journey.legs.last { !$0.isWalk }?.destination.coordinate
            record([navPosition.flatMap { p in target.map { p.distance(to: $0) } }.flatMap {
                CaseTrigger.arrivalWithoutGPS(endedByTime: true, distanceMeters: $0, now: now, near: stop)
            }])
            send(.back)
            return
        }
        startPositionsIfNeeded(step)
        if let buffer = currentBuffer, buffer.needsWarning, let target = NavigationEngine.targetVehicle(step),
           warnedVehicles.insert(target).inserted {
            navWarnings += 1
        }
        // Verpasst mit Position rastet ein, bevor die Umplanung auswertet (Vormerkung verwerfen im selben Tick).
        if currentBuffer?.status == .missed, navPosition != nil, let target = NavigationEngine.targetVehicle(step) {
            navMissedVehicles.insert(target)
        }
        evaluateReplan(now: now)
        if step == .arrived { send(.arrived) }
        syncActivities()
    }

    /// Soll-Stand aus Navigation und naechster Erinnerung; Aufraeumen, Ersetzen und Doppelschutz stecken in `TripActivityPlanner`.
    func syncActivities() {
        let now = deps.now()
        var desired: [TripActivityDesire] = []
        if phase.isGuiding, let journey = navJourney, let step = navStep, let key = navActivityKey {
            let state = TripActivityState(journey: journey, step: step, leaveAt: reminders.reminder(for: journey)?.plan.leaveAt,
                                          broken: connectionBroken(step, journey: journey, now: now), now: now)
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

    /// Problem "Anschluss": Puffer zum Zielfahrzeug jetzt verpasst oder ein Fahrzeug ab dort eingerastet.
    /// Zielfahrzeug: rastet in `navigationUpdate` nur mit Position ein (GPS-Spruenge um Puffer 0; ohne Fix rechnet `currentBuffer` mit dem ganzen
    /// Fussweg, das zaehlt nur bis zum ersten Fix). Spaetere Anschluesse: dieselbe Einrast-Regel wie der Vorschlag
    /// (`replanLatched`). Mit vorgemerktem Wechsel endet die alte Fahrt am Suchstart: Anschluesse danach zaehlen nicht mehr,
    /// bis zum Ausstiegsfahrzeug alles wie sonst. Nach dem Ausstieg entscheidet fuer das Zielfahrzeug nur `live` (mit Position);
    /// eingerastet zaehlen dann nur spaetere.
    private func connectionBroken(_ step: NavigationStep, journey: Journey, now: Date) -> Bool {
        let limit = pendingSwitch?.proposal.search.alightingVehicle ?? .max
        var ahead = NavigationEngine.targetVehicle(step) ?? .max
        var later = ahead
        switch step {
        case .onBoardTransit(let v), .waitingAtPlatform(let v): // im Fahrzeug oder am Gleis: dieses ist erreicht
            ahead = v + 1
            later = v + 1
        case .transferRouting(_, let to) where ConnectionWatch.boardedVehicle(step, in: journey, now: now) == nil:
            later = to + 1
        default: break
        }
        let target = NavigationEngine.targetVehicle(step)
        let live = currentBuffer?.status == .missed && (target ?? .max) <= limit
        return live || navMissedVehicles.contains { $0 >= ahead && $0 <= limit } || replanLatched.contains { $0 >= later && $0 <= limit }
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
        via = remainingVia
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
        resetReplan()
        navMissedSince = nil
        navIsStale = false
        navExpired = false
        navFocus = nil
        navMapOnly = false
    }

    /// Zwischenstopps, die die laufende Fahrt noch vor sich hat: eine Folgeverbindung behaelt sie, erreichte entfallen.
    /// Nicht erkannte Stopps entfallen auch: ob sie noch vor einem liegen, ist unbekannt, und ein besuchter Stopp kostet
    /// einen Umweg zurueck; ein fehlender laesst sich mit "+" wieder eintragen.
    private var remainingVia: [ViaStop] {
        guard let journey = navJourney else { return via }
        // Ohne Zielfahrzeug (Weg zum Ziel) liegen alle Stopps hinter einem.
        guard let target = navStep.flatMap(NavigationEngine.targetVehicle) else { return [] }
        let ahead = journey.viaStays(via).filter { $0.arrivalLeg >= target }.map(\.via)
        return via.filter(ahead.contains)
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

    /// Modus-Parameter der Anfrage: alle Pillen an = voller Nahverkehrsfilter (nil).
    private var modesParameter: [ModeFilter]? {
        modeFilter.count == ModeFilter.allCases.count ? nil : ModeFilter.allCases.filter(modeFilter.contains)
    }

    /// Anfrage der Alternativen unterwegs (Blatt "Alternativen" und Vorschlag): Ziel, Modi und Barrierefreiheit wie die
    /// laufende Fahrt, `rest` = noch offene Zwischenstopps. Start am Zwischenstopp selbst (Fahrt dorthin laeuft): der Stopp
    /// entfaellt, das Backend lehnt Start = Stopp ab; sein Aufenthalt bleibt, die Weiterfahrt beginnt erst danach.
    /// `via` = die gesendeten Stopps ("Wechseln" uebernimmt sie).
    nonisolated static func alternativesQuery(from start: TripEndpoint, at time: Date, to target: TripEndpoint, via rest: [ViaStop],
                                              modes: [ModeFilter]?, accessibility: Accessibility) -> (trip: ManualTripRequest, via: [ViaStop]) {
        let startID: String? = if case .stop(let id, _) = start { id } else { nil }
        let via = rest.filter { stop in startID.map { !stop.matches(stopID: $0) } ?? true }
        let stay = rest.filter { !via.contains($0) }.reduce(0) { $0 + $1.stayMinutes }
        let trip = ManualTripRequest(origin: start, destination: target, targetTime: time.addingTimeInterval(TimeInterval(stay * 60)),
                                     modes: modes, accessibility: accessibility, via: via.isEmpty ? nil : via)
        return (trip, via)
    }

    /// Alternativen zum Ziel; Navigation und Karte bleiben unberuehrt.
    func openAlternatives(from origin: PeekOrigin? = nil) {
        guard case .navigation = phase, let target = destination?.place else { return }
        let source = origin ?? peekOrigin
        let next = nextStation
        // Ohne Standorterlaubnis nie currentFix() anfragen (loest sonst den System-Dialog aus): dann ab der naechsten Station.
        peekOrigin = (source == .nextStation || !locationAllowed) && next != nil ? .nextStation : .position
        peekSearch = nil
        guard peekOrigin == .nextStation || locationAllowed else { peek = .failed(.locationDenied); return }
        peekTask?.cancel()
        peek = .loading
        let now = deps.now()
        let pace = self.pace
        let useNext = peekOrigin == .nextStation
        let rest = remainingVia
        let modes = modesParameter
        let accessibility = self.accessibility
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
                let query = Self.alternativesQuery(from: start, at: time, to: target, via: rest, modes: modes, accessibility: accessibility)
                for try await stage in deps.planner.plan(query.trip, pace: pace) {
                    guard !Task.isCancelled else { return }
                    switch stage {
                    case .skeleton(let r): peek = .loaded(r, nil, via: query.via)
                    case .calibrated(let r, let c): peek = .loaded(r, c, via: query.via)
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
                                 modes: modesParameter,
                                 accessibility: accessibility, via: via.isEmpty ? nil : via)
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
        via = reminder.request.via ?? []
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
        via = reminder.request.via ?? []
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
        peekSearch = nil
    }

    /// Wo die Alternativen im Blatt starten (Hinweis unter dem Umschalter): Suchstart des Vorschlags, sonst naechste Station.
    var peekStart: (name: String, time: Date)? {
        if let search = peekSearch { return (search.start.label, search.time) }
        return nextStation.map { ($0.name, $0.time) }
    }

    /// Wechsel auf eine Alternative: ersetzt die laufende Verbindung. Startet sie an der naechsten Station (bzw. am Suchstart
    /// des Vorschlags), waehrend man noch im Fahrzeug sitzt, wird der Wechsel wie ein uebernommener Vorschlag vorgemerkt
    /// (SPEZIFIKATION 4.4).
    func chooseAlternative(_ index: Int) {
        guard case .loaded(let response, let walks, let peekVia) = peek, index < response.journeys.count else { return }
        let now = deps.now()
        // Noch ohne Gehzeiten (`.skeleton`): mit den Fahrplanzeiten und dem Gehtempo vormerken, die Pruefung am Suchstart
        // rechnet ebenso.
        let calibrated = walks ?? response.journeys.map { CalibratedJourney(timetable: $0, pace: pace) }
        if peekOrigin == .nextStation, calibrated.indices.contains(index), let journey = navJourney, let step = navStep,
           let search = peekSearch.flatMap({ now < $0.time ? $0 : nil }) ?? ConnectionWatch.chosenSwitch(journey: journey, step: step, now: now, pace: pace) {
            closeAlternatives()
            reserveSwitch(ReplanOffer(proposal: ReplanProposal(id: UUID(), search: search, alternativeIndex: index),
                                      answer: ReplanAnswer(search: search, response: response, calibrated: calibrated, via: peekVia)))
            return
        }
        switchJourney(to: response, calibrated: walks, via: peekVia, index: index)
    }

    /// Gewaehlt im Blatt: dieselbe Fahrt, auch wenn sich die Liste seit dem Antippen geaendert hat.
    func chooseAlternative(_ journey: Journey) {
        guard case .loaded(let response, _, _) = peek,
              let index = response.journeys.firstIndex(where: { $0.isSameTrip(as: journey) }) else { return }
        chooseAlternative(index)
    }

    /// Startet eine andere Verbindung aus der Fahrt heraus (Blatt "Alternativen" oder vorgemerkter Wechsel).
    private func switchJourney(to response: RoutesResponse, calibrated walks: [CalibratedJourney]?, via newVia: [ViaStop], index: Int) {
        via = newVia
        routes = response
        calibrated = walks
        attribution = response.attribution
        isStale = false
        closeAlternatives()
        // Wie "Naechste Verbindung": startet eine andere Fahrt, endet der Wecker der laufenden.
        replacedReminder = navJourney.flatMap(reminders.reminder(for:))?.id
        send(.startNavigation(index))
    }

    // MARK: Proaktive Umplanung (SPEZIFIKATION 4.4)

    /// Einmal am Ende jedes Navigations-Ticks (nach Refresh und Position): vorgemerkten Wechsel am Suchstart ausfuehren,
    /// sonst einrasten, Verfall pruefen und die naechste Suche starten oder eine gemerkte Antwort zeigen.
    /// Die Regeln stehen in `ConnectionWatch` und `ReplanMemory`; hier nur Zustand und Netz.
    private func evaluateReplan(now: Date) {
        guard case .navigation = phase, let journey = navJourney, let step = navStep, step != .arrived else { return }
        if replanExpired != nil, now >= replanExpiredUntil { replanExpired = nil }
        let result = ConnectionWatch.evaluate(journey: journey, step: step, latched: replanLatched, walks: navWalks, now: now, pace: pace)
        replanLatched = result.latched
        replanSearches = result.searches
        for v in result.latched where latchedAt[v] == nil { latchedAt[v] = now }
        latchedAt = latchedAt.filter { result.latched.contains($0.key) }
        // Betroffen: eingerastet ohne abgelehnte (auch nach dem Aussteigen, wenn es keine Suchen mehr gibt), und per Position
        // verpasste immer: Ablehnen galt der Echtzeit-Lage, nicht dem tatsaechlich verpassten Fahrzeug.
        // Bis zum Ausstiegsfahrzeug eines Vorschlags oder einer Vormerkung laeuft alles wie sonst; bricht dort etwas weg,
        // entfallen sie (`ConnectionWatch.isUndercut`).
        let affected = result.latched.subtracting(ConnectionWatch.declined(result.latched, memory: replanMemory, journey: journey,
                                                                           walks: navWalks, now: now, pace: pace)).union(navMissedVehicles)
        if let pending = pendingSwitch {
            switch ConnectionWatch.pendingSwitch(pending.proposal.search, journey: journey, step: step, affected: affected,
                                                 fix: navFix, now: now) {
            case .wait: return
            case .start(let arrival):
                if switchTask == nil { startSwitch(pending, from: journey, arrival: arrival) }
                return
            case .drop: pendingSwitch = nil
            }
        }
        // Haptik einmal je Anschluss (bestehend), aus demselben Einrasten wie Vorschlag und Live Activity.
        if !result.latched.isSubset(of: warnedVehicles) {
            warnedVehicles.formUnion(result.latched)
            navWarnings += 1
        }
        // Verfall mit Hysterese: der Ausloeser bleibt aktiv, bis der Puffer wieder `minimumSlackSeconds` erreicht. Je Tick mit
        // der aktuellen Suchzeit geprueft; dieselbe ID (keine zweite Mitteilung), die bisherige Alternative bleibt, solange sie
        // erreichbar ist.
        if let offer = replanOffer {
            let live = result.searches.first { $0.key == offer.proposal.search.key }
            if let live, ConnectionWatch.isValid(offer.proposal, current: result.searches, now: now),
               !ConnectionWatch.isUndercut(live, affected: affected, journey: journey, step: step),
               let index = ConnectionWatch.pick(offer.answer.calibrated, for: live, keeping: offer.proposal.alternativeIndex) {
                let proposal = ReplanProposal(id: offer.proposal.id, search: live, alternativeIndex: index)
                if proposal != offer.proposal { replanOffer = ReplanOffer(proposal: proposal, answer: offer.answer) }
            } else {
                // Verfall: der Anschluss reicht wieder (eingerastet bis `minimumSlackSeconds`), kurzer Hinweis. Andere Enden
                // (Suchstart erreicht, Alternative nicht mehr erreichbar, frueheres Fahrzeug betroffen) bleiben still.
                let vehicle = offer.proposal.search.trigger.vehicle
                if !result.latched.contains(vehicle) {
                    let line = journey.legs.first { $0.index == vehicle }?.badgeText ?? ""
                    replanExpired = String(localized: "Anschluss \(line) reicht wieder")
                    replanExpiredUntil = now.addingTimeInterval(Self.replanNoticeSeconds)
                }
                replanOffer = nil
            }
        }
        // Solange ein Vorschlag steht, keine Suche: ihre Antwort koennte ihn nicht ersetzen.
        guard replanTask == nil, replanOffer == nil else { return }
        if blockedUntil == nil, !navExpired, let search = replanMemory.next(in: result.searches, now: now) {
            startReplanSearch(search, journey: journey)
        } else {
            proposeFromAnswer(now: now)
        }
    }

    /// Suche ab dem Ausstiegshalt zur Echtzeit-Ankunft, Anfrage wie im Blatt "Alternativen"; Stopps ab dem Fahrzeug vor dem
    /// betroffenen. Der Schluessel wird synchron vor dem Task markiert: ein zweiter Tick startet keine zweite Suche.
    private func startReplanSearch(_ search: ReplanSearch, journey: Journey) {
        guard let target = destination?.place else { return }
        replanMemory.markSearched(search)
        let rest = ConnectionWatch.remainingVia(via, in: journey, alightingVehicle: search.alightingVehicle)
        let query = Self.alternativesQuery(from: search.start, at: search.time, to: target, via: rest,
                                           modes: modesParameter, accessibility: accessibility)
        let pace = self.pace
        replanTask = Task {
            do {
                var answer: ReplanAnswer?
                for try await stage in deps.planner.plan(query.trip, pace: pace) {
                    if case .calibrated(let r, let c) = stage {
                        answer = ReplanAnswer(search: search, response: r, calibrated: c, via: query.via)
                    }
                }
                guard let answer else { throw TransitError.internal }
                guard !Task.isCancelled else { return }
                replanTask = nil
                // Nur fuer dieselbe Fahrt; Schluessel, Ausloeser und Zeit prueft `proposeFromAnswer`.
                guard case .navigation = phase, navJourney?.isSameTrip(as: journey) == true else { return }
                replanAnswers[search.key] = answer
                proposeFromAnswer(now: deps.now())
            } catch {
                // Still (kein Banner): Wiederholung nach `retryDelay` oder Retry-After, hoechstens `maxFailures`.
                // Der Task bleibt bis nach dem Warten eingetragen, damit `resetReplan` ihn noch abbrechen kann.
                let blocked = await deps.blockedUntil()
                guard !Task.isCancelled else { return }
                replanTask = nil
                guard case .navigation = phase, navJourney?.isSameTrip(as: journey) == true else { return }
                replanMemory.markFailed(search, now: deps.now(), blockedUntil: blocked)
            }
        }
    }

    /// Zeigt die Antwort zum gerade behandelten Ausloeser (dem ersten nicht abgelehnten), solange er aktiv ist, der Suchstart
    /// nicht erreicht und eine Alternative erreichbar ist (beste nach Rang). Ohne erreichbare Alternative kein Vorschlag:
    /// zaehlt als abgelehnt, damit das naechste Fahrzeug drankommt; der Hinweis "reicht nicht" bleibt.
    private func proposeFromAnswer(now: Date) {
        guard pendingSwitch == nil, replanOffer == nil,
              let live = replanSearches.first(where: { !replanMemory.isDeclined($0) }),
              let answer = replanAnswers[live.key], now < live.time else { return }
        if let index = ConnectionWatch.pick(answer.calibrated, for: live, keeping: nil) {
            replanOffer = ReplanOffer(proposal: ReplanProposal(id: UUID(), search: live, alternativeIndex: index), answer: answer)
            record([CaseTrigger.replanLate(bufferSeconds: live.bufferSeconds,
                                           delaySeconds: Int(now.timeIntervalSince(latchedAt[live.trigger.vehicle] ?? now)),
                                           now: now, near: live.startCoordinate)])
            latchedAt[live.trigger.vehicle] = nil // naechster Vorschlag zum selben Anschluss misst neu
        } else {
            replanMemory.decline(live)
        }
    }

    /// "Uebernehmen": Wechsel vormerken. Die laufende Navigation (Zug, Ausstiegshinweis, Refresh) bleibt bis zum Suchstart.
    func acceptReplan(_ id: UUID) {
        guard let offer = liveOffer(id) else { return }
        reserveSwitch(offer)
    }

    /// "Alternativen ansehen" (Banner und Tipp auf die Mitteilung): Blatt mit der Antwort des Vorschlags, ohne neue Suche.
    func showProposal(_ id: UUID) {
        guard let offer = liveOffer(id) else { return }
        peekTask?.cancel()
        peekTask = nil
        peekOrigin = .nextStation
        peekSearch = offer.proposal.search
        peek = .loaded(offer.answer.response, offer.answer.calibrated, via: offer.answer.via)
    }

    /// Der Vorschlag mit dieser ID, wenn er noch gilt: Phase `.navigation`, aktueller Vorschlag, Suchstart nicht erreicht.
    /// Nie fuer eine fremde oder beendete Fahrt (Mitteilung aus einer frueheren Fahrt traegt eine andere zufaellige ID).
    private func liveOffer(_ id: UUID) -> ReplanOffer? {
        guard case .navigation = phase, let offer = replanOffer, offer.proposal.id == id,
              ConnectionWatch.isValid(offer.proposal, current: replanSearches, now: deps.now()) else { return nil }
        return offer
    }

    /// Was die Jetzt-Karte zur Umplanung zeigt; vorgemerkt geht vor Vorschlag, der vor dem Hinweis nach Verfall.
    var replanBanner: ReplanBanner? {
        if let pending = pendingSwitch {
            let text = Self.switchLine(pending).map { String(localized: "Wechsel auf \($0) vorgemerkt") } ?? String(localized: "Wechsel vorgemerkt")
            return .reserved(text, alighting: pending.proposal.search.alightingVehicle)
        }
        if let offer = replanOffer, let journey = navJourney {
            let texts = Self.replanTexts(offer, in: journey)
            return .offer(id: offer.proposal.id, title: texts.title, body: texts.body)
        }
        return replanExpired.map(ReplanBanner.expired)
    }

    /// Linie der vorgemerkten bzw. vorgeschlagenen Alternative (erstes Fahrzeug).
    nonisolated private static func switchLine(_ offer: ReplanOffer) -> String? {
        offer.answer.calibrated[safe: offer.proposal.alternativeIndex]?.journey.legs.first { !$0.isWalk }?.badgeText
    }

    /// Banner und Mitteilung, eine Regel: betroffene Linie, dann der beste Vorschlag mit Linie, Abfahrt, Halt und Gleis eines
    /// Halts (`ReminderText.departure`: nur Fahrplandaten, kein Ausstiegshalt, nie Adresse oder Position; Sperrbildschirm),
    /// dazu die Ankunft (an das Gehtempo angepasst) und wie viel spaeter als die laufende Fahrt, nur als Uhrzeit.
    nonisolated static func replanTexts(_ offer: ReplanOffer, in journey: Journey) -> (title: String, body: String) {
        let line = journey.legs.first { $0.index == offer.proposal.search.trigger.vehicle }?.badgeText ?? ""
        let title = if case .tripCancelled = offer.proposal.search.trigger {
            String(localized: "Anschluss \(line) fällt aus")
        } else {
            String(localized: "Anschluss \(line) reicht nicht mehr")
        }
        guard let best = offer.answer.calibrated[safe: offer.proposal.alternativeIndex] else { return (title, "") }
        let proposal = String(localized: "Vorschlag: \(ReminderText.departure(best.journey))")
        guard let arrival = best.arrivalAtDestination ?? best.journey.arrival else { return (title, proposal) }
        let later = journey.arrival.map { Int((arrival.timeIntervalSince($0) / 60).rounded()) } ?? 0
        let time = later > 0 ? String(localized: "Ankunft \(arrival.clockText) (+\(later) Min.)")
            : String(localized: "Ankunft \(arrival.clockText)")
        return (title, "\(proposal), \(time)")
    }

    /// Mitteilung folgt dem Vorschlag (ohne ihn dem Hinweis nach gescheitertem Wechsel): im Hintergrund eine mit Ton je
    /// Vorschlag; aendert sich nur der Text desselben Vorschlags, wird sie still ersetzt. Weg, sobald nichts mehr gilt (Verfall,
    /// Uebernehmen, Behalten, Ankunft, Beenden). Nacheinander, damit ein Entfernen kein Senden ueberholt.
    private func syncReplanAlert() {
        var desired = replanNotice
        if let offer = replanOffer, let journey = navJourney {
            let texts = Self.replanTexts(offer, in: journey)
            desired = ReplanAlert(proposalID: offer.proposal.id, title: texts.title, body: texts.body)
        }
        guard desired != postedAlert else { return }
        let update = postedAlert?.proposalID != nil && desired?.proposalID == postedAlert?.proposalID
        let post = desired.flatMap { inBackground || update ? $0 : nil }
        let remove = postedAlert != nil && post == nil
        guard post != nil || remove else { return }
        postedAlert = post
        let notifier = deps.replanNotifier
        let previous = replanAlertTask
        replanAlertTask = Task {
            await previous?.value
            if remove { notifier.remove([ReplanAlert.identifier]) }
            if let post { await notifier.post(post, alerting: !update) }
        }
    }

    /// Wechsel vormerken ("Uebernehmen" oder "Wechseln" ab der naechsten Station); laufende Suche und Vorschlag entfallen.
    private func reserveSwitch(_ offer: ReplanOffer) {
        replanTask?.cancel()
        replanTask = nil
        replanOffer = nil
        pendingSwitch = offer
        syncActivities()
    }

    /// "Behalten": Fahrt unveraendert; gemerkt wird das Fahrzeug mit dem Puffer von jetzt (neu erst 5 Min. schlechter).
    /// Auch Wischen der Mitteilung (`customDismissAction`); wie jeder Tipp nur zum laufenden, noch gueltigen Vorschlag.
    func declineReplan(_ id: UUID) {
        guard let offer = liveOffer(id) else { return }
        replanMemory.decline(replanSearches.first { $0.key == offer.proposal.search.key } ?? offer.proposal.search)
        replanOffer = nil
    }

    /// Am Suchstart: Alternative mit frischem Refresh pruefen (bis dahin ohne Echtzeit) und starten. Ohne Refresh (offline,
    /// Fehler, Rate-Limit-Sperre) zaehlt der gemerkte Stand; eine neue Sperre (Retry-After) gilt danach fuer alle Anfragen.
    /// Reicht sie nicht mehr: kurzer Hinweis (im Hintergrund als Mitteilung), die laufende Fahrt bleibt mit "reicht nicht".
    private func startSwitch(_ pending: ReplanOffer, from journey: Journey, arrival: Date) {
        guard let chosen = pending.answer.calibrated[safe: pending.proposal.alternativeIndex] else {
            pendingSwitch = nil
            return
        }
        // Reiner Fussweg: keine Echtzeit, die ein Refresh aendern koennte.
        let token = blockedUntil == nil && !chosen.journey.isWalkOnly ? chosen.journey.refreshToken : nil
        switchTask = Task {
            var fresh = chosen
            if let token {
                do throws(TransitError) {
                    fresh = chosen.replacingJourney(try await deps.refresh(token))
                } catch {
                    if let until = await deps.blockedUntil(), until > deps.now() { block(until: until) }
                }
            }
            guard !Task.isCancelled else { return }
            switchTask = nil
            guard case .navigation = phase, pendingSwitch?.proposal.id == pending.proposal.id,
                  navJourney?.isSameTrip(as: journey) == true else { return }
            // Neuer Fix waehrend des Refresh fern vom Suchstart: wie im Tick warten (noch im Ausstiegsfahrzeug) oder still verwerfen.
            if let step = navStep,
               let away = ConnectionWatch.awayFromStart(pending.proposal.search, step: step, fix: navFix, now: deps.now()) {
                if away == .drop { pendingSwitch = nil }
                return
            }
            pendingSwitch = nil
            // Spaeter Tick oder langsamer Refresh: ab jetzt muss die Alternative noch erreichbar sein, nicht ab der Ankunft
            // (Weiterfahrt im selben Zug: ab der Ankunft).
            guard ConnectionWatch.pick([fresh], for: pending.proposal.search.at(arrival: arrival, now: deps.now()), keeping: nil) != nil else {
                let text = Self.switchLine(pending).map { String(localized: "Wechsel auf \($0) nicht mehr möglich") }
                    ?? String(localized: "Wechsel nicht mehr möglich")
                replanExpired = text
                replanExpiredUntil = deps.now().addingTimeInterval(Self.replanNoticeSeconds)
                if inBackground {
                    replanNotice = ReplanAlert(proposalID: nil, title: text, body: "")
                    syncReplanAlert()
                }
                syncActivities()
                return
            }
            switchJourney(to: .single(fresh.journey, fetchedAt: deps.now(), attribution: pending.answer.response.attribution),
                          calibrated: [fresh], via: pending.answer.via, index: 0)
        }
    }

    /// Mit Beginn, Ende und Ankunft der Navigation: Vorschlag, Gedaechtnis, Einrasten und Wechsel verwerfen.
    private func resetReplan() {
        replanTask?.cancel()
        replanTask = nil
        replanNotice = nil
        replanOffer = nil
        pendingSwitch = nil
        replanExpired = nil
        replanAnswers = [:]
        replanMemory = ReplanMemory()
        replanLatched = []
        latchedAt = [:]
        replanSearches = []
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

    /// Wartet auf Suche und Wechsel der proaktiven Umplanung.
    func waitForReplan() async {
        await replanTask?.value
        await switchTask?.value
        await replanAlertTask?.value
    }
    #endif
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
