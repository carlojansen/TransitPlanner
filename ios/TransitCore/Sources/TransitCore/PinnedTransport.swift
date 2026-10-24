import CryptoKit
import Foundation
import Security

/// Austauschbarer HTTP-Zugang (Tests: Fake ohne Netz).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession mit den Vorgaben aus AGENT.md 3.2: ephemeral, TLS 1.3, waitsForConnectivity, kein Cache,
/// keine Cookies, SPKI-Pinning im Delegate, keine Weiterleitungen.
public final class PinnedSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(config: BackendConfig) {
        let delegate = PinningDelegate(host: config.host, pins: config.pinSet)
        session = URLSession(configuration: Self.makeConfiguration(), delegate: delegate, delegateQueue: nil)
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.tlsMinimumSupportedProtocolVersion = .TLSv13
        c.waitsForConnectivity = true
        // Ohne Obergrenze wartet waitsForConnectivity bis zu 7 Tage.
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 45
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        return c
    }

    /// Die Session haelt ihren Delegate stark; ohne Invalidierung bliebe beides bis Prozessende im Speicher.
    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

final class PinningDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let host: String
    let pins: Set<Data>

    init(host: String, pins: Set<Data>) {
        self.host = host
        self.pins = pins
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Andere Verfahren (z. B. Client-Zertifikat) bleiben beim System; das Backend nutzt keine.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return (.performDefaultHandling, nil)
        }
        guard challenge.protectionSpace.host == host,
              let trust = challenge.protectionSpace.serverTrust,
              PinValidator.evaluate(trust, host: host, pins: pins)
        else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// Keine Weiterleitungen: der Bearer-Token darf keinen anderen Host erreichen.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

enum PinValidator {
    /// Systemvertrauen (inkl. Hostname) UND Leaf-SPKI in der Pin-Menge. Fail closed.
    static func evaluate(_ trust: SecTrust, host: String, pins: Set<Data>) -> Bool {
        guard !pins.isEmpty,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let hash = spkiSHA256(of: leaf)
        else { return false }
        return pins.contains(hash)
    }

    /// SHA-256 ueber das DER-SubjectPublicKeyInfo, identisch zu `openssl pkey -pubin -outform der | sha256`.
    /// Unterstuetzt EC P-256/P-384 (Caddy-Standard und Backup-Schluessel); andere Schluessel scheitern bewusst.
    static func spkiSHA256(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate),
              let attrs = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attrs[kSecAttrKeyType] as? String,
              type == (kSecAttrKeyTypeECSECPrimeRandom as String),
              let bits = attrs[kSecAttrKeySizeInBits] as? Int,
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        let der: Data?
        switch bits {
        case 256: der = try? P256.Signing.PublicKey(x963Representation: raw).derRepresentation
        case 384: der = try? P384.Signing.PublicKey(x963Representation: raw).derRepresentation
        default: der = nil
        }
        return der.map { Data(SHA256.hash(data: $0)) }
    }
}
