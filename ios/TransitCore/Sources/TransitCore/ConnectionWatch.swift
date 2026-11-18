import Foundation

/// Warum unterwegs umgeplant werden soll (SPEZIFIKATION 4.4). `vehicle` ist der betroffene Leg-Index.
public enum ReplanTrigger: Sendable, Hashable {
    /// Der Anschluss reicht nach Echtzeit nicht mehr (Puffer 0 s oder weniger).
    case connectionBroken(vehicle: Int)
    /// Das spaetere Fahrzeug faellt aus.
    case tripCancelled(vehicle: Int)
    /// "Wechseln" aus dem Blatt "Alternativen" mit Start an der naechsten Station; `vehicle` ist hier das Ausstiegsfahrzeug.
    case chosen(vehicle: Int)

    public var vehicle: Int {
        switch self {
        case .connectionBroken(let v), .tripCancelled(let v), .chosen(let v): v
        }
    }
}

/// Ein Fahrzeug: Fahrt-ID, sonst Linie, Plan-Abfahrt und Name des Einstiegshalts (ohne Namen dessen ID). Dasselbe Fahrzeug,
/// derselbe Schluessel. Gespeichert wird je Fahrt; die Fahrt-Identitaet liegt beim Aufrufer (Gedaechtnis und Einrasten enden
/// mit der Navigation). Ein Gleiswechsel macht aus derselben Fahrt kein neues Fahrzeug: mit Fahrt-ID ohnehin nicht, ohne sie,
/// solange der Haltname gleich bleibt (MOTIS liefert je Bahnsteig eine eigene ID, aber den Namen der Station).
/// `matches` gilt fuer die Weiterfahrt nur mit Fahrt-ID auf beiden Seiten; ohne sie braucht auch die Weiterfahrt Gehweg und Puffer.
public struct ReplanKey: Sendable, Hashable {
    public let vehicle: String
    private let tripId: String?
    private let fallback: String
    /// Ersatzschluessel mit der Halt-ID statt des Namens: `matches` laesst beide gelten (lieber ein Fahrzeug zu oft ausschliessen).
    private let fallbackID: String

    init(_ leg: Leg) {
        tripId = leg.tripId
        let base = "\(leg.line?.name ?? leg.mode.rawValue)@\((leg.plannedDeparture ?? leg.departure)?.timeIntervalSince1970 ?? 0)@"
        fallback = base + (leg.origin.name ?? leg.origin.id ?? "")
        fallbackID = base + (leg.origin.id ?? leg.origin.name ?? "")
        vehicle = leg.tripId ?? fallback
    }

    /// Kein betroffenes Fahrzeug (Wechsel aus dem Blatt): passt auf kein Leg, der Ersatzschluessel eines Legs ist nie leer.
    private init() {
        tripId = nil
        fallback = ""
        fallbackID = ""
        vehicle = ""
    }
    static let noVehicle = ReplanKey()

    public static func == (a: ReplanKey, b: ReplanKey) -> Bool { a.vehicle == b.vehicle }
    public func hash(into h: inout Hasher) { h.combine(vehicle) }

    /// Dasselbe Fahrzeug: Fahrt-ID, wenn beide Seiten eine haben, sonst der Ersatzschluessel (Haltname oder Halt-ID).
    func matches(_ leg: Leg) -> Bool {
        if let tripId, let other = leg.tripId { return tripId == other }
        let other = ReplanKey(leg)
        return fallback == other.fallback || fallbackID == other.fallbackID
    }
}

/// Woher und wann gesucht wird: vom Ausstiegshalt des Fahrzeugs vor dem betroffenen, zur Echtzeit-Ankunft dort.
public struct ReplanSearch: Sendable, Hashable {
    public let trigger: ReplanTrigger
    public let key: ReplanKey
    /// Fahrzeug, in dem man bis zum Suchstart sitzt, und sein Schluessel (Weiterfahrt im selben Zug ist erlaubt).
    public let alightingVehicle: Int
    public let alightingKey: ReplanKey
    public let start: TripEndpoint
    /// Lage des Suchstarts (Halt aus der Fahrt), fuer den Abgleich mit dem ersten Halt einer Alternative.
    public let startCoordinate: GeoCoordinate?
    public let time: Date
    /// Puffer des betroffenen Anschlusses in s; `ConnectionWatch.cancelledBuffer` bei Ausfall.
    public let bufferSeconds: Int
    /// Gehtempo fuer den Weg vom Suchstart zum ersten Halt einer Alternative ohne eigenen Fussweg-Abschnitt.
    public let pace: WalkingPaceFactor

