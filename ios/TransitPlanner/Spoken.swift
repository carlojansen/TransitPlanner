import Foundation
import TransitCore

/// VoiceOver-Saetze (AGENT.md 4.3.3, DESIGN.md 3, 3d, 3e). Rein und testbar; `now` kommt aus einer TimelineView.
enum Spoken {
    static func lineName(_ leg: Leg) -> String {
        let name = [leg.displayMode.displayName, leg.line?.name].compactMap { $0 }.joined(separator: " ")
        return leg.replacement ? String(localized: "Ersatzverkehr \(name)") : name
    }

    /// "Beste Verbindung: In 7 Minuten losgehen. 6 Minuten Fußweg, dann RE 5 Richtung Koblenz, 3 Minuten verspätet. Gleis 7."
    static func hero(_ journey: Journey, calibrated: CalibratedJourney?, now: Date) -> String {
        String(localized: "Beste Verbindung:") + " " + Spoken.journey(journey, calibrated: calibrated, now: now)
    }

    static func journey(_ journey: Journey, calibrated: CalibratedJourney?, now: Date) -> String {
        var parts: [String] = []
        if let leave = calibrated?.departureFromOrigin ?? journey.departure {
            let minutes = Int((leave.timeIntervalSince(now) / 60).rounded(.down))
            if minutes > 0 {
                parts.append(String(localized: "In \(minutes) Minuten losgehen") + ".")
            } else {
                parts.append(String(localized: "Jetzt losgehen."))
            }
        }
        var route: [String] = []
        for leg in journey.legs {
            if leg.isWalk {
                let seconds = calibrated?.walks[leg.index]?.seconds ?? leg.durationSeconds ?? 0
                let minutes = Int((Double(seconds) / 60).rounded(.up))
                if minutes > 0 { route.append(String(localized: "\(minutes) Minuten Fußweg")) }
            } else {
                var text = lineName(leg)
                if let direction = leg.direction { text += " " + String(localized: "Richtung \(direction)") }
                if let delay = leg.departureDelayMinutes { text += ", " + String(localized: "\(delay) Minuten verspätet") }
                route.append(text)
            }
        }
        if !route.isEmpty { parts.append(route.joined(separator: String(localized: ", dann ")) + ".") }
        if let platform = journey.legs.first(where: { !$0.isWalk })?.departurePlatform {
            parts.append(String(localized: "Gleis \(platform)."))
        }
        if let arrive = calibrated?.arrivalAtDestination ?? journey.arrival {
            parts.append(String(localized: "Ankunft \(arrive.formatted(date: .omitted, time: .shortened))."))
        }
        parts.append(journey.transfers == 0 ? String(localized: "Direkt.") : String(localized: "\(journey.transfers) Umstiege") + ".")
        if let sev = sev(journey) { parts.append(sev) }
        if calibrated?.transfers.contains(where: \.isAtRisk) == true { parts.append(String(localized: "Umstieg knapp.")) }
        if journey.cancelled { parts.append(String(localized: "Fällt aus.")) }
        return parts.joined(separator: " ")
    }

    /// "Achtung, Ersatzverkehr: Bus SEV RE 5 bis Köln Hbf, Abfahrt Bilk S Bus."
    static func sev(_ journey: Journey) -> String? {
        guard let leg = journey.legs.first(where: \.replacement) else { return nil }
        var text = String(localized: "Achtung, Ersatzverkehr:") + " " + [leg.displayMode.displayName, leg.line?.name]
            .compactMap { $0 }.joined(separator: " ")
        if let to = leg.destination.name { text += " " + String(localized: "bis \(to)") }
        if let from = leg.origin.name { text += ", " + String(localized: "Abfahrt \(from)") }
        return text + "."
    }

    /// "13:10, Köln Hbf, Gleis 7 statt 10, 3 Minuten später, RE 5 Richtung Koblenz."
    static func station(time: Date?, name: String?, platform: String?, plannedPlatform: String?,
                        delayMinutes: Int?, leg: Leg?) -> String {
        var parts: [String] = []
        if let time { parts.append(time.formatted(date: .omitted, time: .shortened)) }
        if let name { parts.append(name) }
        if let platform {
            if let plannedPlatform, plannedPlatform != platform {
                parts.append(String(localized: "Gleis \(platform) statt \(plannedPlatform)"))
            } else {
                parts.append(String(localized: "Gleis \(platform)"))
            }
        }
        if let delayMinutes { parts.append(String(localized: "\(delayMinutes) Minuten später")) }
        if let leg {
            var line = lineName(leg)
            if let direction = leg.direction { line += " " + String(localized: "Richtung \(direction)") }
            parts.append(line)
        }
        return parts.joined(separator: ", ") + "."
    }

    /// "Treppe, nach unten, Ebene 1 zu 0, 20 Meter."
    static func step(_ step: Step) -> String {
        var parts = [step.direction.spokenName]
        if let street = step.streetName { parts.append(street) }
        if let from = step.fromLevel, let to = step.toLevel, from != to {
            parts.append(to > from ? String(localized: "nach oben") : String(localized: "nach unten"))
            parts.append(String(localized: "Ebene \(from.formatted(.number)) zu \(to.formatted(.number))"))
        }
        if let meters = step.distanceMeters { parts.append(String(localized: "\(meters) Meter")) }
        return parts.joined(separator: ", ") + "."
    }
}
