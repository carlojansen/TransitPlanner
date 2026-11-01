import Foundation
import TransitCore

/// Inhalt der Jetzt-Karte (DESIGN.md C): Eyebrow, Ueberschrift, Kontextzeile, genau drei Zahlen, optional Hinweis.
struct NowCard: Sendable, Equatable {
    enum Value: Sendable, Equatable {
        case time(Date?)
        case minutes(Int)
        case buffer(seconds: Int, status: WalkBuffer.Status)
        case meters(Int?)
        case text(String)
    }

    struct Metric: Sendable, Equatable {
        let label: String
        let value: Value
    }

    struct Hint: Sendable, Equatable {
        enum Action: Sendable, Equatable { case nextConnection }
        let text: String
        let symbol: String
        let tone: Tone
        var action: Action?
    }

    enum Variant: Sendable, Equatable { case waiting, walk, platform, onBoard, transfer, replacement, finalWalk, arrived }

    let variant: Variant
    let eyebrow: String
    let headline: String
    /// Linien-Badge neben der Ueberschrift (4b, 4e)
    var badgeLeg: Leg?
    /// VoiceOver-Fassung der Ueberschrift, falls sie Zeichen enthaelt (4d: "Gleis 11 nach Gleis 2" statt Pfeil)
    var spokenHeadline: String?
    let context: String
    let metrics: [Metric]
    var hint: Hint?
    /// Gehen: naechste Wegaenderung gross (Symbol, Meter), darunter die uebernaechste
    var maneuver: Maneuver?

    struct Maneuver: Sendable, Equatable {
        let symbol: String
        let title: String
        let meters: Int
        /// "Danach: Treppe runter"
        var then: String?
        /// Treppe: eigenes Warnsymbol-Verhalten in der Anzeige (Akzentfarbe Orange)
        var isStairs: Bool
    }
}

/// Restfahrt im Danach-Sheet: alle noch kommenden Etappen ab jetzt, die aktuelle zuerst, erledigte fallen weg.
struct RouteOverview: Sendable, Equatable {
    struct Row: Sendable, Equatable, Identifiable {
        enum Kind: Sendable, Equatable { case walk, ride, transfer }
        /// Leg-Index; Umstieg ohne eigenen Fussweg: "t" + Index des naechsten Fahrzeugs
        let id: String
        let kind: Kind
        /// Beginn der Etappe (Abfahrt, Ankunft am Umsteigehalt, Losgehen)
        let time: Date?
        /// Fahrt: Linien-Badge
        var leg: Leg?
        let title: String
        let detail: String
        /// Puffer vor dem naechsten Fahrzeug (Umstieg bzw. Weg zum ersten Halt)
        var buffer: WalkBuffer?
        let isCurrent: Bool
        /// Umsteigehalt (nur Umstieg)
        var stop: String?
        /// Punkt fuer "auf der Karte zeigen"
        let coordinate: GeoCoordinate?
        let spoken: String
    }

    struct Tightest: Sendable, Equatable {
        let stop: String
        let buffer: WalkBuffer
        let coordinate: GeoCoordinate?
    }

    let arrival: Date?
    let rows: [Row]
    /// Engster Umstieg, nur wenn knapp (unter 2 Min.) oder zu kurz
    let tightest: Tightest?
    /// Restroute fuer "Ganze Route" (Polylines bzw. Halte)
    let points: [GeoCoordinate]
}

extension Tone: Equatable {}

/// Reine Ableitung der Anzeige aus Zustand, Verbindung und Position (ohne SwiftUI, testbar).
enum NavigationPresenter {
    struct Input {
        let step: NavigationStep
        /// Aktuelle Zeiten
        let journey: Journey
        /// Geometrie und Wegschritte (Original vor dem Refresh)
        let geometry: Journey
        let walks: [Int: WalkEstimate]
        let position: GeoCoordinate?
        let now: Date
        let pace: WalkingPaceFactor
        let destinationLabel: String
        let startedAt: Date?
        let expired: Bool
    }

    static func card(_ input: Input) -> NowCard {
        let j = input.journey
        var card = stepCard(input, input.step)
        // Hinweis-Prioritaet: Ausfall/Meldung (kritisch) > nicht mehr aktualisierbar > Anschluss verpasst > Gleiswechsel.
        if let critical = criticalHint(j, step: input.step) {
            card.hint = critical
        } else if input.expired, input.step != .arrived {
            card.hint = NowCard.Hint(text: String(localized: "Die Verbindung ist nicht mehr aktuell."),
                                     symbol: "clock.arrow.circlepath", tone: .alert, action: .nextConnection)
        }
        return card
    }

