import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Ein Ticket, das die Person selbst hinzugefuegt hat (Foto, Bild oder PDF). Die App zeigt es nur an: sie verkauft nichts
/// und prueft nichts. Inhalt und Zeitpunkt liegen nur im verschluesselten Chiffrat (kein Datei-Zeitstempel).
public struct StoredTicket: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case image, pdf }

    public var id: UUID
    public var kind: Kind
    public var createdAt: Date
    public var data: Data

    public init(id: UUID = UUID(), kind: Kind, createdAt: Date = .now, data: Data) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.data = data
    }
}

/// Aufbereitung beim Hinzufuegen: nur Bilder und PDF, mit Groessengrenzen. Bilder werden verkleinert und neu kodiert,
/// dabei fallen EXIF und GPS heraus (sonst laege der Aufnahmeort im Ticket). Nichts davon laeuft ueber eine Datei.
public enum TicketImport {
    /// Rohdaten, die vor jeder Verarbeitung abgelehnt werden (Speicherdruck beim Dekodieren).
    public static let maxRawBytes = 20_000_000
    public static let maxPDFBytes = 10_000_000
    /// Laengste Seite eines gespeicherten Bildes: Screenshots bleiben voll, 48-MP-Fotos werden kleiner.
    public static let maxImagePixels = 3000

    public static func prepare(_ raw: Data) throws(TransitError) -> (kind: StoredTicket.Kind, data: Data) {
        guard !raw.isEmpty, raw.count <= maxRawBytes else { throw .ticketUnreadable }
        if raw.starts(with: Data("%PDF".utf8)) {
            guard raw.count <= maxPDFBytes, isUsablePDF(raw) else { throw .ticketUnreadable }
            return (.pdf, raw)
        }
        guard let jpeg = reencodedImage(raw) else { throw .ticketUnreadable }
        return (.image, jpeg)
    }

    private static func isUsablePDF(_ data: Data) -> Bool {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return false }
        return document.numberOfPages >= 1 && !document.isEncrypted
    }

    private static func reencodedImage(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // Ausrichtung uebernehmen, sie faellt mit EXIF weg
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

/// Verschluesselte Dateien in einem Ordner (`<uuid>.ticket`), nie im Backup, nie im geteilten App-Group-Ordner.
/// Vorbild: `CaseLogStore`. Ein unlesbares Chiffrat (z. B. neuer Schluessel nach Neuinstallation) wird gemeldet statt verschluckt.
public struct TicketStore: Sendable {
    public enum Entry: Sendable, Equatable {
        case ticket(StoredTicket)
        /// Datei vorhanden, aber nicht zu oeffnen: sichtbar machen, loeschbar.
        case unreadable(id: UUID)

        public var id: UUID {
            switch self {
            case .ticket(let ticket): ticket.id
            case .unreadable(let id): id
            }
        }
    }

    public let directory: URL
    private let sealer: LocalSealer

    public init(directory: URL, sealer: LocalSealer) {
        self.directory = directory
        self.sealer = sealer
    }

    /// Aelteste zuerst, nicht lesbare am Ende.
    public func entries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let entries: [Entry] = files.compactMap { url in
            guard url.pathExtension == Self.fileExtension, let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            guard let data = try? Data(contentsOf: url), let ticket = try? sealer.open(StoredTicket.self, from: data) else { return .unreadable(id: id) }
            return .ticket(ticket)
        }
        let tickets = entries.compactMap { entry -> StoredTicket? in if case .ticket(let t) = entry { t } else { nil } }
        let broken = entries.filter { if case .unreadable = $0 { true } else { false } }
        return tickets.sorted { $0.createdAt < $1.createdAt }.map(Entry.ticket) + broken
    }

    /// Schreibt atomar (ein Fehler laesst eine vorhandene Datei stehen). Zum Ersetzen: erst `save`, dann `delete` des alten.
    public func save(_ ticket: StoredTicket) throws(TransitError) {
        let sealed = try sealer.seal(ticket)
        let url = fileURL(ticket.id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw .storageUnavailable
        }
        // `.atomic` setzt das Attribut zurueck: nach jedem Schreiben neu setzen (Ordner und Datei).
        Self.excludeFromBackup(url)
        Self.excludeFromBackup(directory)
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    static let fileExtension = "ticket"

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(Self.fileExtension)
    }

    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }
}
