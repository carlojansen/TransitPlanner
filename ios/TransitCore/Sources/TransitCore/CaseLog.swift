import Foundation

/// Art eines Auffaelligkeitsfalls fuer den Bericht "Bericht senden". Nur Zahlen und Ereignisse, keine Namen.
public enum CaseKind: String, Codable, Sendable, CaseIterable {
    /// Abfahrt nach Apple-Gehzeit nicht erreichbar, nach MOTIS-Gehzeit schon (Fall U5, Brandplatz).
    case departureNearMiss
    /// Vorschlag zur Umplanung kam erst spaet nach dem Anschlussbruch.
    case replanLate
    /// Fahrt nur per Zeit beendet, Position aber nicht am Ziel.
    case arrivalWithoutGPS
}

/// Ein Eintrag im lokalen Protokoll. Anonym by design: Zeit auf 5 Min., Ort auf 2 Stellen (~1 km), nur benannte Zahlen.
public struct CaseEvent: Codable, Sendable, Equatable {
    public let kind: CaseKind
    public let time: Date
    public let latitude: Double?
    public let longitude: Double?
    public let numbers: [String: Int]

    /// Rundet beim Anlegen; ein ungerundeter Wert kann gar nicht erst im Protokoll landen.
    public init(kind: CaseKind, time: Date, near: GeoCoordinate? = nil, numbers: [String: Int]) {
        self.kind = kind
        self.time = Date(timeIntervalSince1970: (time.timeIntervalSince1970 / 300).rounded(.down) * 300)
        let c = near?.rounded(decimals: 2)
        latitude = c?.latitude
        longitude = c?.longitude
        self.numbers = numbers
    }
}

/// Ringpuffer der letzten Faelle: aelteste fallen heraus, Groesse und Datenmenge bleiben begrenzt. Reine Logik, Speichern
/// (Datei) und Weitergabe (Teilen-Menue) liegen beim Aufrufer.
public struct CaseLog: Codable, Sendable, Equatable {
    public static let capacity = 200
    public private(set) var events: [CaseEvent] = []

    public init() {}

    /// Gleiche Art, Zeit (auf 5 Min. gerundet) und Ort nur einmal, die Zahlen des letzten Mals gelten: Neuplanen verdraengt
    /// keine seltenen Faelle.
    public mutating func record(_ event: CaseEvent?) {
        guard let event else { return }
        if let i = events.firstIndex(where: { $0.kind == event.kind && $0.time == event.time && $0.latitude == event.latitude && $0.longitude == event.longitude }) {
            events[i] = event
            return
        }
        events.append(event)
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
    }
}

/// Wann ein Fall ins Protokoll gehoert. Jede Regel liefert nil, wenn nichts auffaellig ist.
public enum CaseTrigger {
    /// Spaeter als so viele Sekunden nach dem Anschlussbruch gilt der Vorschlag als zu spaet.
    public static let lateProposalSeconds = 60

    /// Abfahrt abgelehnt (Reserve unter 0 mit Apple-Gehzeit), obwohl sie mit der MOTIS-Gehzeit erreichbar waere.
    /// `slackSeconds` = Abfahrt minus Ankunft/Jetzt minus kalibrierte Gehzeit.
    public static func departureNearMiss(slackSeconds: Int, walkSeconds: Int, motisWalkSeconds: Int,
                                         now: Date, near: GeoCoordinate?) -> CaseEvent? {
        guard slackSeconds < 0, slackSeconds + (walkSeconds - motisWalkSeconds) >= 0 else { return nil }
        return CaseEvent(kind: .departureNearMiss, time: now, near: near,
                         numbers: ["slack": slackSeconds, "walkApple": walkSeconds, "walkMotis": motisWalkSeconds])
    }

    public static func replanLate(bufferSeconds: Int, delaySeconds: Int, now: Date, near: GeoCoordinate?) -> CaseEvent? {
        guard delaySeconds > lateProposalSeconds else { return nil }
        return CaseEvent(kind: .replanLate, time: now, near: near, numbers: ["buffer": bufferSeconds, "delay": delaySeconds])
    }