    /// Dieselbe Suche zur aktuellen Echtzeit-Ankunft am Suchstart (Pruefung der vorgemerkten Alternative beim Wechsel).
    public func at(_ time: Date) -> ReplanSearch {
        ReplanSearch(trigger: trigger, key: key, alightingVehicle: alightingVehicle, alightingKey: alightingKey,
                     start: start, startCoordinate: startCoordinate, time: time, bufferSeconds: bufferSeconds, pace: pace)
    }
}

/// Vorschlag fuer den Nutzer: die Suche und der Index der gewaehlten Alternative in der Antwort (die liegt in der App).
/// `id` ist zufaellig und steckt in der Mitteilung, damit ein Tipp nur zum aktuellen Vorschlag passt.
public struct ReplanProposal: Sendable, Hashable {
    public let id: UUID
    public let search: ReplanSearch
    public let alternativeIndex: Int

    public init(id: UUID, search: ReplanSearch, alternativeIndex: Int) {
        self.id = id
        self.search = search
        self.alternativeIndex = alternativeIndex
    }
}

/// Was mit einem vorgemerkten Wechsel jetzt geschieht (`ConnectionWatch.pendingSwitch`).
public enum PendingSwitchStep: Sendable, Equatable {
    case wait
    /// Am Suchstart angekommen (Echtzeit-Ankunft des Ausstiegsfahrzeugs): Alternative pruefen und starten.
    case start(arrival: Date)
    /// Suchstart nicht mehr sicher erreichbar oder schon vorbei: Vormerkung verwerfen, die Fahrt laeuft normal weiter.
    case drop
}

/// Reine Regeln der proaktiven Umplanung: keine Uhr, kein Netz, keine UI (`now` kommt als Parameter).
public enum ConnectionWatch {
    /// Eine neue Suche zum selben Fahrzeug erst, wenn der Puffer so viel schlechter ist (s).
    public static let worseningSeconds = 300
    /// Hoechstens so viele erfolgreiche Suchen je Fahrt.
    public static let maxSearches = 3
    /// Hoechstens so viele gescheiterte Suchen je Fahrt, danach Ruhe (Transitous wird ehrenamtlich betrieben).
    public static let maxFailures = 3
    /// Mindestwartezeit nach einer gescheiterten Suche (s).
    public static let retryDelay: TimeInterval = 60
    /// Puffer eines ausgefallenen Fahrzeugs: schlechter als jede Verspaetung, aber ohne Ueberlauf beim Vergleich.
    public static let cancelledBuffer = -86_400
    /// Erster Halt einer Alternative ohne passende ID gilt bis zu dieser Entfernung vom Suchstart als derselbe Halt (m),
    /// wie bei den Zwischenstopps (`Journey.viaStays`).
    public static let sameStopMeters: Double = 300

    /// Fahrzeug, in dem man bis zum Suchstart sitzt: `onBoardTransit` oder die 120 s vor dem Ausstieg. Am Gleis, beim Gehen
    /// und nach dem Ausstieg nil (dort gilt der bestehende Ablauf).
    public static func boardedVehicle(_ step: NavigationStep, in journey: Journey, now: Date) -> Int? {
        switch step {
        case .onBoardTransit(let v): return v
        case .transferRouting(let from, _):
            guard let leg = journey.legs.first(where: { $0.index == from }),
                  let arrival = leg.arrival ?? leg.plannedArrival, now < arrival else { return nil }
            return from
        default: return nil
        }
    }

