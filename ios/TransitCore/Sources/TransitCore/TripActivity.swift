import Foundation

/// Inhalt der Live Activity ohne ActivityKit (TransitCore baut auch fuer macOS). Nur Fahrplandaten: keine Labels, Adressen,
/// Koordinaten, Tokens, keine Position, auch keine Restmeter. Kein Wert haengt an `now`, Countdowns laufen ueber `target`:
/// so aktualisiert sich die Activity nur, wenn sich wirklich etwas aendert.
public struct TripActivityState: Codable, Hashable, Sendable {
    /// Wie die Jetzt-Karte (DESIGN.md C).
    public enum Phase: String, Codable, Sendable {
        case leave, walk, platform, riding, exitNext, transfer, finalWalk, arrived
    }

    /// Wie `ReminderText.lostTitle`.
    public enum Problem: String, Codable, Sendable { case cancelled, connection }

    public let phase: Phase
    /// Endpunkt des Countdowns: Losgehen, Abfahrt oder Ankunft.
    public let target: Date?
    /// Das Fahrzeug, um das es gerade geht.
    public let ride: TripSnapshot.Ride?
    /// Letzter Halt des letzten Fahrzeugs; nie der Zielpunkt der Suche.
    public let destination: String?
    /// Verkehrsmittel aller Fahrzeuge, `current` ist der Platz des aktuellen.
    public let modes: [TransitMode]
    public let current: Int
    public let delayMinutes: Int?
    public let problem: Problem?

    /// Vor der Navigation: die Erinnerung zaehlt zum Losgehen herunter.
    public init(plan: ReminderPlan) {
        let vehicles = plan.journey.legs.filter { !$0.isWalk }
        problem = plan.status == .lost ? Self.problem(plan.journey, vehicle: nil, broken: true) : nil
        phase = .leave
        target = problem == nil ? plan.leaveAt : plan.scheduled.firstDeparture
        ride = vehicles.first.map(TripSnapshot.Ride.init)
        destination = Self.destination(vehicles)
        modes = vehicles.map(\.mode)
        current = 0
        delayMinutes = plan.delayMinutes
    }

    /// Unterwegs: `step` kommt aus `NavigationEngine.resolve`. `broken`: ein spaeterer Anschluss reicht nicht mehr.
    public init(journey: Journey, step: NavigationStep, leaveAt: Date?, broken: Bool, now: Date) {
        let vehicles = journey.legs.filter { !$0.isWalk }
        let index = NavigationEngine.targetVehicle(step)
        var vehicle = index.flatMap { i in vehicles.first { $0.index == i } }
        if case .transferRouting = step {} else if vehicle == nil { vehicle = vehicles.last }
        let departure = vehicle?.departure ?? vehicle?.plannedDeparture
        let arrival = vehicle?.arrival ?? vehicle?.plannedArrival
        var missed = broken
        if case .missedDeparture = step { missed = true }
        problem = Self.problem(journey, vehicle: vehicle, broken: missed)
        switch step {
        case .waitingToLeave:
            phase = .leave
            target = problem == nil ? leaveAt ?? NavigationEngine.leaveTime(journey) : departure
        case .approachingFirstStop:
            phase = .walk
            target = departure
        case .waitingAtPlatform:
            phase = .platform
            target = departure
        case .onBoardTransit:
            phase = vehicle.map { NavigationEngine.exitsNext(leg: $0, now: now) } == true ? .exitNext : .riding
            target = arrival
        case .transferRouting, .missedDeparture:
            phase = .transfer
            target = departure
        case .finalWalkToDestination:
            phase = .finalWalk
            target = journey.arrival
        case .arrived:
            phase = .arrived
            target = nil
        }
        // Ausgestiegen: Gleis und Verspaetung des letzten Fahrzeugs gelten nicht mehr. `vehicle` bleibt fuer Leg-Bar und Ausfall.
        let done = phase == .finalWalk || phase == .arrived
        ride = done ? nil : vehicle.map(TripSnapshot.Ride.init)
        destination = Self.destination(vehicles)
        modes = vehicles.map(\.mode)
        current = vehicle.flatMap { v in vehicles.firstIndex { $0.index == v.index } } ?? max(0, vehicles.count - 1)
        let delay = phase == .riding || phase == .exitNext ? vehicle?.arrivalDelaySeconds : vehicle?.departureDelaySeconds
        delayMinutes = done ? nil : delay.flatMap { $0 >= 60 ? $0 / 60 : nil }
    }