    private static func stepCard(_ input: Input, _ step: NavigationStep) -> NowCard {
        let base: NowCard
        switch step {
        case .waitingToLeave(let v):
            base = waitingCard(input, vehicle: v)
        case .missedDeparture(let v):
            // Fussweg- bzw. Umstiegskarte; der Puffer ist negativ und zeigt "Das reicht nicht mehr."
            base = stepCard(input, NavigationEngine.walkingStep(toward: v, in: input.journey))
        case .approachingFirstStop(let v):
            base = walkCard(input, vehicle: v)
        case .waitingAtPlatform(let v):
            base = platformCard(input, vehicle: v)
        case .onBoardTransit(let v):
            base = onBoardCard(input, vehicle: v)
        case .transferRouting(let from, let to):
            base = transferCard(input, from: from, to: to)
        case .finalWalkToDestination:
            base = finalWalkCard(input)
        case .arrived:
            base = arrivedCard(input)
        }
        return base
    }

    // MARK: Zustaende

    private static func leg(_ index: Int, _ journey: Journey) -> Leg? {
        journey.legs.first { $0.index == index }
    }

    /// Fahrt weit voraus: Abfahrt und "Losgehen in", keine Wegschritte, kein Puffer.
    private static func waitingCard(_ input: Input, vehicle v: Int) -> NowCard {
        let vehicle = leg(v, input.journey)
        let departure = vehicle?.departure ?? vehicle?.plannedDeparture
        // Losgehen = dieselbe Zeit wie die Schwelle der Engine, damit die Karte an der Schwelle nicht springt.
        let leave = NavigationEngine.leaveTime(input.journey)
        let when = departure.map { $0.formatted(.dateTime.weekday(.abbreviated)) + " " + $0.clockText } ?? "–"
        var context = String(localized: "Abfahrt \(when) ab \(vehicle?.origin.name ?? "")")
        if let platform = vehicle?.departurePlatform { context += ", " + String(localized: "Gleis \(platform)") }
        if let vehicle { context += " · " + vehicle.badgeText }
        let arrival = input.journey.legs.last.flatMap { $0.arrival ?? $0.plannedArrival }
        return NowCard(variant: .waiting, eyebrow: String(localized: "Fahrt geplant"),
                       headline: leave.map { String(localized: "Losgehen in \(DurationLabel.short(minutes: minutes(until: $0, input.now)))") }
                           ?? String(localized: "Abfahrt \(when)"),
                       context: context,
                       metrics: [
                           NowCard.Metric(label: String(localized: "Losgehen"), value: .time(leave)),
                           NowCard.Metric(label: String(localized: "Abfahrt"), value: .time(departure)),
                           NowCard.Metric(label: String(localized: "Ankunft"), value: .time(arrival)),
                       ])
    }

    /// 4 Fussweg zum Gleis: Ueberschrift = naechste Wegaenderung.
    private static func walkCard(_ input: Input, vehicle v: Int) -> NowCard {
        let vehicle = leg(v, input.journey)
        let walk = NavigationEngine.walkLeg(before: v, in: input.geometry)
        let stop = vehicle?.origin.name ?? ""
        let headline = walk.map { instruction(NavigationEngine.guidance(walk: $0, position: input.position), target: stop) }
            ?? String(localized: "Zu \(stop)")
        var context = String(localized: "Zu \(stop)")
        if let platform = vehicle?.departurePlatform { context += ", " + String(localized: "Gleis \(platform)") }
        if let vehicle { context += " · " + vehicle.badgeText }
        var card = NowCard(variant: .walk, eyebrow: String(localized: "Zu Fuß zum Gleis"), headline: headline,
                           context: context, metrics: departureMetrics(vehicle, input, third: bufferMetric(input, v)))
        card.hint = bufferHint(input, vehicle: v) ?? platformHint(vehicle)
        card.maneuver = walk.flatMap { maneuver(NavigationEngine.guidance(walk: $0, position: input.position)) }
        return card
    }

    /// Grosse Wegaenderung fuer die Karte; nil ohne Position oder ohne Manoever (dann steht "Noch 120 m").
    static func maneuver(_ g: WalkGuidance) -> NowCard.Maneuver? {
        guard let step = g.nextStep, let meters = g.metersToNextStep else { return nil }
        return NowCard.Maneuver(symbol: step.symbolName, title: maneuver(step), meters: meters,
                                then: g.thenStep.map { String(localized: "Danach: \(maneuver($0))") },
                                isStairs: step.direction == .stairs || (step.isVertical && step.direction != .elevator))
    }

