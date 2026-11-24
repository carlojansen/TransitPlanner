import Foundation
import Synchronization
import TransitCore

/// Ticket-Ablage hinter einem Protokoll (wie `PlaceStoring`): live `TicketStore` (verschluesselte Dateien), in Tests und
/// Vorschauen `MemoryTickets`. Die Dateiarbeit laeuft nie auf dem Main Actor (siehe `AppFlow.addTicket`).
protocol TicketStoring: Sendable {
    func entries() -> [TicketStore.Entry]
    func save(_ ticket: StoredTicket) throws(TransitError)
    func delete(_ id: UUID)
}

extension TicketStore: TicketStoring {}

/// Nur im Arbeitsspeicher: Rueckfall ohne Application Support, Fake fuer Tests und Vorschauen.
final class MemoryTickets: TicketStoring {
    private let state = Mutex<[TicketStore.Entry]>([])
    /// Nur Tests: Speichern scheitert wie ein voller Speicher.
    let failsWrites = Mutex(false)

    init(tickets: [StoredTicket] = []) { state.withLock { $0 = tickets.map(TicketStore.Entry.ticket) } }

    /// Nur Tests: ein Ticket, das sich nicht oeffnen laesst (z. B. neuer Schluessel).
    func addUnreadable(id: UUID = UUID()) { state.withLock { $0.append(.unreadable(id: id)) } }

    func entries() -> [TicketStore.Entry] { state.withLock { $0 } }

    func save(_ ticket: StoredTicket) throws(TransitError) {
        if failsWrites.withLock({ $0 }) { throw .storageUnavailable }
        state.withLock { entries in
            entries.removeAll { $0.id == ticket.id }
            entries.append(.ticket(ticket))
        }
    }

    func delete(_ id: UUID) { state.withLock { $0.removeAll { $0.id == id } } }
}
