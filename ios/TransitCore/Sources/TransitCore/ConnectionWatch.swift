import Foundation

/// Warum unterwegs umgeplant werden soll (SPEZIFIKATION 4.4). `vehicle` ist der betroffene Leg-Index.
public enum ReplanTrigger: Sendable, Hashable {
    /// Der Anschluss reicht nach Echtzeit nicht mehr (Puffer unter 0 s).
    case connectionBroken(vehicle: Int)
    /// Das spaetere Fahrzeug faellt aus.
    case tripCancelled(vehicle: Int)

    public var vehicle: Int {
        switch self {
        case .connectionBroken(let v), .tripCancelled(let v): v
        }
    }
}

/// Das betroffene Fahrzeug (Fahrt-ID, sonst Linie und Plan-Abfahrt). Dieselbe Verbindung, dasselbe Fahrzeug: derselbe Schluessel.
public struct ReplanKey: Sendable, Hashable {
    public let vehicle: String

    init(_ leg: Leg) {
        vehicle = leg.tripId ?? "\(leg.line?.name ?? leg.mode.rawValue)@\((leg.plannedDeparture ?? leg.departure)?.timeIntervalSince1970 ?? 0)"
    }
}

/// Woher und wann gesucht wird: vom Ausstiegshalt des Fahrzeugs vor dem betroffenen, zur Echtzeit-Ankunft dort.
public struct ReplanSearch: Sendable, Hashable {
    public let trigger: ReplanTrigger
    public let key: ReplanKey
    /// Fahrzeug, in dem man bis zum Suchstart sitzt.
    public let alightingVehicle: Int
    public let start: TripEndpoint
    public let time: Date
    /// Puffer des betroffenen Anschlusses in s; `ConnectionWatch.cancelledBuffer` bei Ausfall.
    public let bufferSeconds: Int
}

/// Reine Regeln der proaktiven Umplanung: keine Uhr, kein Netz, keine UI (`now` kommt als Parameter).
public enum ConnectionWatch {
    /// Eine neue Suche zum selben Fahrzeug erst, wenn der Puffer so viel schlechter ist (s).
    public static let worseningSeconds = 300
    /// Hoechstens so viele Suchen je Fahrt.
    public static let maxSearches = 3
    /// Mindestwartezeit nach einer gescheiterten Suche (s).
    public static let retryDelay: TimeInterval = 60
    /// Puffer eines ausgefallenen Fahrzeugs: schlechter als jede Verspaetung, aber ohne Ueberlauf beim Vergleich.
    public static let cancelledBuffer = -86_400