    /// Ein Auswertungsschritt: neuer Anschlussbruch oder Ausfall rastet ein (Puffer-Zittern um 0 s schaltet nicht um) und
    /// faellt erst, wenn der Anschluss mit mindestens `TransferCheck.minimumSlackSeconds` wieder erreichbar ist.
    /// Alle betroffenen Fahrzeuge, frueheste zuerst: lehnt der Nutzer das erste ab, bleibt das zweite sichtbar.
    /// Gesucht wird nur im Fahrzeug (`boardedVehicle`). Auf dem Umstiegsweg und am Gleis rasten spaetere Anschluesse weiter
    /// ein und frei (Live-Activity-Problem "Anschluss"), ohne Suche. `latched` gehoert dem Aufrufer (RAM).
    public static func evaluate(journey: Journey, step: NavigationStep, latched: Set<Int>, walks: [Int: WalkEstimate],
                                now: Date, pace: WalkingPaceFactor) -> (searches: [ReplanSearch], latched: Set<Int>) {
        let boarded = boardedVehicle(step, in: journey, now: now)
        let anchor: Int? = switch step {
        case .transferRouting(_, let to): boarded ?? to
        case .waitingAtPlatform(let v): v
        default: boarded
        }
        guard let last = anchor else { return ([], latched) }
        var latched = latched
        let vehicles = journey.legs.filter { !$0.isWalk }
        if let broken = NavigationEngine.brokenConnection(after: last, journey: journey, walks: walks, now: now, pace: pace) {
            latched.insert(broken)
        }
        for leg in vehicles where leg.index > last && leg.cancelled { latched.insert(leg.index) }
        var searches: [ReplanSearch] = []
        for index in latched.filter({ $0 > last }).sorted() {
            // erreichbar mit Reserve, oder ohne Abfahrtszeit nicht beurteilbar: freigeben
            guard let affected = vehicles.first(where: { $0.index == index }),
                  let buffer = buffer(of: affected, journey: journey, walks: walks, now: now, pace: pace),
                  buffer < TransferCheck.minimumSlackSeconds else { latched.remove(index); continue }
            if boarded != nil, let before = vehicles.last(where: { $0.index < index }),
               let search = search(before: before, affected: affected, buffer: buffer, now: now, pace: pace) {
                searches.append(search)
            }
        }
        return (searches, latched)
    }

    /// Puffer zu einem Fahrzeug ohne Position (s), fuer Einrasten und Ablehnen: Ausfall = `cancelledBuffer`, ohne
    /// Abfahrtszeit nil.
    private static func buffer(of leg: Leg, journey: Journey, walks: [Int: WalkEstimate], now: Date, pace: WalkingPaceFactor) -> Int? {
        leg.cancelled ? cancelledBuffer
            : NavigationEngine.buffer(journey: journey, vehicle: leg.index, walks: walks, position: nil, now: now, pace: pace)?.seconds
    }

    /// Welche dieser Fahrzeuge der Nutzer behalten hat ("Behalten" oder Suche ohne Alternative), mit derselben Regel wie fuer
    /// die Suchen (`ReplanMemory.isDeclined`, neu erst 5 Min. schlechter). Unabhaengig von den Suchen: nach dem Aussteigen
    /// gibt es keine mehr, die Ablehnung gilt weiter. Ohne Abfahrtszeit zaehlt als nicht schlechter.
    public static func declined(_ vehicles: Set<Int>, memory: ReplanMemory, journey: Journey, walks: [Int: WalkEstimate],
                                now: Date, pace: WalkingPaceFactor) -> Set<Int> {
        Set(journey.legs.filter { leg in
            !leg.isWalk && vehicles.contains(leg.index)
                && memory.isDeclined(ReplanKey(leg), bufferSeconds: buffer(of: leg, journey: journey, walks: walks, now: now, pace: pace) ?? .max)
        }.map(\.index))
    }

    /// "Wechseln" aus dem Blatt mit Start an der naechsten Station, waehrend man noch im Fahrzeug sitzt: wird wie ein
    /// uebernommener Vorschlag vorgemerkt und am Ausstieg mit `pick` geprueft. Ohne betroffenes Fahrzeug. Sonst nil.
    public static func chosenSwitch(journey: Journey, step: NavigationStep, now: Date, pace: WalkingPaceFactor) -> ReplanSearch? {
        guard let v = boardedVehicle(step, in: journey, now: now),
              let leg = journey.legs.first(where: { $0.index == v }), let start = endpoint(leg.destination) else { return nil }
        return ReplanSearch(trigger: .chosen(vehicle: v), key: .noVehicle, alightingVehicle: v, alightingKey: ReplanKey(leg),
                            start: start, startCoordinate: leg.destination.coordinate,
                            time: max(now, leg.arrival ?? leg.plannedArrival ?? now), bufferSeconds: 0, pace: pace)
    }

    private static func endpoint(_ place: Place) -> TripEndpoint? {
        if let id = place.id { return .stop(id: id, label: place.name ?? "") }
        return place.coordinate.map { .coordinate($0, label: place.name ?? "") }
    }

