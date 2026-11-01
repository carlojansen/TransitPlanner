import Foundation

public extension FormatStyle where Self == Date.FormatStyle {
    /// Einheitliche Uhrzeit in UI, VoiceOver und Mitteilungen: zweistellige Stunde ("08:32"), 12-Std.-Gebietsschemata mit AM/PM.
    static var clock: Date.FormatStyle { .dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits) }
}

public extension Date {
    var clockText: String { formatted(.clock) }
}

/// Eine lokale Mitteilung, unabhaengig von UserNotifications (Texte und Zeiten sind so testbar).
public struct ReminderAlert: Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable { case warn, leave, snooze }

    public let tripID: UUID
    public let kind: Kind
    public let title: String
    public let body: String
    public let fireAt: Date

    public var identifier: String { Self.identifier(tripID, kind) }
    /// T-0 und der Snooze davon sind zeitkritisch, die Vorwarnung ist eine normale Mitteilung (D3).
    public var isTimeSensitive: Bool { kind != .warn }

    /// IDs pro Fahrt: Verschieben und Loeschen treffen genau die Mitteilungen dieser Fahrt.
    public static func identifier(_ tripID: UUID, _ kind: Kind) -> String { "reminder.\(tripID.uuidString).\(kind.rawValue)" }
    public static func identifiers(_ tripID: UUID) -> [String] { Kind.allCases.map { identifier(tripID, $0) } }
}

/// Texte nach D3: Ziel-Haltestelle, Linie, Zeit, Gleis, Aenderungen ausdruecklich. Nur oeffentliche Haltestellennamen aus
/// den Fahrplandaten, nie Favoriten-Labels, Adressen oder Koordinaten-Endpunkte.
public enum ReminderText {
    public static func title(_ kind: ReminderAlert.Kind, warnMinutes: Int) -> String {
        switch kind {
        case .warn: String(localized: "In \(warnMinutes) Min. losgehen", bundle: .module)
        case .leave, .snooze: String(localized: "Jetzt losgehen", bundle: .module)
        }
    }

    /// Ausfall oder gerissener Anschluss: gleiche Zeit, aber die Mitteilung sagt es ausdruecklich.
    public static func lostTitle(_ journey: Journey) -> String {
        journey.cancelled || journey.legs.contains { !$0.isWalk && $0.cancelled }
            ? String(localized: "Verbindung fällt aus", bundle: .module)
            : String(localized: "Anschluss reicht nicht mehr", bundle: .module)
    }

    public static func body(_ journey: Journey) -> String {
        guard let first = journey.legs.first(where: { !$0.isWalk }) else {
            let time = journey.departure?.clockText ?? ""
            if let stop = stopName(journey.legs.last?.destination) {
                return String(localized: "Zu Fuß nach \(stop), \(time)", bundle: .module)
            }
            return String(localized: "Zu Fuß, \(time)", bundle: .module)
        }
        var parts: [String] = []
        if let time = (first.departure ?? first.plannedDeparture)?.clockText {
            let line = first.line?.name ?? String(localized: "Abfahrt", bundle: .module)
            if let planned = first.plannedDeparture?.clockText, planned != time {
                parts.append(String(localized: "\(line) um \(time) statt \(planned)", bundle: .module))
            } else {
                parts.append(String(localized: "\(line) um \(time)", bundle: .module))
            }
        }
        if let stop = stopName(first.origin) { parts.append(String(localized: "ab \(stop)", bundle: .module)) }
        if let platform = first.departurePlatform ?? first.plannedDeparturePlatform {
            if let planned = first.plannedDeparturePlatform, planned != platform {
                parts.append(String(localized: "Gleis \(platform) statt \(planned)", bundle: .module))
            } else {
                parts.append(String(localized: "Gleis \(platform)", bundle: .module))
            }
        }
        if let stop = stopName(journey.legs.last(where: { !$0.isWalk })?.destination) {
            parts.append(String(localized: "nach \(stop)", bundle: .module))
        }
        return parts.joined(separator: ", ")
    }

    private static func stopName(_ place: Place?) -> String? {
        place?.kind == .stop ? place?.name : nil
    }
}