    /// 4b Am Gleis bzw. 4e Ersatzverkehr.
    private static func platformCard(_ input: Input, vehicle v: Int) -> NowCard {
        guard let vehicle = leg(v, input.journey) else { return finalWalkCard(input) }
        let ride = rideMetric(vehicle)
        if vehicle.replacement {
            var card = NowCard(variant: .replacement, eyebrow: replacementEyebrow(vehicle),
                               headline: String(localized: "Bus ab \(vehicle.origin.name ?? "")"), badgeLeg: vehicle,
                               context: vehicle.direction.map { String(localized: "Richtung \($0)") } ?? vehicle.badgeText,
                               metrics: departureMetrics(vehicle, input, third: ride))
            if let remark = (vehicle.remarks ?? []).first {
                card.hint = NowCard.Hint(text: String(localized: "Meldung des Betreibers: \(remark.summary ?? remark.text)"),
                                         symbol: "exclamationmark.bubble.fill", tone: .alert)
            }
            return card
        }
        let headline = vehicle.departurePlatform.map { String(localized: "Gleis \($0)") } ?? (vehicle.origin.name ?? "")
        var card = NowCard(variant: .platform, eyebrow: String(localized: "Am Gleis"), headline: headline, badgeLeg: vehicle,
                           context: [vehicle.origin.name, vehicle.direction.map { String(localized: "Richtung \($0)") }]
                               .compactMap { $0 }.joined(separator: " · "),
                           metrics: departureMetrics(vehicle, input, third: ride))
        card.hint = platformHint(vehicle)
        return card
    }

    /// 4c Im Zug: Halte herunterzaehlen.
    private static func onBoardCard(_ input: Input, vehicle v: Int) -> NowCard {
        guard let vehicle = leg(v, input.journey) else { return finalWalkCard(input) }
        let headline = exitText(vehicle, now: input.now, row: false)
        let direction = vehicle.direction.map { " " + String(localized: "Richtung \($0)") } ?? ""
        let eyebrow = String(localized: "Im \(vehicle.badgeText)") + direction
        let arrival = vehicle.arrival ?? vehicle.plannedArrival
        var card = NowCard(variant: .onBoard, eyebrow: eyebrow, headline: headline,
                       context: String(localized: "Ausstieg \(vehicle.destination.name ?? "")"),
                       metrics: [
                           NowCard.Metric(label: String(localized: "Ankunft"), value: .time(arrival)),
                           NowCard.Metric(label: String(localized: "Noch"), value: .minutes(minutes(until: arrival, input.now))),
                           NowCard.Metric(label: String(localized: "Danach"), value: .text(afterwards(input, after: v))),
                       ])
        // Spaeterer Anschluss nach Verspaetung nicht mehr zu schaffen: kritisch, mit "Nächste Verbindung" (kein Alert).
        if let broken = NavigationEngine.brokenConnection(after: v, journey: input.journey, walks: input.walks,
                                                          now: input.now, pace: input.pace),
           let next = leg(broken, input.journey) {
            card.hint = NowCard.Hint(text: String(localized: "Anschluss \(next.badgeText) in \(next.origin.name ?? "") reicht nicht mehr."),
                                     symbol: "xmark.octagon.fill", tone: .alert, action: .nextConnection)
        }
        return card
    }

    /// 4d Umstieg: zwei Gleise und der Weg dazwischen (nur aus vorhandenen Daten).
    private static func transferCard(_ input: Input, from: Int, to: Int) -> NowCard {
        let arriving = leg(from, input.journey)
        let next = leg(to, input.journey)
        let a = arriving?.arrivalPlatform.map { String(localized: "Gleis \($0)") } ?? (arriving?.destination.name ?? "")
        let b = next?.departurePlatform.map { String(localized: "Gleis \($0)") } ?? (next?.origin.name ?? "")
        let walk = NavigationEngine.walkLeg(before: to, in: input.geometry)
        var context = walk.map(walkSummary) ?? ""
        if context.isEmpty, let next { context = String(localized: "Weiter mit \(next.badgeText)") }
        var card = NowCard(variant: .transfer, eyebrow: String(localized: "Umstieg in \(next?.badgeText ?? "")"),
                           headline: "\(a) → \(b)", spokenHeadline: String(localized: "\(a) nach \(b)"), context: context,
                           metrics: [
                               NowCard.Metric(label: String(localized: "Ab"), value: .time(next?.departure ?? next?.plannedDeparture)),
                               NowCard.Metric(label: String(localized: "Noch"),
                                              value: .minutes(minutes(until: next?.departure ?? next?.plannedDeparture, input.now))),
                               bufferMetric(input, to),
                           ])
        card.hint = bufferHint(input, vehicle: to) ?? platformHint(next)
        return card
    }

    private static func finalWalkCard(_ input: Input) -> NowCard {
        let walk = input.geometry.legs.last.flatMap { $0.isWalk ? $0 : nil }
        let guidance = walk.map { NavigationEngine.guidance(walk: $0, position: input.position) }
        let remaining = guidance?.remainingMeters ?? walk?.distanceMeters
        let seconds = remaining.map { input.pace.apply(to: Double($0) / NavigationEngine.defaultWalkSpeed) }
            ?? walk.flatMap { input.walks[$0.index]?.seconds ?? $0.durationSeconds } ?? 0
        let headline = guidance.map { instruction($0, target: input.destinationLabel) } ?? String(localized: "Zu \(input.destinationLabel)")
        var card = NowCard(variant: .finalWalk, eyebrow: String(localized: "Zu Fuß zum Ziel"), headline: headline,
                       context: input.destinationLabel,
                       metrics: [
                           NowCard.Metric(label: String(localized: "Ankunft"), value: .time(input.now.addingTimeInterval(TimeInterval(seconds)))),
                           NowCard.Metric(label: String(localized: "Noch"), value: .minutes(Int((Double(seconds) / 60).rounded(.up)))),
                           NowCard.Metric(label: String(localized: "Strecke"), value: .meters(remaining)),
                       ])
        card.maneuver = guidance.flatMap { maneuver($0) }
        return card
    }

