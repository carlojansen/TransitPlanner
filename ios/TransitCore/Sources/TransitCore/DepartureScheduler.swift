import Foundation

/// Eskalationsstufen der Erinnerung (SPEZIFIKATION 4.3), Wert = Sekunden vor dem Aufbruch.
public enum ReminderStage: Int, Sendable, CaseIterable, Comparable {
    case liveActivity = 900
    case headsUp = 300
    case leaveNow = 0

    public static func < (a: ReminderStage, b: ReminderStage) -> Bool { a.rawValue > b.rawValue }
}

public struct TimeToLeave: Codable, Sendable, Hashable {
    /// Aufbruchszeit
    public let leaveAt: Date
    /// Abfahrt des ersten Fahrzeugs inkl. Echtzeit (bei reinem Fussweg: Start des Fusswegs)
    public let firstDeparture: Date
    public let walkSeconds: Int
    public let bufferSeconds: Int

    /// Noch ausstehende Stufen; bereits vergangene entfallen (ausser `leaveNow`, solange die Bahn noch nicht weg ist).
    public func pendingStages(now: Date) -> [(stage: ReminderStage, at: Date)] {
        ReminderStage.allCases.sorted().compactMap { stage in
            let at = leaveAt.addingTimeInterval(-TimeInterval(stage.rawValue))
            if at > now { return (stage, at) }
            if stage == .leaveNow, firstDeparture > now { return (stage, now) }
            return nil
        }
    }
}

public enum ScheduleUpdate: Sendable, Hashable {
    case unchanged(TimeToLeave)
    /// Wecker verschieben (positiv = spaeter, z. B. bei Verspaetung)
    case shifted(TimeToLeave, bySeconds: Int)
    /// Ausfall oder Anschluss nicht zu schaffen: Wecker bleibt stehen, die App bietet "Nächste Verbindung" an.
    case connectionLost
}

/// Rueckwaertsrechnung: `Aufbruch = Abfahrt_Bahn_1 (inkl. Delay) - kalibrierte Gehzeit - Stationspuffer`.
public struct DepartureScheduler: Sendable {
    public var stationBufferSeconds: Int
    /// Kleinere Abweichungen verschieben den Wecker nicht (kein Flattern bei +-30 s Echtzeit-Rauschen).
    public var shiftThresholdSeconds: Int

    public init(stationBufferSeconds: Int = 120, shiftThresholdSeconds: Int = 60) {
        self.stationBufferSeconds = stationBufferSeconds
        self.shiftThresholdSeconds = shiftThresholdSeconds
    }

    public func timeToLeave(for calibrated: CalibratedJourney) throws(TransitError) -> TimeToLeave {
        let journey = calibrated.journey
        guard !journey.cancelled else { throw .noConnections }
        guard let firstTransit = journey.legs.first(where: { !$0.isWalk }) else {
            // Reiner Fussweg: kein Fahrzeug, kein Puffer.
            guard let start = journey.departure ?? journey.legs.first?.departure else { throw .noConnections }
            return TimeToLeave(leaveAt: start, firstDeparture: start, walkSeconds: calibrated.accessWalkSeconds, bufferSeconds: 0)
        }
        // `departure` enthaelt bereits die Echtzeit; ohne Echtzeit ist es die Planzeit.
        guard let departure = firstTransit.departure ?? firstTransit.plannedDeparture else { throw .noConnections }
        let walk = calibrated.accessWalkSeconds
        let leaveAt = departure.addingTimeInterval(-TimeInterval(walk + stationBufferSeconds))
        return TimeToLeave(leaveAt: leaveAt, firstDeparture: departure, walkSeconds: walk, bufferSeconds: stationBufferSeconds)
    }

    /// Nach einem Refresh: Wecker verschieben, beibehalten oder Verbindung verwerfen.
    public func reschedule(_ previous: TimeToLeave, with refreshed: CalibratedJourney) -> ScheduleUpdate {
        guard !refreshed.journey.cancelled, !refreshed.transfers.contains(where: { $0.status == .missed }),
              let next = try? timeToLeave(for: refreshed)
        else { return .connectionLost }
        let delta = Int(next.leaveAt.timeIntervalSince(previous.leaveAt))
        return abs(delta) >= shiftThresholdSeconds ? .shifted(next, bySeconds: delta) : .unchanged(previous)
    }
}
