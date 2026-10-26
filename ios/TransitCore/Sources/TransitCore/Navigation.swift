import Foundation

/// Zustaende der In-App-Navigation (SPEZIFIKATION 4.2, DESIGN.md C). Indizes sind Leg-Indizes der Verbindung.
public enum NavigationStep: Sendable, Hashable {
    /// 4 Fussweg zum ersten Halt
    case approachingFirstStop(vehicle: Int)
    /// 4b Am Gleis (4e, wenn das Fahrzeug Ersatzverkehr ist)
    case waitingAtPlatform(vehicle: Int)
    /// 4c Im Fahrzeug
    case onBoardTransit(vehicle: Int)
    /// 4d Umstieg: ab 120 s vor Ankunft am Umsteigehalt bis zum naechsten Steig
    case transferRouting(from: Int, to: Int)
    /// Anschluss verpasst (4/4d rot, "Nächste Verbindung"): bleibt bis zum Neuplanen oder Beenden
    case missedDeparture(vehicle: Int)
    /// Fussweg nach dem letzten Ausstieg
    case finalWalkToDestination
    /// 4f
    case arrived

    /// Fortschritt fuer die Monotonie: GPS-Rauschen darf nie einen Schritt zurueck schalten.
    var rank: Int {
        switch self {
        case .approachingFirstStop(let v): v * 10
        case .transferRouting(_, let to): to * 10 + 1
        case .missedDeparture(let v): v * 10 + 1
        case .waitingAtPlatform(let v): v * 10 + 2
        case .onBoardTransit(let v): v * 10 + 3
        case .finalWalkToDestination: Int.max - 1
        case .arrived: Int.max
        }
    }
}

/// Puffer = Zeit, die bis zur Abfahrt uebrig bleibt, wenn man im gelernten Tempo geht.
public struct WalkBuffer: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        /// mindestens 2 Minuten (gruen)
        case comfortable
        /// unter 2 Minuten (orange); unter 90 s zusaetzlich Haptik `.warning`
        case tight
        /// reicht nicht (rot): naechste Verbindung anbieten
        case missed
    }

    public let seconds: Int
    public var status: Status {
        seconds < 0 ? .missed : (seconds < 120 ? .tight : .comfortable)
    }
    /// DESIGN.md C4: Warnhaptik unter 90 s
    public var needsWarning: Bool { seconds < 90 }
}

/// Fussweg-Fuehrung aus `steps` (API v0.3). Ohne Polyline oder Schritte nur die Restdistanz, nichts erfunden.
public struct WalkGuidance: Sendable, Hashable {
    /// Naechste Wegaenderung (z. B. links, Treppe), nil = geradeaus bis zum Ziel des Abschnitts
    public let nextStep: Step?
    /// Meter bis zur naechsten Wegaenderung
    public let metersToNextStep: Int?
    /// Meter bis zum Ende des Fusswegs (Luftlinie, wenn keine Geometrie)
    public let remainingMeters: Int?

    public init(nextStep: Step?, metersToNextStep: Int?, remainingMeters: Int?) {
        self.nextStep = nextStep
        self.metersToNextStep = metersToNextStep
        self.remainingMeters = remainingMeters
    }
}

/// Reine Navigationslogik ohne Seiteneffekte; testbar ohne CoreLocation.
public enum NavigationEngine {
    /// Umkreis um den Halt fuer "am Gleis" (SPEZIFIKATION 4.2: 40 m)
    public static let platformRadius: Double = 40
    /// Umkreis ums Ziel fuer "angekommen" (DESIGN.md 4f: 25 m)
    public static let arrivalRadius: Double = 25
    /// Umstiegsansicht ab 120 s vor Ankunft am Umsteigehalt
    public static let transferLead: TimeInterval = 120
    /// Gehgeschwindigkeit ohne kalibrierte Gehzeit (m/s), wird mit dem WalkingPaceFactor multipliziert
    public static let defaultWalkSpeed: Double = 1.3
    /// "Verpasst" nur mit einem Fix, der hoechstens so alt ist (s); sonst entscheidet die Fahrplanzeit.
    public static let freshFix: TimeInterval = 30

    /// Aktueller Zustand aus Zeit (Echtzeit-Abfahrten/Ankuenfte) und Position; nie hinter `previous` zurueck.
    /// ponytail: Einstieg/Ausstieg nach Fahrplanzeit statt Bewegung entlang der Polyline; bei Bedarf um Geschwindigkeit ergaenzen.
    /// `fix.timestamp` ist der Empfangszeitpunkt auf derselben Uhr wie `now`.
    public static func resolve(journey: Journey, fix: LocationFix?, now: Date, previous: NavigationStep?) -> NavigationStep {
        if let previous, case .missedDeparture = previous { return previous }
        let next = compute(journey: journey, fix: fix, now: now, previous: previous)
        if let previous, next.rank < previous.rank { return previous }
        return next
    }