/// Gespeicherte Erinnerung (versiegelt in `PlannedTrip.sealedPlan`). "Frueher" und "Vorwarnen" liegen getrennt von der
/// Rueckwaertsrechnung, damit eine Verschiebung sie nicht ueberschreibt.
/// Neue Felder nur optional (siehe `PlannedTrip.sealedPlan`); `ReminderPersistenceTests` prueft einen festen Alt-Blob.
public struct ReminderPlan: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        case scheduled
        /// Ausfall oder Anschluss reisst: Wecker bleibt zur selben Zeit stehen und nennt das; die App bietet "Nächste Verbindung" an.
        case lost
        /// Backend kann die Fahrt nicht mehr rekonstruieren (410): Zeiten bleiben "ca.", keine weiteren Anfragen.
        case expired
    }

    /// Stand beim Scharfschalten: mit Geometrie und Wegschritten, die Refresh nicht liefert (Navigation braucht sie).
    public private(set) var calibrated: CalibratedJourney
    /// Rueckwaertsrechnung ohne "frueher", Basis fuer `DepartureScheduler.reschedule`.
    public private(set) var scheduled: TimeToLeave
    public let earlierMinutes: Int
    public let warnMinutes: Int
    public let attribution: Attribution
    /// Letzter Refresh, ohne Geometrie.
    public private(set) var live: Journey?
    /// nil = noch nicht neu berechnet (Anzeige "ca.").
    public private(set) var checkedAt: Date?
    /// Letzter Versuch, auch erfolglos; drosselt die Anfragen.
    public var attemptedAt: Date?
    public private(set) var status = Status.scheduled
    /// Stand gespeichert, Mitteilungen noch nicht ersetzt (Fehler, Mitteilungen aus, Absturz dazwischen); der naechste Refresh holt es nach.
    public var alertsPending: Bool?

    /// Erst so kurz vor dem Losgehen wird gefragt (SPEZIFIKATION 4.3); davor gibt es keine Anfragen an Transitous.
    public static let checkLead = NavigationEngine.leaveLead
    /// Hoechstens eine Anfrage je Erinnerung in diesem Abstand.
    public static let checkInterval: TimeInterval = 5 * 60
    public static let snoozeInterval: TimeInterval = 5 * 60
    /// Reicht die Restzeit nicht fuer einen sinnvollen Snooze, entfaellt er.
    public static let snoozeMinimum: TimeInterval = 60

    public init(calibrated: CalibratedJourney, earlierMinutes: Int, warnMinutes: Int, attribution: Attribution,
                scheduler: DepartureScheduler = DepartureScheduler()) throws(TransitError) {
        self.calibrated = calibrated
        scheduled = try scheduler.timeToLeave(for: calibrated)
        self.earlierMinutes = earlierMinutes
        self.warnMinutes = warnMinutes
        self.attribution = attribution
    }

    /// Losgehen inklusive "frueher".
    public var leaveAt: Date { scheduled.leaveAt.addingTimeInterval(-TimeInterval(earlierMinutes * 60)) }
    /// Erste Mitteilung (Anzeige "Erinnerung um").
    public var firstAlarm: Date { leaveAt.addingTimeInterval(-TimeInterval(warnMinutes * 60)) }
    /// Was als naechstes kommt: die Vorwarnung, solange sie vor uns liegt, sonst das Losgehen.
    public func nextAlarm(now: Date) -> Date { firstAlarm > now ? firstAlarm : leaveAt }
    /// Aktuellster Fahrplanstand.
    public var journey: Journey { live ?? calibrated.journey }
    /// Aktuelle Zeiten mit der Geometrie vom Scharfschalten, fuer Navigation und Liste.
    public var navigationJourney: Journey { live?.withGeometry(of: calibrated.journey) ?? calibrated.journey }
    /// D2: "ca.", solange nicht neu berechnet.
    public var isEstimated: Bool { checkedAt == nil || status == .expired }
    /// Echtzeit-Verspaetung des ersten Fahrzeugs in Minuten; nil ohne neuen Stand oder ohne Verspaetung.
    public var delayMinutes: Int? {
        guard let seconds = live?.legs.first(where: { !$0.isWalk })?.departureDelaySeconds, seconds >= 60 else { return nil }
        return seconds / 60
    }

    public var withoutTokens: ReminderPlan {
        var copy = self
        copy.calibrated = calibrated.withRefreshToken(nil)
        copy.live = live?.withRefreshToken(nil)
        return copy
    }

    /// Alles vorbei: Fahrt beendet, die Erinnerung raeumt die App auf.
    public func isOver(now: Date) -> Bool { (journey.arrival ?? scheduled.firstDeparture) < now }

    /// Fuer Badge und Echtzeit-Delta: heute und noch nicht abgefahren.
    public func isActive(now: Date, calendar: Calendar = .current) -> Bool {
        scheduled.firstDeparture > now && calendar.isDate(leaveAt, inSameDayAs: now)
    }

    public func refreshDue(now: Date) -> Bool {
        guard status != .expired, now < scheduled.firstDeparture, now >= leaveAt.addingTimeInterval(-Self.checkLead) else { return false }
        return attemptedAt.map { now.timeIntervalSince($0) >= Self.checkInterval } ?? true
    }

    /// Fruehester Zeitpunkt fuer den naechsten Hintergrund-Lauf; nil = nichts mehr zu pruefen.
    public func nextCheck(now: Date) -> Date? {
        guard status != .expired, now < scheduled.firstDeparture else { return nil }
        return max(now, leaveAt.addingTimeInterval(-Self.checkLead), attemptedAt?.addingTimeInterval(Self.checkInterval) ?? .distantPast)
    }

    /// Ausstehende Mitteilungen. Die Vorwarnung nur, wenn sie noch vor uns liegt; Losgehen schon vorbei, Bahn noch da: sofort.
    public func alerts(tripID: UUID, now: Date) -> [ReminderAlert] {
        var alerts: [ReminderAlert] = []
        if warnMinutes > 0, firstAlarm > now { alerts.append(alert(.warn, tripID, at: firstAlarm)) }
        let shifted = TimeToLeave(leaveAt: leaveAt, firstDeparture: scheduled.firstDeparture,
                                  walkSeconds: scheduled.walkSeconds, bufferSeconds: scheduled.bufferSeconds)
        if let leave = shifted.pendingStages(now: now).first(where: { $0.stage == .leaveNow }) {
            alerts.append(alert(.leave, tripID, at: leave.at))
        }
        return alerts
    }

    /// "Spaeter erinnern": 5 Min., aber nie nach dem letzten Moment, an dem man die Bahn noch erreicht. Kommt die
    /// T-0-Mitteilung ohnehin vorher oder bleibt keine sinnvolle Zeit, entfaellt der Snooze.
    public func snoozeTime(now: Date) -> Date? {
        let latest = scheduled.leaveAt.addingTimeInterval(TimeInterval(scheduled.bufferSeconds))
        let wish = now.addingTimeInterval(Self.snoozeInterval)
        guard latest.timeIntervalSince(now) >= Self.snoozeMinimum, leaveAt <= now || leaveAt > wish else { return nil }
        return min(wish, latest)
    }

    public func snoozeAlert(tripID: UUID, now: Date) -> ReminderAlert? {
        snoozeTime(now: now).map { alert(.snooze, tripID, at: $0) }
    }

    /// Wertet einen Refresh aus und meldet, ob die Mitteilungen ersetzt werden muessen: bei Verschiebung und bei geaendertem
    /// Text (Gleis, Zeit, Ausfall). `.connectionLost` laesst die Zeit stehen; der Wecker wird nie still auf eine andere
    /// Verbindung gestellt.
    public mutating func apply(_ fresh: Journey, now: Date, scheduler: DepartureScheduler = DepartureScheduler()) -> Bool {
        let textBefore = alertTexts
        let update = scheduler.reschedule(scheduled, with: calibrated.replacingJourney(fresh))
        live = fresh.withRefreshToken(nil)
        checkedAt = now
        switch update {
        case .connectionLost:
            status = .lost
        case .unchanged:
            status = .scheduled
        case .shifted(let next, _):
            status = .scheduled
            scheduled = next
            return true
        }
        return alertTexts != textBefore
    }

    public mutating func markExpired() { status = .expired }

    private var alertTexts: [String] { ReminderAlert.Kind.allCases.map(title) + [ReminderText.body(journey)] }

    private func title(_ kind: ReminderAlert.Kind) -> String {
        status == .lost ? ReminderText.lostTitle(journey) : ReminderText.title(kind, warnMinutes: warnMinutes)
    }

    private func alert(_ kind: ReminderAlert.Kind, _ tripID: UUID, at date: Date) -> ReminderAlert {
        ReminderAlert(tripID: tripID, kind: kind, title: title(kind), body: ReminderText.body(journey), fireAt: date)
    }
}
