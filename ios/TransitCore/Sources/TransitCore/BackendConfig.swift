import Foundation

/// Einzige Stelle fuer Host und SPKI-Pins. Bei eigener Domain oder Schluesselwechsel nur hier aendern
/// (docs/DEPLOYMENT.md). Pins: Base64(SHA-256(DER SubjectPublicKeyInfo)), erzeugt mit `backend/deploy/spki-hash.sh`.
public struct BackendConfig: Sendable, Hashable {
    public let host: String
    public let primaryPin: String
    /// Offline-Backup-Schluessel. Ohne ihn fuehrt ein Schluesselverlust zum Totalausfall bis zum App-Update.
    public let backupPin: String?
    public let userAgent: String

    public init(host: String, primaryPin: String, backupPin: String?, userAgent: String = "TransitPlanner-iOS") {
        self.host = host
        self.primaryPin = primaryPin
        self.backupPin = backupPin
        self.userAgent = userAgent
    }

    public static let production = BackendConfig(
        host: "static.18.209.104.178.clients.your-server.de",
        primaryPin: "/G2ucqajVU17fdDE+oayjXlVEGDIEqe0/eo+4dK6i9Q=",
        // Offline-Backup-Schluessel (Carlo, 24.10.2026); der private Schluessel liegt nicht im Repo.
        backupPin: "0hkYwM2uh2/AMns6RP22FPaDZ2Zk/GjJVRHdz4hqvWI="
    )

    /// Basis-URL, immer https.
    public var baseURL: URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        return c.url
    }

    /// Dekodierte Pins (ungueltige Eintraege werden verworfen).
    public var pinSet: Set<Data> {
        Set([primaryPin, backupPin].compactMap { $0.flatMap { Data(base64Encoded: $0) } }.filter { $0.count == 32 })
    }

    /// Erst mit zwei gueltigen, verschiedenen Pins releasefaehig.
    public var isPinningReleaseReady: Bool { pinSet.count == 2 }
}