    private static func destination(_ vehicles: [Leg]) -> String? {
        vehicles.last.flatMap { $0.destination.kind == .stop ? $0.destination.name : nil }
    }

    private static func problem(_ journey: Journey, vehicle: Leg?, broken: Bool) -> Problem? {
        if journey.cancelled || vehicle?.cancelled == true || (vehicle == nil && journey.legs.contains { !$0.isWalk && $0.cancelled }) {
            return .cancelled
        }
        return broken ? .connection : nil
    }
}

public extension TripActivityState {
    /// Nach `staleDate` laeuft die Activity ohne App weiter: aus dem Countdown wird die Aufforderung.
    func title(stale: Bool) -> String {
        if let problem { return Self.text(problem) }
        switch phase {
        case .leave: return stale ? ReminderText.title(.leave, warnMinutes: 0) : String(localized: "Losgehen", bundle: .module)
        case .walk: return ride?.platform == nil ? String(localized: "Zum Halt", bundle: .module) : String(localized: "Zum Gleis", bundle: .module)
        case .platform: return ride?.platform == nil ? String(localized: "Am Halt", bundle: .module) : String(localized: "Am Gleis", bundle: .module)
        case .riding: return ride?.line.map { String(localized: "Im \($0)", bundle: .module) } ?? String(localized: "Im Fahrzeug", bundle: .module)
        case .exitNext: return String(localized: "Nächster Halt aussteigen", bundle: .module)
        case .transfer: return ride?.line.map { String(localized: "Umstieg in \($0)", bundle: .module) } ?? String(localized: "Umstieg", bundle: .module)
        case .finalWalk: return String(localized: "Zu Fuß zum Ziel", bundle: .module)
        case .arrived: return String(localized: "Angekommen", bundle: .module)
        }
    }

    private static func text(_ problem: Problem) -> String {
        switch problem {
        case .cancelled: String(localized: "Verbindung fällt aus", bundle: .module)
        case .connection: String(localized: "Anschluss reicht nicht mehr", bundle: .module)
        }
    }

    /// Bei einem Problem gibt es bis zur Abfahrt nichts herunterzuzaehlen: dann steht die Uhrzeit da. Die Ankunft zaehlt weiter.
    var countsDown: Bool { problem == nil || [.riding, .exitNext, .finalWalk].contains(phase) }

    /// Beschriftung des Countdowns.
    var targetLabel: String? {
        switch phase {
        case .leave, .walk, .platform, .transfer:
            if !countsDown { return String(localized: "Abfahrt", bundle: .module) }
            return phase == .leave ? String(localized: "Los in", bundle: .module) : String(localized: "Abfahrt in", bundle: .module)
        case .riding, .exitNext, .finalWalk: return String(localized: "Ankunft in", bundle: .module)
        case .arrived: return nil
        }
    }

    /// Der Halt, um den es gerade geht: einsteigen, im Fahrzeug aussteigen.
    var stop: String? {
        switch phase {
        case .riding, .exitNext: ride?.to
        case .finalWalk, .arrived: destination
        default: ride?.from
        }
    }

    /// Absolut statt "in": gesprochen wird die Uhrzeit, nicht der laufende Countdown.
    private var spokenTime: String? {
        guard let clock = target?.clockText else { return nil }
        switch phase {
        case .leave where countsDown: return String(localized: "Losgehen \(clock)", bundle: .module)
        case .leave, .walk, .platform, .transfer: return String(localized: "Abfahrt \(clock)", bundle: .module)
        case .riding, .exitNext, .finalWalk: return String(localized: "Ankunft \(clock)", bundle: .module)
        case .arrived: return nil
        }
    }

