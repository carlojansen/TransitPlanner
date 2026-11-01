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
        phase = .leave
        target = plan.leaveAt
        ride = vehicles.first.map(TripSnapshot.Ride.init)
        destination = Self.destination(vehicles)
        modes = vehicles.map(\.mode)
        current = 0
        delayMinutes = plan.delayMinutes
        problem = plan.status == .lost ? Self.problem(plan.journey, vehicle: nil, broken: true) : nil
    }

    /// Unterwegs: `step` kommt aus `NavigationEngine.resolve`. `broken`: ein spaeterer Anschluss reicht nicht mehr.
    public init(journey: Journey, step: NavigationStep, leaveAt: Date?, broken: Bool, now: Date) {
        let vehicles = journey.legs.filter { !$0.isWalk }
        let index = NavigationEngine.targetVehicle(step)
        var vehicle = index.flatMap { i in vehicles.first { $0.index == i } }
        if case .transferRouting = step {} else if vehicle == nil { vehicle = vehicles.last }
        let departure = vehicle?.departure ?? vehicle?.plannedDeparture
        let arrival = vehicle?.arrival ?? vehicle?.plannedArrival
        switch step {
        case .waitingToLeave:
            phase = .leave
            target = leaveAt ?? NavigationEngine.leaveTime(journey)
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
        ride = vehicle.map(TripSnapshot.Ride.init)
        destination = Self.destination(vehicles)
        modes = vehicles.map(\.mode)
        current = vehicle.flatMap { v in vehicles.firstIndex { $0.index == v.index } } ?? max(0, vehicles.count - 1)
        delayMinutes = vehicle?.departureDelaySeconds.flatMap { $0 >= 60 ? $0 / 60 : nil }
        var missed = broken
        if case .missedDeparture = step { missed = true }
        problem = Self.problem(journey, vehicle: vehicle, broken: missed)
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
        let line = ride?.line ?? ""
        switch phase {
        case .leave: return stale ? ReminderText.title(.leave, warnMinutes: 0) : String(localized: "Losgehen", bundle: .module)
        case .walk: return ride?.platform == nil ? String(localized: "Zum Halt", bundle: .module) : String(localized: "Zum Gleis", bundle: .module)
        case .platform: return ride?.platform == nil ? String(localized: "Am Halt", bundle: .module) : String(localized: "Am Gleis", bundle: .module)
        case .riding: return String(localized: "Im \(line)", bundle: .module)
        case .exitNext: return String(localized: "Nächster Halt aussteigen", bundle: .module)
        case .transfer: return String(localized: "Umstieg in \(line)", bundle: .module)
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

    /// Beschriftung des Countdowns.
    var targetLabel: String? {
        switch phase {
        case .leave: String(localized: "Los in", bundle: .module)
        case .walk, .platform, .transfer: String(localized: "Abfahrt in", bundle: .module)
        case .riding, .exitNext, .finalWalk: String(localized: "Ankunft in", bundle: .module)
        case .arrived: nil
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

    /// VoiceOver; ohne Halte, solange der Sperrbildschirm redigiert ist.
    func spoken(stale: Bool, includeStops: Bool) -> String {
        var parts = [title(stale: stale)]
        if let target { parts.append(String(localized: "Zeit \(target.clockText)", bundle: .module)) }
        if phase != .riding, phase != .exitNext, phase != .transfer, let line = ride?.line { parts.append(line) }
        if includeStops, let stop { parts.append(stop) }
        if let platform = ride?.platformText, phase != .riding, phase != .exitNext { parts.append(platform) }
        if let delayMinutes { parts.append(String(localized: "\(delayMinutes) Minuten verspätet", bundle: .module)) }
        return parts.joined(separator: ", ")
    }
}

/// Soll-Stand einer Activity. `key` ist die Erinnerung oder `navigationKey`, je Fahrt hoechstens eine.
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
    case update(TripActivityDesire)
    case end(key: String)
}

/// Eine Funktion fuer alles: Start, Ersetzen, Aufraeumen. Was nicht gewuenscht ist, endet; darum gibt es keine Waisen
/// und keine zweite Activity je Fahrt.
public enum TripActivityPlanner {
    /// Fahrt ohne Erinnerung.
    public static let navigationKey = "navigation"
    /// Geplanter Start vor dem Losgehen (SPEZIFIKATION 4.3).
    public static let startLead: TimeInterval = 15 * 60
    /// Spaeter als der Countdown plus das: die App laeuft nicht mehr, der Stand ist alt.
    public static let staleGrace: TimeInterval = 2 * 60

    private static func desire(_ key: String, _ state: TripActivityState, leaveAt: Date?, now: Date) -> TripActivityDesire {
        let start = leaveAt?.addingTimeInterval(-startLead)
        // Beim Losgehen schaltet die Anzeige ueber `isStale` auf "Jetzt losgehen", auch ohne App.
        let stale = state.phase == .leave ? state.target : state.target?.addingTimeInterval(staleGrace)
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
        desire(key, state, leaveAt: state.phase == .leave ? state.target : nil, now: now)
    }

    /// Starten geht nur im Vordergrund (`canStart`); im Hintergrund bleibt eine geplante Activity lieber stehen, als dass sie
    /// beendet und nicht neu angelegt werden kann.
    public static func actions(running: [TripActivityRunning], desired: [TripActivityDesire], canStart: Bool) -> [TripActivityAction] {
        var actions: [TripActivityAction] = []
        for activity in running where !desired.contains(where: { $0.key == activity.key }) {
            actions.append(.end(key: activity.key))
        }
        for wish in desired {
            guard let activity = running.first(where: { $0.key == wish.key }) else {
                if canStart { actions.append(.start(wish)) }
                continue
            }
            if activity.isPending {
                // Geplantes laesst sich nicht aendern. Auch ein verstrichener Start landet hier: Rueckfall auf sofort.
                guard canStart, activity.state != wish.state || activity.startAt != wish.startAt else { continue }
                actions += [.end(key: wish.key), .start(wish)]
            } else if activity.state != wish.state {
                actions.append(.update(wish))
            }
        }
        return actions
    }
}