    /// 4f Ankunft: Zusammenfassung in drei Zahlen.
    private static func arrivedCard(_ input: Input) -> NowCard {
        let travelled = input.startedAt.map { Int((input.now.timeIntervalSince($0) / 60).rounded()) } ?? 0
        let walkSeconds = input.geometry.legs.filter(\.isWalk).reduce(0) { $0 + (input.walks[$1.index]?.seconds ?? $1.durationSeconds ?? 0) }
        let lastVehicle = input.journey.legs.last { !$0.isWalk }
        let delay = max(0, (lastVehicle?.arrivalDelaySeconds ?? 0) / 60)
        return NowCard(variant: .arrived, eyebrow: String(localized: "Angekommen"), headline: input.destinationLabel,
                       context: String(localized: "Ankunft \(input.now.clockText)"),
                       metrics: [
                           NowCard.Metric(label: String(localized: "Unterwegs"), value: .minutes(travelled)),
                           NowCard.Metric(label: String(localized: "Zu Fuß"), value: .minutes(Int((Double(walkSeconds) / 60).rounded(.up)))),
                           NowCard.Metric(label: String(localized: "Verspätung"), value: .minutes(delay)),
                       ])
    }

    // MARK: Bausteine

    private static func departureMetrics(_ vehicle: Leg?, _ input: Input, third: NowCard.Metric) -> [NowCard.Metric] {
        let departure = vehicle?.departure ?? vehicle?.plannedDeparture
        return [
            NowCard.Metric(label: String(localized: "Abfahrt"), value: .time(departure)),
            NowCard.Metric(label: String(localized: "Noch"), value: .minutes(minutes(until: departure, input.now))),
            third,
        ]
    }

    private static func rideMetric(_ vehicle: Leg) -> NowCard.Metric {
        var seconds = vehicle.durationSeconds ?? 0
        if let d = vehicle.departure, let a = vehicle.arrival { seconds = Int(a.timeIntervalSince(d)) }
        return NowCard.Metric(label: String(localized: "Fahrt"), value: .minutes(Int((Double(seconds) / 60).rounded(.up))))
    }

    private static func bufferMetric(_ input: Input, _ vehicle: Int) -> NowCard.Metric {
        let buffer = NavigationEngine.buffer(journey: input.journey, geometry: input.geometry, vehicle: vehicle, walks: input.walks,
                                             position: input.position, now: input.now, pace: input.pace)
        return NowCard.Metric(label: String(localized: "Puffer"),
                              value: buffer.map { .buffer(seconds: $0.seconds, status: $0.status) } ?? .text("–"))
    }

    /// Puffer reicht nicht: rot, naechste Verbindung direkt in der Karte (kein Alert).
    private static func bufferHint(_ input: Input, vehicle: Int) -> NowCard.Hint? {
        guard let buffer = NavigationEngine.buffer(journey: input.journey, geometry: input.geometry, vehicle: vehicle, walks: input.walks,
                                                   position: input.position, now: input.now, pace: input.pace),
              buffer.status == .missed else { return nil }
        return NowCard.Hint(text: String(localized: "Das reicht nicht mehr."), symbol: "figure.walk.motion",
                            tone: .alert, action: .nextConnection)
    }

    /// Gleiswechsel: "nicht Gleis 10".
    private static func platformHint(_ vehicle: Leg?) -> NowCard.Hint? {
        guard let vehicle, vehicle.platformChanged == true, let planned = vehicle.plannedDeparturePlatform,
              let platform = vehicle.departurePlatform, planned != platform else { return nil }
        return NowCard.Hint(text: String(localized: "Gleis \(platform), nicht Gleis \(planned)"),
                            symbol: "exclamationmark.triangle.fill", tone: .warn)
    }

    /// Ausfall oder Warnmeldung am naechsten Fahrzeug: kritisch, mit "Nächste Verbindung".
    private static func criticalHint(_ journey: Journey, step: NavigationStep) -> NowCard.Hint? {
        guard let v = NavigationEngine.targetVehicle(step), let vehicle = leg(v, journey) else { return nil }
        if vehicle.cancelled || journey.cancelled {
            return NowCard.Hint(text: String(localized: "\(vehicle.badgeText) fällt aus."), symbol: "xmark.octagon.fill",
                                tone: .alert, action: .nextConnection)
        }
        // Meldungen beim Ersatzverkehr stehen schon als "Meldung des Betreibers" in 4e.
        if !vehicle.replacement, let remark = (vehicle.remarks ?? []).first(where: { $0.type == .warning }),
           ["NO_SERVICE", "DETOUR", "STOP_MOVED"].contains(remark.effect ?? "") {
            return NowCard.Hint(text: String(localized: "Meldung des Betreibers: \(remark.summary ?? remark.text)"),
                                symbol: "exclamationmark.bubble.fill", tone: .alert, action: .nextConnection)
        }
        return nil
    }