    private static func search(before: Leg, affected: Leg, buffer: Int, now: Date, pace: WalkingPaceFactor) -> ReplanSearch? {
        guard let start = endpoint(before.destination) else { return nil }
        let trigger: ReplanTrigger = affected.cancelled ? .tripCancelled(vehicle: affected.index) : .connectionBroken(vehicle: affected.index)
        return ReplanSearch(trigger: trigger, key: ReplanKey(affected), alightingVehicle: before.index, alightingKey: ReplanKey(before),
                            start: start, startCoordinate: before.destination.coordinate,
                            time: max(now, before.arrival ?? before.plannedArrival ?? now), bufferSeconds: buffer, pace: pace)
    }

    /// Beste erreichbare Alternative nach der bestehenden Rangfolge (Ankunft, Umstiege, Gehzeit, Strafen); Index in `alternatives`.
    /// `keeping`: die bisher vorgeschlagene bleibt, solange sie erreichbar ist (kein Hin und Her, keine zweite Mitteilung).
    public static func pick(_ alternatives: [CalibratedJourney], for search: ReplanSearch, keeping current: Int? = nil) -> Int? {
        if let current, alternatives.indices.contains(current), isReachable(alternatives[current], for: search) { return current }
        let reachable = alternatives.indices.filter { isReachable(alternatives[$0], for: search) }
        return reachable.min { alternatives[$0].rank(arrivalSearch: false) < alternatives[$1].rank(arrivalSearch: false) }
    }

    /// Erreichbar heisst: beginnt am Suchstart, ohne das betroffene Fahrzeug, ohne Ausfall, kein Umstieg verpasst, und die erste
    /// Abfahrt fruehestens Suchzeit + Gehweg am Start + `minimumSlackSeconds` (MOTIS liefert Abfahrten ohne Umstiegszeit, live
    /// geprueft 18.11.). Ausnahme: faehrt man im selben Zug weiter (erstes Fahrzeug = Ausstiegsfahrzeug), zaehlt nur die Abfahrt
    /// nach der Ankunft. Ohne Fussweg-Abschnitt am Anfang zaehlt bei anderer Halt-ID die Luftlinie vom Suchstart mit Gehtempo.
    static func isReachable(_ alt: CalibratedJourney, for search: ReplanSearch) -> Bool {
        let vehicles = alt.journey.legs.filter { !$0.isWalk }
        guard !alt.journey.cancelled, let first = vehicles.first, startsAtSearchStart(alt.journey, search),
              !vehicles.contains(where: { $0.cancelled || search.key.matches($0) }),
              !alt.transfers.contains(where: { $0.status == .missed }),
              let departure = first.departure ?? first.plannedDeparture else { return false }
        if search.alightingKey.matches(first), alt.journey.legs.first?.isWalk == false { return departure >= search.time }
        let access = alt.journey.legs.first.flatMap { $0.isWalk ? (alt.walks[$0.index]?.seconds ?? $0.durationSeconds) : nil }
            ?? accessSeconds(to: first.origin, for: search)
        return departure >= search.time.addingTimeInterval(TimeInterval(access + TransferCheck.minimumSlackSeconds))
    }

    /// Weg vom Suchstart zum ersten Halt ohne Fussweg-Abschnitt: gleiche Halt-ID 0 s, sonst Luftlinie (anderer Bahnsteig,
    /// Halt in der Naehe) mit Gehtempo; ohne Koordinaten 0 s.
    private static func accessSeconds(to origin: Place, for search: ReplanSearch) -> Int {
        if case .stop(let id, _) = search.start, origin.id == id { return 0 }
        guard let a = origin.coordinate, let b = search.startCoordinate else { return 0 }
        return search.pace.apply(to: a.distance(to: b) / NavigationEngine.defaultWalkSpeed)
    }

    /// Beginnt die Alternative dort, wo der Nutzer aussteigt? Gleiche Stop-ID, ein Bahnsteig derselben Station ("<id>:…",
    /// auch umgekehrt; MOTIS liefert am Start oft einen anderen Bahnsteig) oder hoechstens `sameStopMeters` entfernt.
    static func startsAtSearchStart(_ journey: Journey, _ search: ReplanSearch) -> Bool {
        guard let origin = journey.legs.first?.origin else { return false }
        if case .stop(let id, _) = search.start, let other = origin.id,
           other == id || other.hasPrefix(id + ":") || id.hasPrefix(other + ":") { return true }
        guard let a = origin.coordinate, let b = search.startCoordinate else { return false }
        return a.distance(to: b) <= sameStopMeters
    }

