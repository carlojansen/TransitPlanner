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
    /// Zuletzt gewaehltes "Frueher losgehen" fuer diesen Ort (D1), nur im Verlauf.
    var earlierMinutes: Int?
}

/// Favoriten und Verlauf der Planen-Ansicht. Lokal und verschluesselt. Der Verlauf ist Komfort: Fehler beim Speichern
/// bleiben still, die Suche wird nie blockiert. Favoriten setzt man bewusst: Scheitern meldet `false`.
protocol PlaceStoring: Sendable {
    @MainActor func favorites() -> [SavedPlace]
    @MainActor func recents() -> [SavedPlace]
    @MainActor func remember(_ endpoint: TripEndpoint)
    /// Merkt "Frueher losgehen" an einem Ort im Verlauf. Legt keine Zeile an: was nicht im Verlauf steht ("Mein Standort"), kommt auch so nicht hinein.
    // ponytail: lebt mit dem Verlauf (10 Orte, "Suchverlauf löschen"); eigenes Modell, falls Werte laenger halten sollen.
    @MainActor func setEarlierMinutes(_ minutes: Int, for endpoint: TripEndpoint)
    /// Je Rolle (ausser `.other`) ein Ort; derselbe Ort nie doppelt (eine neue Rolle ersetzt die alte).
    /// `replacing`: der Favorit, den der neue Ort ersetzt; er behaelt dessen Platz in der Reihenfolge, ersetzt wird in
    /// einem einzigen Speichern. Gleicher Ort heisst gleicher `routePoint` (das Label darf abweichen, z. B. umbenannt).
    /// `false`, wenn nichts gespeichert werden konnte (der Zustand bleibt dann wie vorher).
    @MainActor @discardableResult func addFavorite(_ endpoint: TripEndpoint, role: FavoritePlace.Role, replacing: UUID?) -> Bool
    /// Neuer Name fuer einen Favoriten (Ort, Rolle und Platz bleiben). Der Name ist schon geprueft (`TripEndpoint.normalizedLabel`).
    @MainActor @discardableResult func renameFavorite(_ id: UUID, to label: String) -> Bool
    @MainActor @discardableResult func removeFavorite(_ id: UUID) -> Bool
    @MainActor func removeRecent(_ id: UUID)
    @MainActor func clearRecents()
}

