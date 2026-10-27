import Foundation

/// Lange Zeitspannen lesbar: unter 1 Std. "45 Min.", unter 1 Tag "2 Std. 5 Min.", sonst "2 Tg. 13 Std.".
/// Ohne Tausenderpunkt ("3.705 Min." war nicht lesbar). Nullteile entfallen.
public enum DurationLabel {
    public static func short(minutes: Int) -> String {
        let m = max(0, minutes)
        let (days, hours, rest) = (m / 1440, m % 1440 / 60, m % 60)
        if days > 0 { return hours == 0 ? "\(days) Tg." : "\(days) Tg. \(hours) Std." }
        if hours > 0 { return rest == 0 ? "\(hours) Std." : "\(hours) Std. \(rest) Min." }
        return "\(m) Min."
    }
}

extension Journey {
    /// Strafe fuer einen knappen Umstieg (unter `TransferCheck.minimumSlackSeconds`).
    static let tightTransferPenalty: TimeInterval = 15 * 60
    /// Strafe fuer einen Umstieg, der nicht reicht: nur beste, wenn es keine andere gibt.
    static let missedTransferPenalty: TimeInterval = 7 * 24 * 3600

    /// Rang fuer "beste Verbindung": frueheste Ankunft plus 8 Min. je Umstieg (Gehen zaehlt nicht extra) plus Strafe
    /// fuer knappe bzw. nicht machbare Umstiege. Bei Ankunftszeit-Suche zaehlt die spaeteste Abfahrt.
    /// MOTIS sortiert nach Abfahrt, das war oft nicht die beste.
    func rank(arrivalSearch: Bool) -> TimeInterval {
        let penalty = TimeInterval(transfers * 480) + transferPenalty
        if arrivalSearch { return -(departure ?? .distantPast).timeIntervalSince1970 + penalty }
        return (arrival ?? .distantFuture).timeIntervalSince1970 + penalty
    }

    /// Geplanter Puffer je Umstieg (Ankunft, Abfahrt, Gehzeit des Umstiegswegs), dieselbe Rechnung wie unterwegs.
    private var transferPenalty: TimeInterval {
        legs.filter { !$0.isWalk }.dropFirst().reduce(0) { sum, leg in
            let status = NavigationEngine.buffer(journey: self, vehicle: leg.index, walks: [:], position: nil,
                                                 now: .distantPast, pace: WalkingPaceFactor())?.status
            return sum + (status == .missed ? Self.missedTransferPenalty : status == .tight ? Self.tightTransferPenalty : 0)
        }
    }
}

extension RoutesResponse {
    /// Beste Verbindung nach vorn, der Rest bleibt in Abfahrtsreihenfolge.
    public func bestFirst(arrivalSearch: Bool) -> RoutesResponse {
        guard let best = journeys.indices.min(by: { journeys[$0].rank(arrivalSearch: arrivalSearch) < journeys[$1].rank(arrivalSearch: arrivalSearch) })
        else { return self }
        return movingToFront(best)
    }

    /// Verbindung `index` an die erste Stelle, die uebrigen behalten ihre Reihenfolge.
    public func movingToFront(_ index: Int) -> RoutesResponse {
        guard index > 0, journeys.indices.contains(index) else { return self }
        var list = journeys
        list.insert(list.remove(at: index), at: 0)
        return RoutesResponse(journeys: list, earlierRef: earlierRef, laterRef: laterRef, walkOnly: walkOnly,
                              removedLongDistance: removedLongDistance, fetchedAt: fetchedAt, attribution: attribution)
    }
}

extension CalibratedJourney {
    /// Wie `Journey.rank`, aber mit kalibrierten Gehzeiten: Ankunft inkl. letztem Fussweg, Puffer im gelernten Tempo.
    func rank(arrivalSearch: Bool) -> TimeInterval {
        let penalty = TimeInterval(journey.transfers * 480) + transfers.reduce(0) {
            $0 + ($1.status == .missed ? Journey.missedTransferPenalty : $1.status == .tight ? Journey.tightTransferPenalty : 0)
        }
        if arrivalSearch { return -(departureFromOrigin ?? .distantPast).timeIntervalSince1970 + penalty }
        return (arrivalAtDestination ?? .distantFuture).timeIntervalSince1970 + penalty
    }

    /// Index der besten kalibrierten Verbindung.
    static func bestIndex(_ list: [CalibratedJourney], arrivalSearch: Bool) -> Int? {
        list.indices.min { list[$0].rank(arrivalSearch: arrivalSearch) < list[$1].rank(arrivalSearch: arrivalSearch) }
    }
}