    /// Fahrzeug, in dem man bis zum Suchstart sitzt: `onBoardTransit` oder die 120 s vor dem Ausstieg. Am Gleis, beim Gehen
    /// und nach dem Ausstieg nil (dort gilt der bestehende Ablauf).
    static func boardedVehicle(_ step: NavigationStep, in journey: Journey, now: Date) -> Int? {
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
    /// `latched` gehoert dem Aufrufer (RAM) und wird mit dem Ergebnis zurueckgegeben.
    public static func evaluate(journey: Journey, step: NavigationStep, latched: Set<Int>, walks: [Int: WalkEstimate],
                                now: Date, pace: WalkingPaceFactor) -> (search: ReplanSearch?, latched: Set<Int>) {
        guard let last = boardedVehicle(step, in: journey, now: now) else { return (nil, latched) }
        var latched = latched
        let vehicles = journey.legs.filter { !$0.isWalk }
        if let broken = NavigationEngine.brokenConnection(after: last, journey: journey, walks: walks, now: now, pace: pace) {
            latched.insert(broken)
        }
        for leg in vehicles where leg.index > last && leg.cancelled { latched.insert(leg.index) }
        for index in latched.filter({ $0 > last }).sorted() {
            guard let affected = vehicles.first(where: { $0.index == index }) else { latched.remove(index); continue }
            let buffer = affected.cancelled ? cancelledBuffer
                : NavigationEngine.buffer(journey: journey, vehicle: index, walks: walks, position: nil, now: now, pace: pace)?.seconds ?? 0
            if !affected.cancelled, buffer >= TransferCheck.minimumSlackSeconds { latched.remove(index); continue }
            guard let before = vehicles.last(where: { $0.index < index }) else { continue }
            return (search(before: before, affected: affected, buffer: buffer, now: now), latched)
        }
        return (nil, latched)
    }

    private static func search(before: Leg, affected: Leg, buffer: Int, now: Date) -> ReplanSearch? {
        let place = before.destination
        let start: TripEndpoint
        if let id = place.id {
            start = .stop(id: id, label: place.name ?? "")
        } else if let coordinate = place.coordinate {
            start = .coordinate(coordinate, label: place.name ?? "")
        } else {
            return nil
        }
        let trigger: ReplanTrigger = affected.cancelled ? .tripCancelled(vehicle: affected.index) : .connectionBroken(vehicle: affected.index)
        return ReplanSearch(trigger: trigger, key: ReplanKey(affected), alightingVehicle: before.index, start: start,
                            time: max(now, before.arrival ?? before.plannedArrival ?? now), bufferSeconds: buffer)
    }

    /// Erste Alternative der Rangfolge, die man wirklich erreicht: ohne das betroffene Fahrzeug, ohne Ausfall, kein Umstieg
    /// verpasst und erste Abfahrt frühestens Suchzeit + Gehweg am Start + `minimumSlackSeconds` (MOTIS liefert Abfahrten
    /// ohne Umstiegszeit, live geprueft 18.11.). Ergebnis ist der Index in `alternatives`.
    public static func pick(_ alternatives: [CalibratedJourney], for search: ReplanSearch) -> Int? {
        alternatives.firstIndex { alt in
            let vehicles = alt.journey.legs.filter { !$0.isWalk }
            guard !alt.journey.cancelled, let first = vehicles.first,
                  !vehicles.contains(where: { $0.cancelled || ReplanKey($0) == search.key }),
                  !alt.transfers.contains(where: { $0.status == .missed }),
                  let departure = first.departure ?? first.plannedDeparture else { return false }
            let access = alt.journey.legs.first.flatMap { $0.isWalk ? (alt.walks[$0.index]?.seconds ?? $0.durationSeconds) : nil } ?? 0
            let earliest = search.time.addingTimeInterval(TimeInterval(access + TransferCheck.minimumSlackSeconds))
            return departure >= earliest
        }
    }

    /// Zwischenstopps, die die Alternative noch behalten soll: alle ab dem Ausstiegsfahrzeug (dessen Halt eingeschlossen),
    /// nicht erkannte entfallen wie in `AppFlow.remainingVia`.
    public static func remainingVia(_ via: [ViaStop], in journey: Journey, alightingVehicle: Int) -> [ViaStop] {
        let ahead = journey.viaStays(via).filter { $0.arrivalLeg >= alightingVehicle }.map(\.via)
        return via.filter(ahead.contains)
    }
}

/// Gedaechtnis einer Fahrt gegen Wiederholung (nur RAM, mit der Navigation verworfen).
public struct ReplanMemory: Sendable, Hashable {
    private var searched: [ReplanKey: Int] = [:]
    private var declined: [ReplanKey: Int] = [:]
    private var retryNotBefore: Date?
    public private(set) var searchCount = 0

    public init() {}

    /// Darf jetzt gesucht werden? Ein Schluessel wird nur bei mindestens `worseningSeconds` schlechterem Puffer erneut gesucht,
    /// nie nach abgelehntem Stand, nie mehr als `maxSearches` je Fahrt und nicht vor Ablauf der Wiederholungssperre.
    public func maySearch(_ search: ReplanSearch, now: Date) -> Bool {
        if searchCount >= ConnectionWatch.maxSearches { return false }
        if let retryNotBefore, now < retryNotBefore { return false }
        if isDeclined(search) { return false }
        guard let seen = searched[search.key] else { return true }
        return search.bufferSeconds <= seen - ConnectionWatch.worseningSeconds
    }

    /// Vor dem Start des Tasks aufrufen (synchron), sonst starten zwei Auswertungen dieselbe Suche.
    public mutating func markSearched(_ search: ReplanSearch) {
        searched[search.key] = search.bufferSeconds
        searchCount += 1
    }

    /// Suche gescheitert: Zaehler zurueck, nach `retryDelay` oder `blockedUntil` (Rate-Limit) erneut.
    public mutating func markFailed(_ search: ReplanSearch, now: Date, blockedUntil: Date?) {
        searched[search.key] = nil
        searchCount = max(searchCount - 1, 0)
        retryNotBefore = max(now.addingTimeInterval(ConnectionWatch.retryDelay), blockedUntil ?? .distantPast)
    }

    /// "Behalten": derselbe Auslöser meldet sich nicht wieder, ausser der Puffer wird um `worseningSeconds` schlechter.
    public mutating func decline(_ search: ReplanSearch) { declined[search.key] = search.bufferSeconds }

    public func isDeclined(_ search: ReplanSearch) -> Bool {
        guard let seen = declined[search.key] else { return false }
        return search.bufferSeconds > seen - ConnectionWatch.worseningSeconds
    }
}
