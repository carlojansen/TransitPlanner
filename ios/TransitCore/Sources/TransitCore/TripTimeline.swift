import Foundation

public extension TripSnapshot {
    /// Ein Stand der Widget-Timeline: ab `date` gilt `trip`, nil = Leerzustand.
    struct TimelineStep: Sendable, Hashable {
        public let date: Date
        public let trip: Trip?
    }

    /// WidgetKit-Budget: Zeiten dazwischen laufen ueber `Text(timerInterval:)`, nicht ueber Eintraege.
    static let minimumEntryGap: TimeInterval = 5 * 60
    /// Ab hier zaehlt das Widget herunter; davor steht die Uhrzeit (ein Timer waere bei Tagen unlesbar).
    static let countdownLead: TimeInterval = 60 * 60

    /// Vorberechnet: ein Eintrag je Wechsel, auch ohne Reload (`.after` ist nur ein fruehester Zeitpunkt). Zu nahe Wechsel
    /// warten auf den Mindestabstand; was sie dabei ueberholen, steckt im Stand des spaeteren Eintrags. Eine Fahrt verschwindet
    /// also hoechstens `minimumEntryGap` zu spaet, nie gar nicht. Der Abstand gilt nicht zum Eintrag `now`, sonst stuende
    /// kurz vor dem Losgehen "Los in 0:00" statt "Jetzt losgehen".
    func timeline(now: Date) -> [TimelineStep] {
        let changes = trips.flatMap {
            [$0.leaveAt.addingTimeInterval(-Self.countdownLead), $0.leaveAt, $0.firstDeparture, $0.arrival] + $0.rides.compactMap(\.arrival)
        }
        var dates: [Date] = []
        for change in changes.sorted() where change > dates.last ?? now {
            dates.append(dates.last.map { max(change, $0.addingTimeInterval(Self.minimumEntryGap)) } ?? change)
        }
        return ([now] + dates).map { TimelineStep(date: $0, trip: trip(at: $0)) }
    }

    /// `trips` ist nach Losgehen sortiert (`ReminderCenter.rows`), das fruehere gewinnt. Ist es schon abgefahren, geht eine
    /// Fahrt vor, deren Losgehen ansteht: unterwegs zaehlt der naechste Aufbruch mehr als die laufende Fahrt.
    func trip(at date: Date) -> Trip? {
        let open = trips.filter { $0.endsAt > date }
        return open.first { [.soon, .leaveNow].contains($0.phase(at: date)) } ?? open.first
    }
}

public extension TripSnapshot.Trip {
    enum Phase: Sendable, Hashable { case later, soon, leaveNow, riding }

    /// Ab hier zeigt das Widget die Fahrt nicht mehr. Weggefallen endet sie bei der Abfahrt wie `ReminderCenter.lost`.
    var endsAt: Date { status == .lost ? min(firstDeparture, arrival) : arrival }

    /// Wie `ReminderText.lostTitle`.
    var isCancelled: Bool { cancelled == true || rides.contains(where: \.cancelled) }

    func phase(at date: Date) -> Phase {
        if date >= firstDeparture { return .riding }
        if date >= leaveAt { return .leaveNow }
        return date >= leaveAt.addingTimeInterval(-TripSnapshot.countdownLead) ? .soon : .later
    }

    /// Fahrzeuge ab dem aktuellen; angekommene fallen weg.
    func remainingRides(at date: Date) -> ArraySlice<TripSnapshot.Ride> {
        rides.drop { ($0.arrival ?? .distantFuture) <= date }
    }

    /// Das Fahrzeug, um das es gerade geht: unterwegs das aktuelle, davor das erste.
    func ride(at date: Date) -> TripSnapshot.Ride? { remainingRides(at: date).first ?? rides.last }

    /// nil, solange die Verbindung steht.
    var lostText: String? {
        guard status == .lost else { return nil }
        return isCancelled ? String(localized: "Verbindung fällt aus", bundle: .module)
            : String(localized: "Anschluss reicht nicht mehr", bundle: .module)
    }

    /// Die Verspaetung gilt der ersten Abfahrt, unterwegs zaehlt die Ankunft.
    func visibleDelay(at date: Date) -> Int? { phase(at: date) == .riding ? nil : delayMinutes }

    /// "08:32", an einem anderen Tag "Mo., 08:32", ab 7 Tagen "8. Nov., 08:32"; "ca.", solange nicht neu berechnet.
    func leaveText(at date: Date) -> String {
        let time = if Calendar.current.isDate(leaveAt, inSameDayAs: date) {
            leaveAt.clockText
        } else if leaveAt.timeIntervalSince(date) >= 7 * 24 * 3600 {
            leaveAt.formatted(.clock.day().month(.abbreviated))
        } else {
            leaveAt.formatted(.clock.weekday(.abbreviated))
        }
        return isEstimated ? String(localized: "ca. \(time)", bundle: .module) : time
    }

    /// VoiceOver: wie die Mitteilung, dieselbe Uhrzeit wie in der App. Ohne Halte, solange das Widget redigiert ist.
    func spoken(at date: Date, includeStops: Bool) -> String {
        var parts: [String]
        switch phase(at: date) {
        case .later, .soon: parts = [String(localized: "Losgehen \(leaveText(at: date))", bundle: .module)]
        case .leaveNow: parts = [ReminderText.title(.leave, warnMinutes: 0)]
        case .riding: parts = [String(localized: "Ankunft \(arrival.clockText)", bundle: .module)]
        }
        if let lostText { parts.insert(lostText, at: 0) }
        if let ride = ride(at: date) {
            if let line = ride.line { parts.append(line) }
            if includeStops, let stop = ride.from { parts.append(String(localized: "ab \(stop)", bundle: .module)) }
            if let platform = ride.platformText { parts.append(platform) }
        }
        if includeStops, let stop = rides.last?.to { parts.append(String(localized: "nach \(stop)", bundle: .module)) }
        if let delay = visibleDelay(at: date) { parts.append(String(localized: "\(delay) Minuten verspätet", bundle: .module)) }
        return parts.joined(separator: ", ")
    }
}

public extension TripSnapshot.Ride {
    /// "Gleis 2" oder bei Wechsel "Gleis 2 statt 1"; die Aenderung steht im Text, nicht nur in der Farbe.
    var platformText: String? {
        guard let platform else { return nil }
        if let plannedPlatform, plannedPlatform != platform {
            return String(localized: "Gleis \(platform) statt \(plannedPlatform)", bundle: .module)
        }
        return String(localized: "Gleis \(platform)", bundle: .module)
    }
}