    /// Fahrt endet per Zeit (Nachfrist), die Position liegt noch ausserhalb des Ziel-Umkreises.
    public static func arrivalWithoutGPS(endedByTime: Bool, distanceMeters: Double, now: Date, near: GeoCoordinate?) -> CaseEvent? {
        guard endedByTime, distanceMeters > NavigationEngine.arrivalRadius else { return nil }
        return CaseEvent(kind: .arrivalWithoutGPS, time: now, near: near, numbers: ["distance": Int(distanceMeters.rounded())])
    }
}

extension CaseTrigger {
    /// Fall U5: Verbindungen, deren Aufbruch mit der Apple-Gehzeit vor `now` liegt, mit der MOTIS-Gehzeit aber nicht.
    /// Ein Eintrag je Verbindung; nur Zugangswege (vor dem ersten Fahrzeug) zaehlen, und nur mit echter Apple-Gehzeit:
    /// Beim Fahrplan-Fallback waere der Unterschied nur das Gehtempo, nicht Apple. Ort ist der Einstiegshalt, nie der
    /// Start des Wegs (Standort oder Adresse des Nutzers).
    public static func departureNearMisses(in journeys: [CalibratedJourney], now: Date) -> [CaseEvent] {
        journeys.compactMap { item in
            guard let first = item.journey.legs.first(where: { !$0.isWalk }), let departure = first.departure else { return nil }
            let access = item.journey.legs.prefix(while: \.isWalk)
            guard !access.isEmpty, access.allSatisfy({ item.walks[$0.index]?.source == .appleMaps }) else { return nil }
            let motis = access.reduce(0) { $0 + ($1.durationSeconds ?? 0) }
            return departureNearMiss(slackSeconds: Int(departure.timeIntervalSince(now)) - item.accessWalkSeconds,
                                     walkSeconds: item.accessWalkSeconds, motisWalkSeconds: motis,
                                     now: now, near: first.origin.coordinate)
        }
    }
}

/// Berichtsdatei fuer "Bericht senden" (docs/API.md, Abschnitt Bericht). Nur das Protokoll und zwei Versionsangaben.
public struct CaseReport: Codable, Sendable, Equatable {
    public static let schema = 1
    public let schema: Int
    public let app: String
    public let os: String
    public let events: [CaseEvent]

    public init(log: CaseLog, app: String, os: String) {
        schema = Self.schema
        self.app = app
        self.os = os
        events = log.events
    }

    /// JSON, sortierte Schluessel (gleiche Eingabe, gleiche Datei), ISO-8601-Zeiten.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    /// Schreibt die Datei zum Teilen in `directory` (Dateiname nur mit Tag, Dateischutz bis zur ersten Entsperrung, vom Backup ausgenommen).
    public func write(to directory: URL, day: Date = Date()) throws -> URL {
        let name = "Bericht-\(day.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())).json"
        let url = directory.appendingPathComponent(name)
        try encoded().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        CaseLogStore.excludeFromBackup(url)
        return url
    }
}

/// Das Protokoll auf dem Geraet: eine JSON-Datei, vom Backup ausgenommen, nie ueber das Netz.
public struct CaseLogStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> CaseLog {
        (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(CaseLog.self, from: $0) } ?? CaseLog()
    }

    /// Eine vorhandene, aber gerade nicht lesbare Datei (Geraet noch nie entsperrt) wird nie ueberschrieben: sonst ginge die
    /// Historie verloren. Kaputter Inhalt dagegen wird ersetzt.
    public func save(_ log: CaseLog) {
        if FileManager.default.fileExists(atPath: url.path), (try? Data(contentsOf: url)) == nil { return }
        guard let data = try? Self.encoder.encode(log) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        Self.excludeFromBackup(url)
    }

    /// `.atomic` ersetzt die Datei und setzt das Attribut zurueck: nach jedem Schreiben neu setzen.
    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