extension PlaceStoring {
    @MainActor @discardableResult func addFavorite(_ endpoint: TripEndpoint, role: FavoritePlace.Role) -> Bool {
        addFavorite(endpoint, role: role, replacing: nil)
    }
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
        recentRows().compactMap { row in open(row.sealedEndpoint).map { SavedPlace(id: row.id, endpoint: $0, isFavorite: false, earlierMinutes: row.earlierMinutes) } }
    }

    func remember(_ endpoint: TripEndpoint) {
        let rows = recentRows()
        let hit = rows.first { open($0.sealedEndpoint)?.routePoint == endpoint.routePoint }
        if let hit {
            hit.usedAt = .now
            if let sealed = try? sealer.seal(endpoint) { hit.sealedEndpoint = sealed } // Label der letzten Wahl
        } else {
            guard let sealed = try? sealer.seal(endpoint) else { return }
            context.insert(RecentSearch(sealedEndpoint: sealed))
        }
        // Der gewaehlte Ort steht vorn; von den uebrigen bleiben so viele, dass es insgesamt `recentPlacesLimit` sind.
        for old in rows.filter({ $0 !== hit }).dropFirst(recentPlacesLimit - 1) { context.delete(old) }
        try? context.save()
    }

    func setEarlierMinutes(_ minutes: Int, for endpoint: TripEndpoint) {
        recentRows().filter { open($0.sealedEndpoint)?.routePoint == endpoint.routePoint }.forEach { $0.earlierMinutes = minutes }
        try? context.save()
    }

    @discardableResult func addFavorite(_ endpoint: TripEndpoint, role: FavoritePlace.Role, replacing: UUID?) -> Bool {
        let rows = favoriteRows()
        let samePlace = rows.filter { open($0.sealedEndpoint)?.routePoint == endpoint.routePoint }
        let old = rows.first { $0.id == replacing }
        // Schon Favorit (ohne Rolle): nichts zu tun, nur der ersetzte faellt weg.
        if role == .other, samePlace.contains(where: { $0.id != replacing }) {
            guard let old else { return true }
            context.delete(old)
            return saveOrRollBack()
        }
        guard let sealed = try? sealer.seal(endpoint) else { return false }
        let replaced = rows.filter { row in samePlace.contains { $0 === row } || (role != .other && row.role == role) || row === old }
        let index = old?.sortIndex ?? (rows.map(\.sortIndex).max() ?? -1) + 1
        replaced.forEach(context.delete)
        context.insert(FavoritePlace(role: role, sealedEndpoint: sealed, sortIndex: index))
        return saveOrRollBack()
    }

    @discardableResult func renameFavorite(_ id: UUID, to label: String) -> Bool {
        guard let row = favoriteRows().first(where: { $0.id == id }), let endpoint = open(row.sealedEndpoint),
              let sealed = try? sealer.seal(endpoint.relabeled(label)) else { return false }
        row.sealedEndpoint = sealed
        return saveOrRollBack()
    }

    @discardableResult func removeFavorite(_ id: UUID) -> Bool {
        let rows = (try? context.fetch(FetchDescriptor<FavoritePlace>(predicate: #Predicate { $0.id == id }))) ?? []
        rows.forEach(context.delete)
        return saveOrRollBack()
    }

    /// Ein gescheiterter Schreibvorgang bleibt nicht halb im Kontext haengen (sonst taucht er beim naechsten Speichern auf).
    private func saveOrRollBack() -> Bool {
        do { try context.save(); return true } catch { context.rollback(); return false }
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
            let kept = $0.recents.first { $0.endpoint.routePoint == endpoint.routePoint }?.earlierMinutes
            $0.recents.removeAll { $0.endpoint.routePoint == endpoint.routePoint }
            $0.recents.insert(SavedPlace(id: UUID(), endpoint: endpoint, isFavorite: false, earlierMinutes: kept), at: 0)
            $0.recents = Array($0.recents.prefix(recentPlacesLimit))
        }
    }

    func setEarlierMinutes(_ minutes: Int, for endpoint: TripEndpoint) {
        state.withLock { s in
            for i in s.recents.indices where s.recents[i].endpoint.routePoint == endpoint.routePoint { s.recents[i].earlierMinutes = minutes }
        }
    }

    /// Nur Tests: Schreiben scheitert wie ein voller Speicher.
    let failure = Mutex(false)
    var failsWrites: Bool {
        get { failure.withLock { $0 } }
        set { failure.withLock { $0 = newValue } }
    }

    @discardableResult func addFavorite(_ endpoint: TripEndpoint, role: FavoritePlace.Role, replacing: UUID?) -> Bool {
        if failsWrites { return false }
        return state.withLock {
            let samePlace = { (p: SavedPlace) in p.endpoint.routePoint == endpoint.routePoint }
            let oldIndex = $0.favorites.firstIndex { $0.id == replacing }
            if role == .other, $0.favorites.contains(where: { samePlace($0) && $0.id != replacing }) {
                $0.favorites.removeAll { $0.id == replacing }
                return true
            }
            let place = SavedPlace(id: UUID(), endpoint: endpoint, isFavorite: true, role: role)
            $0.favorites.removeAll { samePlace($0) || (role != .other && $0.role == role) || $0.id == replacing }
            // Platz des ersetzten Favoriten behalten (wie `sortIndex` im SwiftData-Speicher).
            $0.favorites.insert(place, at: min(oldIndex ?? $0.favorites.count, $0.favorites.count))
            return true
        }
    }

    @discardableResult func renameFavorite(_ id: UUID, to label: String) -> Bool {
        if failsWrites { return false }
        return state.withLock { s in
            guard let i = s.favorites.firstIndex(where: { $0.id == id }) else { return false }
            s.favorites[i] = SavedPlace(id: id, endpoint: s.favorites[i].endpoint.relabeled(label), isFavorite: true, role: s.favorites[i].role)
            return true
        }
    }

    @discardableResult func removeFavorite(_ id: UUID) -> Bool {
        if failsWrites { return false }
        state.withLock { $0.favorites.removeAll { $0.id == id } }
        return true
    }
    func removeRecent(_ id: UUID) { state.withLock { $0.recents.removeAll { $0.id == id } } }
    func clearRecents() { state.withLock { $0.recents = [] } }
}