    static func compute(journey: Journey, fix: LocationFix?, now: Date, previous: NavigationStep?) -> NavigationStep {
        let position = fix?.coordinate
        let vehicles = journey.legs.filter { !$0.isWalk }
        for (k, leg) in vehicles.enumerated() {
            let departure = leg.departure ?? leg.plannedDeparture ?? .distantPast
            let arrival = leg.arrival ?? leg.plannedArrival ?? departure
            if now < departure {
                if within(position, leg.origin, platformRadius) { return .waitingAtPlatform(vehicle: leg.index) }
                return k == 0 ? .approachingFirstStop(vehicle: leg.index)
                              : .transferRouting(from: vehicles[k - 1].index, to: leg.index)
            }
            // Verpasst: abgefahren, frischer Fix sicher (abzueglich Genauigkeit) nicht am Halt und nie "am Gleis".
            // Veralteter oder ungenauer Fix (U-Bahn): Fahrplanzeit wie ohne Position.
            if now < arrival, let fix, now.timeIntervalSince(fix.timestamp) <= freshFix, let stop = leg.origin.coordinate,
               fix.coordinate.distance(to: stop) - fix.horizontalAccuracy > platformRadius,
               (previous?.rank ?? 0) < NavigationStep.waitingAtPlatform(vehicle: leg.index).rank {
                return .missedDeparture(vehicle: leg.index)
            }
            if now < arrival {
                if k < vehicles.count - 1, now >= arrival.addingTimeInterval(-transferLead) {
                    return .transferRouting(from: leg.index, to: vehicles[k + 1].index)
                }
                return .onBoardTransit(vehicle: leg.index)
            }
        }
        if let target = journey.legs.last?.destination, within(position, target, arrivalRadius) { return .arrived }
        return .finalWalkToDestination
    }

    private static func within(_ position: GeoCoordinate?, _ place: Place, _ radius: Double) -> Bool {
        guard let position, let c = place.coordinate else { return false }
        return position.distance(to: c) <= radius
    }

    /// Fahrzeug, auf das der Zustand zulaeuft (fuer Puffer, Gleis, Abfahrt).
    public static func targetVehicle(_ step: NavigationStep) -> Int? {
        switch step {
        case .approachingFirstStop(let v), .waitingAtPlatform(let v), .onBoardTransit(let v), .missedDeparture(let v): v
        case .transferRouting(_, let to): to
        case .finalWalkToDestination, .arrived: nil
        }
    }

    /// Fussweg-Zustand zu einem Fahrzeug (Zugang oder Umstieg), z. B. fuer die Karte eines verpassten Anschlusses.
    public static func walkingStep(toward vehicle: Int, in journey: Journey) -> NavigationStep {
        let vehicles = journey.legs.filter { !$0.isWalk }
        guard let k = vehicles.firstIndex(where: { $0.index == vehicle }), k > 0 else { return .approachingFirstStop(vehicle: vehicle) }
        return .transferRouting(from: vehicles[k - 1].index, to: vehicle)
    }

    /// Fussweg-Abschnitt direkt vor einem Fahrzeug (Zugang oder Umstieg), sonst nil.
    public static func walkLeg(before vehicle: Int, in journey: Journey) -> Leg? {
        guard let i = journey.legs.firstIndex(where: { $0.index == vehicle }), i > 0 else { return nil }
        let leg = journey.legs[i - 1]
        return leg.isWalk ? leg : nil
    }

    /// Puffer bis zur Abfahrt von `vehicle`: Abfahrt - jetzt - verbleibende Gehzeit im gelernten Tempo.
    /// Verbleibende Gehzeit = kalibrierte Gehzeit x Anteil der Restdistanz (entlang der Polylinie, sonst Luftlinie), ohne Kalibrierung Luftlinie / 1,3 m/s x Tempo.
    /// Vor der Ankunft des vorigen Fahrzeugs zaehlt dessen Ankunft statt jetzt, und die Position nicht (man sitzt noch drin).
    /// Zeiten aus `journey` (nach Refresh aktuell), Fussweg mit Polylinie aus `geometry` (Refresh liefert keine Geometrie).
    public static func buffer(journey: Journey, geometry: Journey? = nil, vehicle: Int, walks: [Int: WalkEstimate],
                              position: GeoCoordinate?, now: Date, pace: WalkingPaceFactor) -> WalkBuffer? {
        guard let i = journey.legs.firstIndex(where: { $0.index == vehicle }),
              let departure = journey.legs[i].departure ?? journey.legs[i].plannedDeparture else { return nil }
        var start = now
        var position = position
        if let previous = journey.legs[..<i].last(where: { !$0.isWalk }),
           let arrival = previous.arrival ?? previous.plannedArrival, now < arrival {
            start = arrival
            position = nil
        }
        let walk = walkLeg(before: vehicle, in: geometry ?? journey) ?? walkLeg(before: vehicle, in: journey)
        let remaining = remainingWalkSeconds(to: journey.legs[i].origin, walk: walk,
                                             walks: walks, position: position, pace: pace)
        return WalkBuffer(seconds: Int(departure.timeIntervalSince(start)) - remaining)
    }