    /// VoiceOver; ohne Halte, solange der Sperrbildschirm redigiert ist.
    func spoken(stale: Bool, includeStops: Bool) -> String {
        var parts = [title(stale: stale)]
        if let time = spokenTime { parts.append(time) }
        if phase != .riding, phase != .exitNext, phase != .transfer, let line = ride?.line { parts.append(line) }
        if includeStops, let stop { parts.append(stop) }
        if let platform = ride?.platformText, phase != .riding, phase != .exitNext { parts.append(platform) }
        if let delayMinutes { parts.append(String(localized: "\(delayMinutes) Minuten verspätet", bundle: .module)) }
        if stale, phase != .leave { parts.append(String(localized: "Stand evtl. nicht aktuell", bundle: .module)) }
        return parts.joined(separator: ", ")
    }
}

/// Soll-Stand einer Activity. `key` ist die Erinnerung oder eine eigene ID je Navigation, je Fahrt hoechstens eine.
public struct TripActivityDesire: Sendable, Hashable {
    public let key: String
    public let state: TripActivityState
    /// Geplanter Start; nil = sofort.
    public let startAt: Date?
    public let staleDate: Date?
}

/// Ist-Stand, wie ihn das System meldet.
public struct TripActivityRunning: Sendable, Hashable {
    public let key: String
    public let state: TripActivityState
    public let startAt: Date?
    /// Geplant, noch nicht sichtbar.
    public let isPending: Bool

    public init(key: String, state: TripActivityState, startAt: Date?, isPending: Bool) {
        self.key = key
        self.state = state
        self.startAt = startAt
        self.isPending = isPending
    }
}

public enum TripActivityAction: Sendable, Hashable {
    case start(TripActivityDesire)
    /// `alert`: meldet sich auch bei gesperrtem Geraet.
    case update(TripActivityDesire, alert: Bool = false)
    /// Ankunft: endet mit Endstand, der noch `TripActivityPlanner.finishLinger` stehen bleibt.
    case finish(TripActivityDesire)
    case end(key: String)
}

/// Eine Funktion fuer alles: Start, Ersetzen, Aufraeumen. Was nicht gewuenscht ist, endet; darum gibt es keine Waisen
/// und keine zweite Activity je Fahrt.
public enum TripActivityPlanner {
    /// Geplanter Start vor dem Losgehen (SPEZIFIKATION 4.3).
    public static let startLead: TimeInterval = 15 * 60
    /// Spaeter als der Countdown plus das: die App laeuft nicht mehr, der Stand ist alt.
    public static let staleGrace: TimeInterval = 2 * 60
    /// So lange bleibt "Angekommen" auf dem Sperrbildschirm.
    public static let finishLinger: TimeInterval = 5 * 60

    private static func desire(_ key: String, _ state: TripActivityState, leaveAt: Date?, now: Date) -> TripActivityDesire {
        let start = leaveAt?.addingTimeInterval(-startLead)
        let stale: Date? = switch state.phase {
        // Beim Losgehen schaltet die Anzeige ueber `isStale` auf "Jetzt losgehen", auch ohne App.
        case .leave: state.target
        // Die Ankunft ist hier eine Schaetzung; laenger zu gehen macht den Stand nicht alt.
        case .finalWalk: nil
        // Ziel schon vorbei (verpasst): sonst waere die Activity sofort "nicht aktuell".
        default: state.target?.addingTimeInterval(staleGrace).nonPast(now)
        }
        return TripActivityDesire(key: key, state: state, startAt: start.flatMap { $0 > now ? $0 : nil }, staleDate: stale)
    }

    /// Bis zur Abfahrt; weggefallen wie `ReminderCenter.lost`.
    public static func reminder(key: String, plan: ReminderPlan, now: Date) -> TripActivityDesire? {
        guard now < plan.scheduled.firstDeparture else { return nil }
        return desire(key, TripActivityState(plan: plan), leaveAt: plan.leaveAt, now: now)
    }