    /// Vorschlag und Vormerkung haengen am Ausstiegsfahrzeug: bis dorthin laeuft die Fahrt normal weiter und wird normal
    /// ausgewertet. Faellt dort etwas weg, ist der Suchstart nicht mehr sicher erreichbar: ein Fahrzeug ab dem naechsten bis zum
    /// Ausstiegsfahrzeug ist in `affected` (eingerastet oder verpasst, nicht abgelehnt), faellt aus oder wird verpasst.
    public static func isUndercut(_ search: ReplanSearch, affected: Set<Int>, journey: Journey, step: NavigationStep) -> Bool {
        let first: Int? = if case .onBoardTransit(let v) = step { v + 1 } else { NavigationEngine.targetVehicle(step) }
        guard let first else { return false }
        let ahead = { (i: Int) in i >= first && i <= search.alightingVehicle }
        if case .missedDeparture(let v) = step, ahead(v) { return true }
        return affected.contains(where: ahead) || journey.legs.contains { !$0.isWalk && $0.cancelled && ahead($0.index) }
    }

    /// Vorgemerkter Wechsel: gestartet wird am Suchstart und ab der Echtzeit-Ankunft des Ausstiegsfahrzeugs, nie nach der Uhr
    /// allein. Am Suchstart heisst: im Ausstiegsfahrzeug, auf dem Weg aus ihm, am Gleis des direkt folgenden Fahrzeugs bzw.
    /// dessen Abfahrt verpasst, oder auf dem Weg zum Ziel, wenn das Ausstiegsfahrzeug das letzte ist. Davor wird gewartet,
    /// eine verpasste Abfahrt bis dorthin verwirft (`isUndercut`).
    /// Ist der Schritt schon weiter (spaeteres Fahrzeug, Weg zum Ziel), bevor die Ankunft erreicht ist, war die Echtzeit-Ankunft
    /// zu spaet geschaetzt und der Nutzer ist schon unterwegs: verwerfen, nie an der falschen Station wechseln. Nach der Ankunft
    /// gilt ein weiterer Schritt als Fahrplan-Annahme (ohne Position, oder am Gleis nach der Abfahrt) und startet wie bisher:
    /// der Schritt kann dort nicht zwischen "eingestiegen" und "steht noch am Suchstart" unterscheiden, und der gebrochene
    /// Anschluss ist der Grund der Vormerkung. Verworfen wird auch ohne Ankunftszeit des Ausstiegsfahrzeugs.
    public static func pendingSwitch(_ search: ReplanSearch, journey: Journey, step: NavigationStep, affected: Set<Int>,
                                     now: Date) -> PendingSwitchStep {
        let last = search.alightingVehicle
        guard step != .arrived, let leg = journey.legs.first(where: { $0.index == last }), let arrival = leg.arrival ?? leg.plannedArrival,
              !isUndercut(search, affected: affected, journey: journey, step: step) else { return .drop }
        let next = journey.legs.first { !$0.isWalk && $0.index > last }?.index
        // true: am Suchstart, false: davor, nil: schon weiter
        let reached: Bool? = switch step {
        case .waitingToLeave, .approachingFirstStop: false
        case .onBoardTransit(let v): v == last ? true : v < last ? false : nil
        case .transferRouting(let from, _): from == last ? true : from < last ? false : nil
        case .waitingAtPlatform(let v), .missedDeparture(let v): v == next ? true : v <= last ? false : nil
        case .finalWalkToDestination: next == nil ? true : nil
        case .arrived: nil
        }
        guard now >= arrival else { return reached == nil ? .drop : .wait }
        return reached == false ? .wait : .start(arrival: arrival)
    }

    /// Gilt ein Vorschlag noch? Nur solange derselbe Anschluss weiter betroffen ist (`current` = Ergebnis von `evaluate`)
    /// und der Nutzer den Suchstart noch nicht erreicht hat (die Zeit folgt der aktuellen Echtzeit-Ankunft).
    /// Danach gilt der bestehende Ablauf; ein spaeter eintreffender Suchlauf wird verworfen.
    public static func isValid(_ proposal: ReplanProposal, current: [ReplanSearch], now: Date) -> Bool {
        guard let live = current.first(where: { $0.key == proposal.search.key }) else { return false }
        return now < live.time
    }