    /// Erster spaeterer Anschluss nach `vehicle`, der nach Fahrplan/Echtzeit nicht mehr reicht (z. B. nach Verspaetung).
    public static func brokenConnection(after vehicle: Int, journey: Journey, walks: [Int: WalkEstimate], now: Date,
                                        pace: WalkingPaceFactor) -> Int? {
        journey.legs.filter { !$0.isWalk && $0.index > vehicle }.first { leg in
            buffer(journey: journey, vehicle: leg.index, walks: walks, position: nil, now: now, pace: pace)?.status == .missed
        }?.index
    }

    static func remainingWalkSeconds(to stop: Place, walk: Leg?, walks: [Int: WalkEstimate],
                                     position: GeoCoordinate?, pace: WalkingPaceFactor) -> Int {
        guard let target = stop.coordinate else { return 0 }
        guard let position else {
            return walk.map { walks[$0.index]?.seconds ?? $0.durationSeconds ?? 0 } ?? 0
        }
        let left = position.distance(to: target)
        if let walk, let start = walk.origin.coordinate {
            // Mit Geometrie: Rest entlang des Wegs (Treppen, Umwege im Bahnhof), sonst Anteil der Luftlinie.
            let points = walk.polyline?.points ?? []
            let fraction: Double
            if points.count >= 2 {
                let total = max(PolylineMath.length(points), 1)
                fraction = min(max((total - PolylineMath.distanceAlong(points, to: position)) / total, 0), 1)
            } else {
                fraction = min(max(left / max(start.distance(to: target), 1), 0), 1)
            }
            let full = Double(walks[walk.index]?.seconds ?? walk.durationSeconds ?? 0)
            return Int((full * fraction).rounded(.up))
        }
        return pace.apply(to: left / defaultWalkSpeed)
    }

    /// Fuehrung entlang eines Fusswegs: Fortschritt per Projektion auf die Polyline, Schritte kumuliert.
    public static func guidance(walk leg: Leg, position: GeoCoordinate?) -> WalkGuidance {
        guard let position else { return WalkGuidance(nextStep: nil, metersToNextStep: nil, remainingMeters: nil) }
        let points = leg.polyline?.points ?? []
        guard points.count >= 2 else {
            let left = leg.destination.coordinate.map { Int(position.distance(to: $0).rounded()) }
            return WalkGuidance(nextStep: nil, metersToNextStep: nil, remainingMeters: left)
        }
        let total = PolylineMath.length(points)
        let along = PolylineMath.distanceAlong(points, to: position)
        let remaining = Int(max(total - along, 0).rounded())
        // Schritt i beginnt bei cumulative[i]; die naechste Aenderung ist das erste Manoever (Abbiegen, Treppe,
        // Aufzug), das noch vor uns liegt. Zusammengefasste Schritte: keine Mikroschritte ("In 3 m geradeaus").
        var start = 0.0
        for step in WalkDirections.condensed(leg.steps) {
            if start > along + 1, step.isManeuver {
                return WalkGuidance(nextStep: step, metersToNextStep: Int((start - along).rounded()), remainingMeters: remaining)
            }
            start += Double(step.distanceMeters ?? 0)
        }
        return WalkGuidance(nextStep: nil, metersToNextStep: nil, remainingMeters: remaining)
    }

    /// Halte, die im Fahrzeug noch vor dem Ausstieg kommen (nach Zeit), plus der Ausstieg selbst.
    public static func stopsUntilExit(leg: Leg, now: Date) -> Int {
        let ahead = (leg.stopovers ?? []).filter { ($0.arrival ?? $0.departure ?? .distantPast) > now }.count
        return ahead + 1
    }
}

extension Step {
    /// Ebenenwechsel (Treppe, Rampe, Aufzug) oder ausdrueckliche Treppe/Aufzug.
    public var isVertical: Bool {
        if direction == .stairs || direction == .elevator { return true }
        guard let fromLevel, let toLevel else { return false }
        return fromLevel != toLevel
    }

    /// Ohne Richtungswechsel (Losgehen, geradeaus, unbekannt).
    public var isStraight: Bool { [.depart, .continue, .unknown].contains(direction) }