    private static func replacementEyebrow(_ leg: Leg) -> String {
        let name = leg.line?.name ?? ""
        let replaced = name.uppercased().hasPrefix("SEV ") ? String(name.dropFirst(4)) : ""
        return replaced.isEmpty ? String(localized: "Ersatzverkehr") : String(localized: "Ersatzverkehr statt \(replaced)")
    }

    /// "In 80 m links", "In 20 m Treppe runter", sonst "Noch 120 m zu X". Nichts Erfundenes ohne Daten.
    static func instruction(_ g: WalkGuidance, target: String) -> String {
        if let step = g.nextStep, let meters = g.metersToNextStep {
            return String(localized: "In \(meters) m \(maneuver(step))")
        }
        if let remaining = g.remainingMeters { return String(localized: "Noch \(remaining) m zu \(target)") }
        return String(localized: "Zu \(target)")
    }

    static func maneuver(_ step: Step) -> String {
        let level: String? = {
            guard let from = step.fromLevel, let to = step.toLevel, from != to else { return nil }
            return to > from ? String(localized: "hoch") : String(localized: "runter")
        }()
        switch step.direction {
        case .stairs: return [String(localized: "Treppe"), level].compactMap { $0 }.joined(separator: " ")
        case .elevator: return [String(localized: "Aufzug"), level].compactMap { $0 }.joined(separator: " ")
        case .left, .hardLeft: return String(localized: "links")
        case .slightlyLeft: return String(localized: "leicht links")
        case .right, .hardRight: return String(localized: "rechts")
        case .slightlyRight: return String(localized: "leicht rechts")
        case .uturnLeft, .uturnRight: return String(localized: "wenden")
        case .circleClockwise, .circleCounterclockwise: return String(localized: "in den Kreisverkehr")
        case .depart, .continue, .unknown: return level.map { String(localized: "Ebene \($0)") } ?? String(localized: "geradeaus")
        }
    }

    /// Zeile der Wegbeschreibung: mehrere Treppen als "4 Treppen", sonst wie der einzelne Schritt.
    static func lineTitle(_ line: WalkDirections.Line) -> String {
        line.stairs > 1 ? String(localized: "\(line.stairs) Treppen") : stepTitle(line.step)
    }

    /// Zeile der Wegbeschreibung: "Hüttenstraße folgen", "Rechts abbiegen in Bahnhofstraße", "Treppe runter".
    static func stepTitle(_ step: Step) -> String {
        if step.direction == .stairs || step.direction == .elevator || (step.isVertical && step.isStraight) {
            return maneuver(step)
        }
        if step.isStraight {
            return step.streetName.map { String(localized: "\($0) folgen") } ?? String(localized: "Geradeaus")
        }
        return step.streetName.map { String(localized: "\(step.direction.spokenName) in \($0)") } ?? step.direction.spokenName
    }

    /// 4d Kontext: Ebenenwechsel aus den Schritten und Laenge, ohne Indoor-Daten nur "ca. 180 m".
    static func walkSummary(_ walk: Leg) -> String {
        let changes = walk.steps.filter { ($0.direction == .stairs || $0.direction == .elevator) }.map(maneuver)
        let meters = walk.distanceMeters.map { String(localized: "ca. \($0) m") }
        return (changes + [meters].compactMap { $0 }).joined(separator: ", ")
    }

    /// "Danach" im Zug: Umstieg mit Puffer bzw. Fussweg zum Ziel.
    private static func afterwards(_ input: Input, after v: Int) -> String {
        let vehicles = input.journey.legs.filter { !$0.isWalk }
        if let i = vehicles.firstIndex(where: { $0.index == v }), i + 1 < vehicles.count {
            return String(localized: "Umstieg")
        }
        if let walk = input.geometry.legs.last, walk.isWalk {
            let seconds = input.walks[walk.index]?.seconds ?? walk.durationSeconds ?? 0
            return String(localized: "\(Int((Double(seconds) / 60).rounded(.up))) Min. zu Fuß")
        }
        return String(localized: "Ziel")
    }