    /// Zwischenstopps, die die Alternative noch behalten soll: alle ab dem Ausstiegsfahrzeug (dessen Halt eingeschlossen),
    /// nicht erkannte entfallen wie in `AppFlow.remainingVia`.
    public static func remainingVia(_ via: [ViaStop], in journey: Journey, alightingVehicle: Int) -> [ViaStop] {
        let ahead = journey.viaStays(via).filter { $0.arrivalLeg >= alightingVehicle }.map(\.via)
        return via.filter(ahead.contains)
    }
}

/// Gedaechtnis einer Fahrt gegen Wiederholung (nur RAM, mit der Navigation verworfen).
/// Ablehnen merkt das Fahrzeug, nicht die Art: wer "B reicht nicht" behaelt, wird bei "B faellt aus" erneut gefragt
/// (Ausfall ist weit schlechter als 300 s), umgekehrt nicht.
public struct ReplanMemory: Sendable, Hashable {
    private var searched: [ReplanKey: Int] = [:]
    private var declined: [ReplanKey: Int] = [:]
    private var retryNotBefore: Date?
    public private(set) var searchCount = 0
    public private(set) var failureCount = 0

    public init() {}

    /// Darf jetzt gesucht werden? Ein Schluessel wird nur bei mindestens `worseningSeconds` schlechterem Puffer erneut gesucht,
    /// nie nach abgelehntem Stand, nie mehr als `maxSearches` je Fahrt und nicht vor Ablauf der Wiederholungssperre.
    public func maySearch(_ search: ReplanSearch, now: Date) -> Bool {
        if searchCount >= ConnectionWatch.maxSearches || failureCount >= ConnectionWatch.maxFailures { return false }
        if let retryNotBefore, now < retryNotBefore { return false }
        if isDeclined(search) { return false }
        guard let seen = searched[search.key] else { return true }
        return search.bufferSeconds <= seen - ConnectionWatch.worseningSeconds
    }

    /// Die naechste Suche, nacheinander: abgelehnte Fahrzeuge (auch solche ohne Alternative, siehe `decline`) werden uebersprungen.
    /// Ist ein Fahrzeug gesucht und noch unbeantwortet, kommt nil; das naechste wartet auf Antwort oder Ablehnen.
    public func next(in searches: [ReplanSearch], now: Date) -> ReplanSearch? {
        for s in searches {
            if maySearch(s, now: now) { return s }
            if searched[s.key] != nil && !isDeclined(s) { return nil }
        }
        return nil
    }

    /// Vor dem Start des Tasks aufrufen (synchron), sonst starten zwei Auswertungen dieselbe Suche.
    public mutating func markSearched(_ search: ReplanSearch) {
        searched[search.key] = search.bufferSeconds
        searchCount += 1
    }

    /// Suche gescheitert: Zaehler zurueck (die Suche zaehlt als Fehlversuch, hoechstens `maxFailures`), nach `retryDelay`
    /// oder `blockedUntil` (Rate-Limit) erneut. Wirkt nur fuer eine markierte Suche.
    public mutating func markFailed(_ search: ReplanSearch, now: Date, blockedUntil: Date?) {
        guard searched[search.key] != nil else { return }
        searched[search.key] = nil
        searchCount = max(searchCount - 1, 0)
        failureCount += 1
        retryNotBefore = max(now.addingTimeInterval(ConnectionWatch.retryDelay), blockedUntil ?? .distantPast)
    }

    /// Auch fuer eine Suche ohne brauchbare Alternative aufrufen, damit das naechste Fahrzeug drankommt.
    /// "Behalten": derselbe Auslöser meldet sich nicht wieder, ausser der Puffer wird um `worseningSeconds` schlechter.
    public mutating func decline(_ search: ReplanSearch) { declined[search.key] = search.bufferSeconds }

    public func isDeclined(_ search: ReplanSearch) -> Bool { isDeclined(search.key, bufferSeconds: search.bufferSeconds) }

    func isDeclined(_ key: ReplanKey, bufferSeconds: Int) -> Bool {
        guard let seen = declined[key] else { return false }
        return bufferSeconds > seen - ConnectionWatch.worseningSeconds
    }
}
