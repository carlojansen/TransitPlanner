import Foundation
import SwiftData
import Synchronization
import TransitCore

/// Gemerkter Ort: Favorit oder Verlaufseintrag. "Mein Standort" und GPS-Koordinaten landen hier nie (AGENT.md 3.1.2).
struct SavedPlace: Identifiable, Hashable, Sendable {
    let id: UUID
    let endpoint: TripEndpoint
    let isFavorite: Bool
    /// Zuhause, Uni, Arbeit oder weiterer Favorit; im Verlauf immer `.other`.
    var role: FavoritePlace.Role = .other
}

/// Favoriten und Verlauf der Planen-Ansicht. Lokal und verschluesselt; Fehler beim Speichern bleiben still,
/// weil beides nur Komfort ist und die Suche nie blockieren darf.
protocol PlaceStoring: Sendable {
    @MainActor func favorites() -> [SavedPlace]
    @MainActor func recents() -> [SavedPlace]
    @MainActor func remember(_ endpoint: TripEndpoint)
    /// Je Rolle (ausser `.other`) ein Ort; derselbe Ort nie doppelt (eine neue Rolle ersetzt die alte).
    @MainActor func addFavorite(_ endpoint: TripEndpoint, role: FavoritePlace.Role)
    @MainActor func removeFavorite(_ id: UUID)
    @MainActor func removeRecent(_ id: UUID)
    @MainActor func clearRecents()
}

/// Gleiche Wahl nur einmal im Verlauf, aeltere Eintraege fallen heraus.
let recentPlacesLimit = 10

/// SwiftData-Speicher; Orte liegen AES-GCM-verschluesselt in `FavoritePlace` und `RecentSearch`.
@MainActor
final class SwiftDataPlaces: PlaceStoring {
    /// Der Kontext haelt den Container nicht: ohne diese Referenz stuerzt der erste Fetch ab.
    private let container: ModelContainer
    private let context: ModelContext
    private let sealer: LocalSealer

    init(container: ModelContainer, sealer: LocalSealer) {
        self.container = container
        context = container.mainContext
        self.sealer = sealer
    }

    func favorites() -> [SavedPlace] {
        return favoriteRows().compactMap { row in
            open(row.sealedEndpoint).map { SavedPlace(id: row.id, endpoint: $0, isFavorite: true, role: row.role) }
        }
    }

    private func favoriteRows() -> [FavoritePlace] {
        let sort = [SortDescriptor(\FavoritePlace.sortIndex), SortDescriptor(\FavoritePlace.createdAt)]
        return (try? context.fetch(FetchDescriptor<FavoritePlace>(sortBy: sort))) ?? []
    }

    func recents() -> [SavedPlace] {
        recentRows().compactMap { row in open(row.sealedEndpoint).map { SavedPlace(id: row.id, endpoint: $0, isFavorite: false) } }
    }

    func remember(_ endpoint: TripEndpoint) {
        let rows = recentRows()
        let hit = rows.first { open($0.sealedEndpoint) == endpoint }
        if let hit {
            hit.usedAt = .now
        } else {
            guard let sealed = try? sealer.seal(endpoint) else { return }
            context.insert(RecentSearch(sealedEndpoint: sealed))
        }
        // Der gewaehlte Ort steht vorn; von den uebrigen bleiben so viele, dass es insgesamt `recentPlacesLimit` sind.
        for old in rows.filter({ $0 !== hit }).dropFirst(recentPlacesLimit - 1) { context.delete(old) }
        try? context.save()
    }

    func addFavorite(_ endpoint: TripEndpoint, role: FavoritePlace.Role) {
        let rows = favoriteRows()
        let replaced = rows.filter { open($0.sealedEndpoint) == endpoint || (role != .other && $0.role == role) }
        if role == .other, !replaced.isEmpty { return }
        guard let sealed = try? sealer.seal(endpoint) else { return }
        replaced.forEach(context.delete)
        context.insert(FavoritePlace(role: role, sealedEndpoint: sealed, sortIndex: (rows.map(\.sortIndex).max() ?? -1) + 1))
        try? context.save()
    }

    func removeFavorite(_ id: UUID) {
        let rows = (try? context.fetch(FetchDescriptor<FavoritePlace>(predicate: #Predicate { $0.id == id }))) ?? []
        rows.forEach(context.delete)
        try? context.save()
    }

    func removeRecent(_ id: UUID) {
        recentRows().filter { $0.id == id }.forEach(context.delete)
        try? context.save()
    }

    func clearRecents() {
        recentRows().forEach(context.delete)
        try? context.save()
    }

    private func recentRows() -> [RecentSearch] {
        (try? context.fetch(FetchDescriptor<RecentSearch>(sortBy: [SortDescriptor(\.usedAt, order: .reverse)]))) ?? []
    }

    private func open(_ data: Data) -> TripEndpoint? {
        try? sealer.open(TripEndpoint.self, from: data)
    }
}

/// Speicher nur im Arbeitsspeicher: Rueckfall ohne Store, Fake fuer Tests und Vorschauen.
final class MemoryPlaces: PlaceStoring {
    private struct State {
        var favorites: [SavedPlace] = []
        var recents: [SavedPlace] = []
    }

    private let state = Mutex(State())

    init(favorites: [TripEndpoint] = [], recents: [TripEndpoint] = []) {
        state.withLock {
            $0.favorites = favorites.map { SavedPlace(id: UUID(), endpoint: $0, isFavorite: true) }
            $0.recents = recents.map { SavedPlace(id: UUID(), endpoint: $0, isFavorite: false) }
        }
    }

    func favorites() -> [SavedPlace] { state.withLock { $0.favorites } }
    func recents() -> [SavedPlace] { state.withLock { $0.recents } }

    func remember(_ endpoint: TripEndpoint) {
        state.withLock {
            $0.recents.removeAll { $0.endpoint == endpoint }
            $0.recents.insert(SavedPlace(id: UUID(), endpoint: endpoint, isFavorite: false), at: 0)
            $0.recents = Array($0.recents.prefix(recentPlacesLimit))
        }
    }

    func addFavorite(_ endpoint: TripEndpoint, role: FavoritePlace.Role) {
        state.withLock {
            let replaced = { (p: SavedPlace) in p.endpoint == endpoint || (role != .other && p.role == role) }
            if role == .other, $0.favorites.contains(where: replaced) { return }
            $0.favorites.removeAll(where: replaced)
            $0.favorites.append(SavedPlace(id: UUID(), endpoint: endpoint, isFavorite: true, role: role))
        }
    }

    func removeFavorite(_ id: UUID) { state.withLock { $0.favorites.removeAll { $0.id == id } } }
    func removeRecent(_ id: UUID) { state.withLock { $0.recents.removeAll { $0.id == id } } }
    func clearRecents() { state.withLock { $0.recents = [] } }
}