    /// "Nächster Halt aussteigen" erst in den letzten `NavigationEngine.exitLead`; vorher "Aussteigen in 22 Min."
    /// (z. B. ICE ohne Zwischenhalt), mit mehr Halten "Aussteigen in 3 Halten". `row`: Zeile der Restfahrt.
    private static func exitText(_ leg: Leg, now: Date, row: Bool) -> String {
        let stops = NavigationEngine.stopsUntilExit(leg: leg, now: now)
        if stops > 1 { return row ? String(localized: "noch \(stops) Halte") : String(localized: "Aussteigen in \(stops) Halten") }
        if !NavigationEngine.exitsNext(leg: leg, now: now) {
            let left = DurationLabel.short(minutes: minutes(until: leg.arrival ?? leg.plannedArrival, now))
            return row ? String(localized: "aussteigen in \(left)") : String(localized: "Aussteigen in \(left)")
        }
        return row ? String(localized: "nächster Halt aussteigen") : String(localized: "Nächster Halt aussteigen")
    }

    private static func minutes(until date: Date?, _ now: Date) -> Int {
        guard let date else { return 0 }
        return max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
    }

    // MARK: Danach-Sheet: Restfahrt

    /// Unter 2 Min. Puffer zeigt die App Sekunden (wie `WalkBuffer.Status.tight`).
    static let tightLimit = 120

    /// Alle noch kommenden Etappen ab jetzt (Fussweg, Fahrt, Umstieg) mit Puffer an jedem Umstieg.
    /// Aktueller Umstieg: Live-Puffer aus Position und Uhr; spaetere: Ankunft vorher -> Abfahrt minus Gehzeit.
    static func overview(_ input: Input) -> RouteOverview {
        let legs = input.journey.legs
        // Erste noch offene Etappe (Leg-Index) bzw. Umstieg vor Fahrzeug `to`.
        let current: Int? = switch input.step {
        case .waitingToLeave(let v), .approachingFirstStop(let v), .missedDeparture(let v): NavigationEngine.walkLeg(before: v, in: input.journey)?.index ?? v
        case .waitingAtPlatform(let v), .onBoardTransit(let v): v
        case .transferRouting(_, let to): NavigationEngine.walkLeg(before: to, in: input.journey)?.index ?? to
        case .finalWalkToDestination: legs.last?.index
        case .arrived: nil
        }
        // Umstieg ohne Fussweg haengt am Fahrzeug selbst: dann ist der Umstieg die aktuelle Etappe.
        let currentIsTransferAt: Int? = if case .transferRouting(_, let to) = input.step,
                                           NavigationEngine.walkLeg(before: to, in: input.journey) == nil { to } else { nil }
        guard let current else {
            return RouteOverview(arrival: arrival(input), rows: [], tightest: nil, points: [])
        }

        var rows: [RouteOverview.Row] = []
        for (i, leg) in legs.enumerated() where leg.index >= current {
            let previous = i > 0 ? legs[i - 1] : nil
            let next = i + 1 < legs.count ? legs[i + 1] : nil
            if leg.isWalk {
                let before = previous.flatMap { $0.isWalk ? nil : $0 }
                let after = next.flatMap { $0.isWalk ? nil : $0 }
                rows.append(walkRow(input, walk: leg, from: before, to: after, isCurrent: leg.index == current))
            } else {
                // Umstieg direkt von Fahrzeug zu Fahrzeug (gleicher Steig, kein Fussweg): eigene Zeile.
                if let previous, !previous.isWalk, leg.index > current || currentIsTransferAt == leg.index {
                    rows.append(walkRow(input, walk: nil, from: previous, to: leg, isCurrent: currentIsTransferAt == leg.index))
                }
                rows.append(rideRow(input, leg, isCurrent: leg.index == current && currentIsTransferAt == nil))
            }
        }

        let tightest = rows.filter { $0.kind == .transfer }
            .compactMap { row in row.buffer.map { (row, $0) } }
            .min { $0.1.seconds < $1.1.seconds }
            .flatMap { row, buffer in
                buffer.status != .comfortable
                    ? RouteOverview.Tightest(stop: row.stop ?? row.title, buffer: buffer, coordinate: row.coordinate) : nil
            }
        let remaining = legs.filter { $0.index >= current }.map(\.index)
        let points = input.geometry.legs.filter { remaining.contains($0.index) }.flatMap { leg in
            leg.polyline?.points ?? [leg.origin.coordinate, leg.destination.coordinate].compactMap { $0 }
        }
        return RouteOverview(arrival: arrival(input), rows: rows, tightest: tightest, points: points)
    }

    /// Ankunft am Ziel: letzte Ankunft (Echtzeit) plus kalibrierter Weg zum Ziel.
    private static func arrival(_ input: Input) -> Date? {
        let legs = input.journey.legs
        guard let last = legs.last, last.isWalk, let vehicle = legs.last(where: { !$0.isWalk }),
              let reached = vehicle.arrival ?? vehicle.plannedArrival else { return legs.last?.arrival ?? input.journey.arrival }
        return reached.addingTimeInterval(TimeInterval(input.walks[last.index]?.seconds ?? last.durationSeconds ?? 0))
    }