    /// Welche Erinnerung die Activity bekommt: nur die eine, nach derselben Regel wie die Widgets (`TripSnapshot.trip(at:)`).
    public static func nextReminder(_ reminders: [(key: String, plan: ReminderPlan)], now: Date) -> TripActivityDesire? {
        let open = reminders.filter { now < $0.plan.scheduled.firstDeparture }
        let snapshot = TripSnapshot(plans: open.map(\.plan))
        guard let trip = snapshot.trip(at: now), let index = snapshot.trips.firstIndex(of: trip) else { return nil }
        return reminder(key: open[index].key, plan: open[index].plan, now: now)
    }

    public static func navigation(key: String, state: TripActivityState, now: Date) -> TripActivityDesire {
        desire(key, state, leaveAt: nil, now: now)
    }

    /// Kaltstart ueber den Knopf: die Navigation ist mit dem Prozess weg, zurueck auf "Losgehen" waere falsch.
    public static func stranded(_ running: [TripActivityRunning]) -> [TripActivityAction] {
        running.filter { $0.state.phase != .leave }.map { .end(key: $0.key) }
    }

    /// Was zuletzt lief (`seen`: Key und geplanter Start, sonst `.distantPast`) und fehlt, ohne dass die App es beendet hat
    /// (`end` nimmt den Key heraus). Fehlt ein Key vor seinem Start, hat ihn niemand gesehen, also auch niemand weggewischt:
    /// das ist ein App-Update oder ein von iOS verworfener Plan, der naechste Vordergrund-Abgleich plant neu.
    public static func dismissed(seen: [String: Date], live: Set<String>, now: Date) -> Set<String> {
        Set(seen.filter { !live.contains($0.key) && $0.value <= now }.keys)
    }

    /// Haptik und Mitteilung nur bei dem, was man bei gesperrtem Geraet nicht verpassen darf (DESIGN 4c). Liegt der letzte
    /// Zwischenhalt kurz vor dem Umstieg, entfaellt `.exitNext`, dann ist `.transfer` die Ansage.
    private static func alerts(from old: TripActivityState, to new: TripActivityState) -> Bool {
        (new.phase == .exitNext && old.phase != .exitNext) || (new.phase == .transfer && old.phase == .riding)
            || (new.problem != nil && new.problem != old.problem)
    }

    /// Starten geht nur im Vordergrund (`canStart`); im Hintergrund bleibt eine geplante Activity stehen, ausser sie kaeme zu
    /// spaet oder die Fahrt hat ein Problem. Eine spaetere Zeit korrigiert der naechste Vordergrund-Abgleich. `rejected`: weggewischt oder vom System beendet, fuer diese Fahrt kein neuer Start.
    public static func actions(running: [TripActivityRunning], desired: [TripActivityDesire], canStart: Bool,
                               rejected: Set<String> = []) -> [TripActivityAction] {
        var actions: [TripActivityAction] = []
        for activity in running where !desired.contains(where: { $0.key == activity.key }) {
            actions.append(.end(key: activity.key))
        }
        for wish in desired {
            let activity = running.first { $0.key == wish.key }
            if wish.state.phase == .arrived {
                // Nie neu starten: nach `.finish` zaehlt die Activity nicht mehr als laufend.
                if let activity { actions.append(activity.isPending ? .end(key: wish.key) : .finish(wish)) }
            } else if let activity, activity.isPending {
                // Geplantes laesst sich nicht aendern. Auch ein verstrichener Start landet hier: Rueckfall auf sofort.
                guard activity.state != wish.state || activity.startAt != wish.startAt else { continue }
                if canStart {
                    actions += [.end(key: wish.key), .start(wish)]
                } else if wish.state.problem != nil || (wish.state.target ?? .distantPast) < (activity.state.target ?? .distantPast) {
                    actions.append(.end(key: wish.key))
                }
            } else if let activity {
                if activity.state != wish.state { actions.append(.update(wish, alert: alerts(from: activity.state, to: wish.state))) }
            } else if canStart, !rejected.contains(wish.key) {
                actions.append(.start(wish))
            }
        }
        return actions
    }
}

private extension Date {
    func nonPast(_ now: Date) -> Date? { self > now ? self : nil }
}
