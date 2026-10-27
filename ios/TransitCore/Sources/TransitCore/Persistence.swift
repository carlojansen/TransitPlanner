import CryptoKit
import Foundation
import SwiftData
import Synchronization

/// AES-GCM fuer lokal gespeicherte Orte (AGENT.md 3.1.2). Schluessel in der Keychain, im Speicher gecacht.
public final class LocalSealer: Sendable {
    private let secrets: any SecretStore
    private let cachedKey = Mutex<SymmetricKey?>(nil)

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    private func key() throws(TransitError) -> SymmetricKey {
        try cachedKey.withLock { (cached: inout SymmetricKey?) throws(TransitError) -> SymmetricKey in
            if let cached { return cached }
            let key: SymmetricKey
            if let data = try secrets.read(.coordinateKey) {
                // Falsche Laenge = beschaedigter Eintrag. Nicht ueberschreiben, sonst waeren alle Daten verloren.
                guard data.count == 32 else { throw TransitError.keychainFailure }
                key = SymmetricKey(data: data)
            } else {
                key = SymmetricKey(size: .bits256)
                try secrets.write(key.withUnsafeBytes { Data($0) }, for: .coordinateKey)
            }
            cached = key
            return key
        }
    }

    public func seal(_ value: some Encodable) throws(TransitError) -> Data {
        let k = try key()
        do {
            let plain = try JSONEncoder().encode(value)
            guard let combined = try AES.GCM.seal(plain, using: k).combined else { throw TransitError.internal }
            return combined
        } catch {
            throw .internal
        }
    }

    public func open<T: Decodable>(_ type: T.Type, from data: Data) throws(TransitError) -> T {
        let k = try key()
        do {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: k)
            return try JSONDecoder().decode(T.self, from: plain)
        } catch {
            throw .decodingFailed
        }
    }
}

// MARK: - SwiftData-Modelle

/// Favorit (Zuhause, Uni, Arbeit, ...). Name und Ort liegen nur verschluesselt vor.
@Model
public final class FavoritePlace {
    /// Feste Kacheln im Start (DESIGN.md B1) plus beliebig viele weitere (`other`). Rohwert als String: neue Faelle
    /// brauchen keine Migration.
    public enum Role: String, Codable, Sendable, CaseIterable { case home, uni, work, other }

    @Attribute(.unique) public var id: UUID
    public var roleRaw: String
    /// AES-GCM(TripEndpoint)
    public var sealedEndpoint: Data
    public var sortIndex: Int
    public var createdAt: Date

    public init(id: UUID = UUID(), role: Role, sealedEndpoint: Data, sortIndex: Int = 0, createdAt: Date = .now) {
        self.id = id
        roleRaw = role.rawValue
        self.sealedEndpoint = sealedEndpoint
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }

    public var role: Role { Role(rawValue: roleRaw) ?? .other }
}

/// Letzte Suchen (verschluesselt, Reihenfolge ueber `usedAt`).
@Model
public final class RecentSearch {
    @Attribute(.unique) public var id: UUID
    public var sealedEndpoint: Data
    public var usedAt: Date

    public init(id: UUID = UUID(), sealedEndpoint: Data, usedAt: Date = .now) {
        self.id = id
        self.sealedEndpoint = sealedEndpoint
        self.usedAt = usedAt
    }
}

/// Oeffentliche Haltestellendaten fuer Sofort-Vorschlaege (unverschluesselt, kein Personenbezug).
@Model
public final class CachedStop {
    @Attribute(.unique) public var stopID: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var modesRaw: [String]
    public var area: String?
    public var updatedAt: Date

    public init(place: Place, updatedAt: Date = .now) {
        stopID = place.id ?? ""
        name = place.name ?? ""
        latitude = place.latitude ?? 0
        longitude = place.longitude ?? 0
        modesRaw = (place.modes ?? []).map(\.rawValue)
        area = place.area
        self.updatedAt = updatedAt
    }

    /// Nur echte Haltestellen mit ID und Koordinate werden gecacht.
    public static func make(from place: Place, now: Date = .now) -> CachedStop? {
        guard place.kind == .stop, place.id?.isEmpty == false, place.coordinate != nil else { return nil }
        return CachedStop(place: place, updatedAt: now)
    }
}

/// Geplante Fahrt. Der refreshToken liegt in der Keychain (`SecretKey.refreshToken(tripID:)`), nicht hier.
@Model
public final class PlannedTrip {
    @Attribute(.unique) public var id: UUID
    /// AES-GCM(ManualTripRequest), enthaelt Orte, Labels und Kalender-Kennung
    public var sealedRequest: Data
    /// Unverschluesselt nur fuer Sortierung und Hintergrund-Planung
    public var targetTime: Date
    public var reminderEnabled: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), sealedRequest: Data, targetTime: Date, reminderEnabled: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.sealedRequest = sealedRequest
        self.targetTime = targetTime
        self.reminderEnabled = reminderEnabled
        self.createdAt = createdAt
    }

    public convenience init(request: ManualTripRequest, sealer: LocalSealer, reminderEnabled: Bool = false) throws(TransitError) {
        self.init(sealedRequest: try sealer.seal(request), targetTime: request.targetTime, reminderEnabled: reminderEnabled)
    }

    public func request(using sealer: LocalSealer) throws(TransitError) -> ManualTripRequest {
        try sealer.open(ManualTripRequest.self, from: sealedRequest)
    }
}

/// Gelernter Gehzeit-Faktor (eine Zeile).
@Model
public final class PaceProfile {
    public var learned: Double
    public var sampleCount: Int
    public var manualOverride: Double?
    public var updatedAt: Date

    public init(_ pace: WalkingPaceFactor = WalkingPaceFactor(), updatedAt: Date = .now) {
        learned = pace.learned
        sampleCount = pace.sampleCount
        manualOverride = pace.manualOverride
        self.updatedAt = updatedAt
    }

    public var pace: WalkingPaceFactor {
        get { WalkingPaceFactor(learned: learned, sampleCount: sampleCount, manualOverride: manualOverride) }
        set {
            learned = newValue.learned
            sampleCount = newValue.sampleCount
            manualOverride = newValue.manualOverride
            updatedAt = .now
        }
    }
}

// MARK: - Container

public enum TransitStore {
    public static let models: [any PersistentModel.Type] = [
        FavoritePlace.self, RecentSearch.self, CachedStop.self, PlannedTrip.self, PaceProfile.self,
    ]

    /// Lokaler Store, kein iCloud-Sync. Dateischutz `completeUntilFirstUserAuthentication` (AGENT.md 3.3.1).
    public static func makeContainer(inMemory: Bool = false) throws(TransitError) -> ModelContainer {
        let schema = Schema(models)
        do {
            if inMemory {
                return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            }
            let fm = FileManager.default
            let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "TransitStore", directoryHint: .isDirectory)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: protection)
            let config = ModelConfiguration(schema: schema, url: dir.appending(path: "Transit.store"),
                                            cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: config)
            try protectContents(of: dir)
            return container
        } catch {
            throw .internal
        }
    }

    private static var protection: [FileAttributeKey: Any] {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        [:]
        #endif
    }

    /// Store, -wal und -shm explizit schuetzen (neue Dateien erben den Schutz des Ordners).
    private static func protectContents(of dir: URL) throws {
        #if os(iOS)
        let fm = FileManager.default
        try fm.setAttributes(protection, ofItemAtPath: dir.path)
        for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            try fm.setAttributes(protection, ofItemAtPath: file.path)
        }
        #endif
    }
}