    /// Fussweg zum ersten Halt, Umstieg (zwischen zwei Fahrzeugen) oder Weg zum Ziel.
    private static func walkRow(_ input: Input, walk: Leg?, from: Leg?, to: Leg?, isCurrent: Bool) -> RouteOverview.Row {
        let seconds = walk.map { input.walks[$0.index]?.seconds ?? $0.durationSeconds ?? 0 } ?? 0
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        let geometry = walk.flatMap { w in input.geometry.legs.first { $0.index == w.index } }
        let distance = (geometry ?? walk)?.distanceMeters
        // Puffer vor dem naechsten Fahrzeug; dieselbe Rechnung wie die Jetzt-Karte (vor der Ankunft zaehlt die Ankunft).
        // Im Wartezustand kein Puffer ab jetzt fuer den Zugangsweg (waere Tage lang); Umstiege bleiben.
        let waiting = if case .waitingToLeave = input.step { from == nil } else { false }
        let buffer = waiting ? nil : to.flatMap {
            NavigationEngine.buffer(journey: input.journey, geometry: input.geometry, vehicle: $0.index, walks: input.walks,
                                    position: isCurrent ? input.position : nil, now: input.now, pace: input.pace)
        }
        let walkText = walk == nil ? nil : String(localized: "\(minutes) Min. zu Fuß")
        let id = walk.map { String($0.index) } ?? "t\(to?.index ?? 0)"

        if let from, let to {
            let stop = from.destination.name ?? to.origin.name ?? ""
            let a = from.arrivalPlatform.map { String(localized: "Gleis \($0)") }
            let b = to.departurePlatform.map { String(localized: "Gleis \($0)") }
            let platforms: String? = switch (a, b) {
            case let (a?, b?): "\(a) → \(b)"
            case let (a?, nil): a
            case let (nil, b?): b
            case (nil, nil): nil
            }
            let spokenPlatforms: String? = if let a, let b { String(localized: "\(a) nach \(b)") } else { platforms }
            let detail = [platforms, walkText].compactMap { $0 }.joined(separator: " · ")
            let spokenWalk = walk == nil ? nil : String(localized: "\(minutes) Minuten Fußweg")
            let time = from.arrival ?? from.plannedArrival
            let spoken = [time.map(spokenTime), String(localized: "Umstieg in \(stop)"), spokenPlatforms, spokenWalk,
                          buffer.map(spokenBufferStatus)].compactMap { $0 }
            return RouteOverview.Row(id: id, kind: .transfer, time: time, title: String(localized: "Umstieg \(stop)"),
                                     detail: detail, buffer: buffer, isCurrent: isCurrent, stop: stop,
                                     coordinate: walk?.origin.coordinate ?? from.destination.coordinate,
                                     spoken: rowSpoken(spoken, isCurrent: isCurrent))
        }
        let isFinal = to == nil
        let target = isFinal ? input.destinationLabel : (to?.origin.name ?? walk?.destination.name ?? "")
        let time = from.flatMap { $0.arrival ?? $0.plannedArrival } ?? walk.flatMap { $0.departure ?? $0.plannedDeparture }
        let platform = to?.departurePlatform.map { String(localized: "Gleis \($0)") }
        let detail = [walkText, distance.map { String(localized: "ca. \($0) m") }, platform].compactMap { $0 }.joined(separator: " · ")
        let spoken = [time.map(spokenTime), String(localized: "Zu Fuß zu \(target)"), String(localized: "\(minutes) Minuten"),
                      platform, buffer.map(spokenBufferStatus)].compactMap { $0 }
        return RouteOverview.Row(id: id, kind: .walk, time: time, title: String(localized: "Zu Fuß zu \(target)"),
                                 detail: detail, buffer: buffer, isCurrent: isCurrent,
                                 coordinate: (walk?.destination ?? to?.origin)?.coordinate,
                                 spoken: rowSpoken(spoken, isCurrent: isCurrent))
    }

