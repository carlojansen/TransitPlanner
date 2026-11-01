import Foundation

/// Was Widgets und Live Activity von den Erinnerungen sehen, im Klartext im App-Group-Container. Nur Fahrplandaten:
/// keine Favoriten-Labels, Adressen, Koordinaten, Tokens. Darum Abbildung aus dem Plan, nie aus dem Request.
/// Fussweg-Abschnitte fehlen, ihre Endpunkte koennen Adressen oder Labels tragen.
/// Neue Felder nur optional; inkompatible Aenderungen erhoehen `currentVersion`.
public struct TripSnapshot: Codable, Sendable, Hashable {
    public struct Ride: Codable, Sendable, Hashable {
        public let mode: TransitMode
        public let replacement: Bool
        public let line: String?
        public let lineColor: String?
        public let lineTextColor: String?
        public let direction: String?
        public let from: String?
        public let to: String?
        public let departure: Date?
        public let plannedDeparture: Date?
        public let arrival: Date?
        public let platform: String?
        public let plannedPlatform: String?
        public let cancelled: Bool

        init(_ leg: Leg) {
            mode = leg.mode
            replacement = leg.replacement
            line = leg.line?.name
            lineColor = leg.line?.color
            lineTextColor = leg.line?.textColor
            direction = leg.direction
            from = leg.origin.kind == .stop ? leg.origin.name : nil
            to = leg.destination.kind == .stop ? leg.destination.name : nil
            departure = leg.departure
            plannedDeparture = leg.plannedDeparture
            arrival = leg.arrival
            platform = leg.departurePlatform ?? leg.plannedDeparturePlatform
            plannedPlatform = leg.plannedDeparturePlatform
            cancelled = leg.cancelled
        }
    }

    public struct Trip: Codable, Sendable, Hashable {
        public let leaveAt: Date
        public let firstDeparture: Date
        /// Ende der Fahrt, wie `ReminderPlan.isOver`.
        public let arrival: Date
        public let walkSeconds: Int
        public let delayMinutes: Int?
        public let status: ReminderPlan.Status
        public let isEstimated: Bool
        public let rides: [Ride]

        init(_ plan: ReminderPlan) {
            leaveAt = plan.leaveAt
            firstDeparture = plan.scheduled.firstDeparture
            arrival = plan.journey.arrival ?? plan.scheduled.firstDeparture
            walkSeconds = plan.scheduled.walkSeconds
            delayMinutes = plan.delayMinutes
            status = plan.status
            isEstimated = plan.isEstimated
            rides = plan.journey.legs.filter { !$0.isWalk }.map(Ride.init)
        }
    }

    public static let currentVersion = 1
    public static let empty = TripSnapshot(trips: [])
    /// Ohne App hoechstens so lange alt: Lesen vor der ersten Entsperrung liefert leer, der Stand muss sich danach selbst holen.
    public static let rereadInterval: TimeInterval = 60 * 60

    public let version: Int
    public let trips: [Trip]

    private init(trips: [Trip]) {
        version = Self.currentVersion
        self.trips = trips
    }

    /// Haengt nicht von der Uhr ab: gleicher Stand, gleicher Inhalt.
    public init(plans: [ReminderPlan]) { self.init(trips: plans.map(Trip.init)) }

    /// Die App raeumt nur auf, wenn sie laeuft; Widgets filtern selbst.
    public func upcoming(now: Date) -> [Trip] { trips.filter { $0.arrival >= now } }

    /// Naechstes Lesen der Datei: wenn eine Fahrt endet, spaetestens nach `rereadInterval`.
    public func nextReload(now: Date) -> Date {
        min(now.addingTimeInterval(Self.rereadInterval), upcoming(now: now).map(\.arrival).min() ?? .distantFuture)
    }
}

/// JSON im App-Group-Container statt UserDefaults: nur Dateien tragen den Dateischutz aus AGENT.md 3.3.1.
public enum TripSnapshotFile {
    public static let appGroup = "group.de.carlojansen.transitplanner"

    /// nil, wenn der Container fehlt (App Group nicht signiert).
    public static var sharedURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: "trip-snapshot.json")
    }

    private static var options: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        .atomic
        #endif
    }

    /// Fehlt, kaputt, gesperrt oder aus einer neueren Version: leerer Stand, nie ein Fehler.
    public static func read(_ url: URL?) -> TripSnapshot {
        guard let url, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(TripSnapshot.self, from: data),
              snapshot.version <= TripSnapshot.currentVersion else { return .empty }
        return snapshot
    }

    /// Standard-Datumsformat statt ISO-8601: verlustfrei, `ReminderCenter` vergleicht mit dem gelesenen Stand.
    public static func write(_ snapshot: TripSnapshot, to url: URL?) throws(TransitError) {
        guard let url else { throw .storageUnavailable }
        do {
            try JSONEncoder().encode(snapshot).write(to: url, options: options)
        } catch {
            throw .storageUnavailable
        }
    }
}