    /// Etwas, das man tun muss: abbiegen, wenden, Kreisverkehr, Treppe, Aufzug, Ebenenwechsel.
    public var isManeuver: Bool { isVertical || !isStraight }
}

/// Lesbare Wegbeschreibung aus OSM-Schritten: OSM zerlegt eine Strasse oft in viele Teilstuecke (3 m, 3 m, 2 m ...).
public enum WalkDirections {
    /// Teilstuecke unter dieser Laenge ohne Richtungswechsel werden nie eine eigene Zeile.
    public static let miniStepMeters = 10
    /// Bis zu so vielen Schritten zeigt die Beschreibung alles, darueber nur die Kernschritte.
    public static let compactLimit = 3

    /// Fasst aufeinanderfolgende Schritte zusammen, ohne Gesamtdistanz zu veraendern (Fuehrung rechnet kumuliert):
    /// geradeaus auf derselben oder namenloser Strasse, leichte Biegung derselben Strasse und Mikroschritte
    /// ohne Richtungswechsel gehen im vorigen Schritt auf. Treppen, Aufzuege und Abbiegungen bleiben eigene Zeilen.
    public static func condensed(_ steps: [Step]) -> [Step] {
        var out: [Step] = []
        for step in steps {
            guard let last = out.last, absorbs(last, step) else {
                out.append(step)
                continue
            }
            let meters: Int? = (last.distanceMeters == nil && step.distanceMeters == nil)
                ? nil : (last.distanceMeters ?? 0) + (step.distanceMeters ?? 0)
            out[out.count - 1] = Step(direction: last.direction, distanceMeters: meters, fromLevel: last.fromLevel,
                                      toLevel: last.toLevel,
                                      // Nur ein gerades Stueck uebernimmt den Namen; "Links abbiegen" bleibt ohne fremden Namen.
                                      streetName: last.isStraight && !last.isVertical
                                          ? (last.streetName ?? step.streetName) : last.streetName)
        }
        return out
    }

    /// Standardansicht: bei wenigen Schritten alle, sonst nur Manoever (Abbiegen, Treppe, Aufzug).
    public static func keySteps(_ condensed: [Step]) -> [Step] {
        let maneuvers = condensed.filter(\.isManeuver)
        return condensed.count <= compactLimit || maneuvers.isEmpty ? condensed : maneuvers
    }

    static func absorbs(_ last: Step, _ step: Step) -> Bool {
        guard !step.isVertical else { return false }
        let mini = (step.distanceMeters ?? 0) < miniStepMeters
        // Nach Treppe/Aufzug nur Mikroschritte, damit "Aufzug runter" nicht 300 m Fussweg enthaelt.
        if last.isVertical { return step.isStraight && mini }
        if step.isStraight {
            if mini || step.streetName == nil || step.streetName == last.streetName { return true }
            // Unbekannte Richtung mit neuem Namen bleibt eine eigene Zeile (koennte eine Abbiegung sein).
            return step.direction != .unknown && last.streetName == nil
        }
        // Leichte Biegung derselben Strasse ist kein Abbiegen.
        let slight = step.direction == .slightlyLeft || step.direction == .slightlyRight
        return slight && step.streetName != nil && step.streetName == last.streetName
    }
}

/// Ebene Naeherung (equirektangulaer) fuer kurze Fusswege; genau genug fuer Meter-Angaben in Bahnhoefen.
enum PolylineMath {
    static func length(_ points: [GeoCoordinate]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    /// Strecke vom Anfang bis zum Lotfusspunkt der Position auf der naechstgelegenen Teilstrecke.
    static func distanceAlong(_ points: [GeoCoordinate], to position: GeoCoordinate) -> Double {
        var best = (distance: Double.greatestFiniteMagnitude, along: 0.0)
        var walked = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = a.distance(to: b)
            let t = projection(of: position, onto: a, b)
            let foot = GeoCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                     longitude: a.longitude + (b.longitude - a.longitude) * t)
            let d = position.distance(to: foot)
            if d < best.distance { best = (d, walked + segment * t) }
            walked += segment
        }
        return best.along
    }

    /// Anteil 0...1 entlang a->b, mit Laengengrad-Stauchung nach Breite.
    static func projection(of p: GeoCoordinate, onto a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let k = cos(a.latitude * .pi / 180)
        let (bx, by) = ((b.longitude - a.longitude) * k, b.latitude - a.latitude)
        let (px, py) = ((p.longitude - a.longitude) * k, p.latitude - a.latitude)
        let len2 = bx * bx + by * by
        guard len2 > 0 else { return 0 }
        return min(max((px * bx + py * by) / len2, 0), 1)
    }
}
