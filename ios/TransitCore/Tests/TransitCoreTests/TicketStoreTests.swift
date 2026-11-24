import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TransitCore

/// Ticket-Datei: verschluesselt, nicht im Backup, Grenzen beim Import, EXIF/GPS faellt heraus.
@Suite struct TicketStoreTests {
    static func makeStore(secrets: InMemorySecretStore = InMemorySecretStore()) throws -> (TicketStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tickets-\(UUID().uuidString)")
        return (TicketStore(directory: dir, sealer: LocalSealer(secrets: secrets)), dir)
    }

    /// Testbild mit GPS im EXIF, in der gewuenschten Groesse.
    static func jpeg(width: Int, height: Int, withGPS: Bool = false) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if withGPS { properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 51.2, kCGImagePropertyGPSLongitude: 6.8] }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    static func pdf() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @Test func roundTripOrderAndRawBytesAreSealed() throws {
        let (store, dir) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = Data("GEHEIMES-TICKET-4711".utf8)
        let first = StoredTicket(kind: .image, createdAt: Date(timeIntervalSince1970: 100), data: marker)
        let second = StoredTicket(kind: .pdf, createdAt: Date(timeIntervalSince1970: 200), data: Data("zweites".utf8))
        try store.save(second)
        try store.save(first)
        #expect(store.entries() == [.ticket(first), .ticket(second)]) // aelteste zuerst
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            #expect(try Data(contentsOf: file).range(of: marker) == nil, "Klartext in der Datei")
        }
        store.delete(first.id)
        #expect(store.entries() == [.ticket(second)])
    }

    @Test func filesAreExcludedFromBackupAlsoAfterReplacing() throws {
        let (store, dir) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ticket = StoredTicket(kind: .image, data: Data("a".utf8))
        try store.save(ticket)
        try store.save(StoredTicket(id: ticket.id, kind: .image, data: Data("b".utf8))) // ersetzt die Datei atomar
        let file = try #require(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // Die Datei muss das Attribut selbst tragen (sonst erbt sie es nur vom Ordner und verliert es beim Verschieben).
        var folder = dir
        var off = URLResourceValues()
        off.isExcludedFromBackup = false
        try folder.setResourceValues(off)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    /// Neuer Schluessel (Neuinstallation): das Ticket wird als unlesbar gemeldet, nicht verschluckt, und laesst sich loeschen.
    @Test func wrongKeyIsReportedAsUnreadable() throws {
        let (store, dir) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ticket = StoredTicket(kind: .image, data: Data("x".utf8))
        try store.save(ticket)
        let other = TicketStore(directory: dir, sealer: LocalSealer(secrets: InMemorySecretStore()))
        #expect(other.entries() == [.unreadable(id: ticket.id)])
        other.delete(ticket.id)
        #expect(other.entries().isEmpty)
    }

    @Test func failedSaveKeepsTheOldTicket() throws {
        let (store, dir) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ticket = StoredTicket(kind: .image, data: Data("alt".utf8))
        try store.save(ticket)
        // Der Zielpfad der neuen Datei ist ein nicht leerer Ordner: Schreiben scheitert, die alte Datei bleibt.
        let blocked = StoredTicket(kind: .image, data: Data("neu".utf8))
        let blockedFile = dir.appendingPathComponent("\(blocked.id.uuidString).ticket")
        try FileManager.default.createDirectory(at: blockedFile.appendingPathComponent("x"), withIntermediateDirectories: true)
        #expect(throws: TransitError.storageUnavailable) { try store.save(blocked) }
        #expect(store.entries().contains(.ticket(ticket)))
    }

    @Test func importAcceptsImageAndPDFAndRejectsTheRest() throws {
        let image = try TicketImport.prepare(Self.jpeg(width: 200, height: 100))
        #expect(image.kind == .image)
        let pdf = Self.pdf()
        let prepared = try TicketImport.prepare(pdf)
        #expect(prepared.kind == .pdf && prepared.data == pdf) // PDF unveraendert
        for bad in [Data(), Data("kein Bild".utf8), Data("%PDF-kaputt".utf8), Data(count: TicketImport.maxRawBytes + 1)] {
            #expect(throws: TransitError.ticketUnreadable) { try TicketImport.prepare(bad) }
        }
    }

    @Test func importShrinksBigImagesAndDropsGPS() throws {
        let big = Self.jpeg(width: 4000, height: 100, withGPS: true)
        let source = try #require(CGImageSourceCreateWithData(big as CFData, nil))
        let before = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(before?[kCGImagePropertyGPSDictionary] != nil, "Testbild muss GPS tragen")

        let prepared = try TicketImport.prepare(big)
        let result = try #require(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyGPSDictionary] == nil)
        #expect((props?[kCGImagePropertyPixelWidth] as? Int) == TicketImport.maxImagePixels)
    }
}