    private static func rideRow(_ input: Input, _ leg: Leg, isCurrent: Bool) -> RouteOverview.Row {
        let departure = leg.departure ?? leg.plannedDeparture
        let arrival = leg.arrival ?? leg.plannedArrival
        let from = leg.departurePlatform.map { String(localized: "ab Gleis \($0)") }
            ?? leg.origin.name.map { String(localized: "ab \($0)") }
        let to = [arrival.map { String(localized: "an \(spokenTime($0))") },
                  leg.arrivalPlatform.map { String(localized: "Gleis \($0)") }].compactMap { $0 }.joined(separator: " ")
        // Im Fahrzeug: Halte bis zum Ausstieg statt der Abfahrt, die schon war.
        var stops: String?
        if isCurrent, case .onBoardTransit = input.step {
            stops = exitText(leg, now: input.now, row: true)
        }
        let detail = [stops ?? from, to.isEmpty ? nil : to].compactMap { $0 }.joined(separator: " · ")
        var spoken = [departure.map(spokenTime), Spoken.lineName(leg)]
        if let d = leg.departureDelayMinutes { spoken.append(String(localized: "\(d) Minuten verspätet")) }
        spoken += [leg.origin.name.map { String(localized: "ab \($0)") }, leg.departurePlatform.map { String(localized: "Gleis \($0)") },
                   leg.destination.name.map { String(localized: "bis \($0)") },
                   arrival.map { String(localized: "an \(spokenTime($0))") },
                   leg.arrivalPlatform.map { String(localized: "Gleis \($0)") }, stops]
        if leg.cancelled { spoken.append(String(localized: "Fällt aus")) }
        return RouteOverview.Row(id: String(leg.index), kind: .ride, time: departure, leg: leg,
                                 title: leg.destination.name.map { String(localized: "bis \($0)") } ?? "",
                                 detail: detail, isCurrent: isCurrent,
                                 coordinate: isCurrent ? leg.destination.coordinate : leg.origin.coordinate,
                                 spoken: rowSpoken(spoken.compactMap { $0 }, isCurrent: isCurrent))
    }

    private static func rowSpoken(_ parts: [String], isCurrent: Bool) -> String {
        ((isCurrent ? [String(localized: "Jetzt")] : []) + parts).joined(separator: ", ") + "."
    }

    private static func spokenTime(_ date: Date) -> String { date.clockText }

    /// Sichtbar: "Puffer 5 Min.", "Knapp: 20 s", "Reicht nicht" (nie nur Farbe).
    static func bufferLabel(_ buffer: WalkBuffer) -> String {
        switch buffer.status {
        case .comfortable: String(localized: "Puffer \(buffer.seconds / 60) Min.")
        case .tight: String(localized: "Knapp: \(shortBuffer(buffer.seconds))")
        case .missed: String(localized: "Reicht nicht")
        }
    }

    /// "20 s", ab 2 Min. "2 Min.", ab 0 s "reicht nicht" (wie `WalkBuffer.Status.missed`).
    static func shortBuffer(_ seconds: Int) -> String {
        seconds <= 0 ? String(localized: "reicht nicht")
            : seconds < tightLimit ? String(localized: "\(seconds) s") : String(localized: "\(seconds / 60) Min.")
    }

    /// "20 Sekunden", ab 2 Min. "2 Minuten", ab 0 s "reicht nicht".
    static func spokenBuffer(_ seconds: Int) -> String {
        seconds <= 0 ? String(localized: "reicht nicht")
            : seconds < tightLimit ? String(localized: "\(seconds) Sekunden") : String(localized: "\(seconds / 60) Minuten")
    }

    private static func spokenBufferStatus(_ buffer: WalkBuffer) -> String {
        switch buffer.status {
        case .comfortable: String(localized: "Puffer \(spokenBuffer(buffer.seconds))")
        case .tight: String(localized: "knapp, Puffer \(spokenBuffer(buffer.seconds))")
        case .missed: String(localized: "Umstieg reicht nicht")
        }
    }

    /// Kopf: "Restfahrt, Ankunft 09:03, 8 Etappen."
    static func spokenHeader(_ overview: RouteOverview) -> String {
        var parts = [String(localized: "Restfahrt")]
        if let arrival = overview.arrival { parts.append(String(localized: "Ankunft \(spokenTime(arrival))")) }
        parts.append(String(localized: "\(overview.rows.count) Etappen"))
        return parts.joined(separator: ", ") + "."
    }

    /// Sichtbar "Engster Umstieg: Köln Messe/Deutz, 20 s", vorgelesen mit "Sekunden".
    static func tightestText(_ t: RouteOverview.Tightest, spoken: Bool = false) -> String {
        String(localized: "Engster Umstieg: \(t.stop), \(spoken ? spokenBuffer(t.buffer.seconds) : shortBuffer(t.buffer.seconds))")
    }

    /// VoiceOver-Satz der Jetzt-Karte (Ansage bei Zustandswechsel).
    static func spoken(_ card: NowCard) -> String {
        var parts = [card.eyebrow, card.spokenHeadline ?? card.headline]
        if let leg = card.badgeLeg { parts.append(Spoken.lineName(leg)) }
        if !card.context.isEmpty { parts.append(card.context) }
        for metric in card.metrics {
            switch metric.value {
            case .time(let date): parts.append("\(metric.label) \(date?.clockText ?? "–")")
            case .minutes(let m): parts.append("\(metric.label) " + String(localized: "\(m) Minuten"))
            case .buffer(let seconds, _):
                parts.append("\(metric.label) " + spokenBuffer(seconds))
            case .meters(let m): parts.append("\(metric.label) " + (m.map { String(localized: "\($0) Meter") } ?? "–"))
            case .text(let t): parts.append("\(metric.label) \(t)")
            }
        }
        if let hint = card.hint { parts.append(hint.text) }
        return parts.joined(separator: ". ")
    }
}
