import Foundation
import Security
import Testing
@testable import TransitCore

/// Pinning gegen eine eigene Test-CA (Fixtures test-ca.der / test-leaf.der, EC P-256, Leaf fuer
/// `backend.transitplanner.test`, gueltig 24.10.2026 bis 24.10.2027). Pruefdatum fest, damit die Tests nicht altern.
@Suite struct PinningTests {
    static let host = "backend.transitplanner.test"
    static let leafPin = "+Nct2qu4XfqCn7vV3IT38GiaU1EhOgmonkySxAdpaNc="
    static let otherPin = Data(repeating: 1, count: 32)

    static func certificate(_ name: String) throws -> SecCertificate {
        try #require(SecCertificateCreateWithData(nil, try Fixture.data(name, "der") as CFData))
    }

    /// Trust fuer das Test-Leaf, verankert ausschliesslich in der Test-CA.
    static func trust() throws -> SecTrust {
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(try certificate("test-leaf"), SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let t = try #require(trust)
        #expect(SecTrustSetAnchorCertificates(t, [try certificate("test-ca")] as CFArray) == errSecSuccess)
        #expect(SecTrustSetAnchorCertificatesOnly(t, true) == errSecSuccess)
        #expect(SecTrustSetVerifyDate(t, Date.iso("2026-12-01T00:00:00Z") as CFDate) == errSecSuccess)
        return t
    }

    static var pins: Set<Data> { [Data(base64Encoded: leafPin) ?? Data()] }

    @Test func leafSPKIMatchesOpenSSL() throws {
        #expect(PinValidator.spkiSHA256(of: try Self.certificate("test-leaf"))?.base64EncodedString() == Self.leafPin)
    }

    @Test func validChainWithMatchingPinPasses() throws {
        #expect(PinValidator.evaluate(try Self.trust(), host: Self.host, pins: Self.pins))
    }

    @Test func validChainWithWrongPinFails() throws {
        #expect(!PinValidator.evaluate(try Self.trust(), host: Self.host, pins: [Self.otherPin]))
    }

    @Test func pinOnlyMatchingCAKeyFails() throws {
        // Leaf-Pinning: ein Pin auf den CA-Schluessel reicht nicht.
        let caPin = try #require(PinValidator.spkiSHA256(of: try Self.certificate("test-ca")))
        #expect(!PinValidator.evaluate(try Self.trust(), host: Self.host, pins: [caPin]))
    }

    @Test func wrongHostnameFailsEvenWithMatchingPin() throws {
        #expect(!PinValidator.evaluate(try Self.trust(), host: "evil.transitplanner.test", pins: Self.pins))
    }

    @Test func untrustedChainFailsEvenWithMatchingPin() throws {
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(try Self.certificate("test-leaf"), SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let t = try #require(trust) // ohne Test-CA als Anker
        #expect(!PinValidator.evaluate(t, host: Self.host, pins: Self.pins))
    }

    // MARK: Delegate

    static func challenge(host: String = PinningTests.host, method: String = NSURLAuthenticationMethodServerTrust,
                          trust: SecTrust?) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(protectionSpace: StubProtectionSpace(host: host, method: method, trust: trust),
                                   proposedCredential: nil, previousFailureCount: 0, failureResponse: nil,
                                   error: nil, sender: NoopChallengeSender())
    }

    @Test func delegateAcceptsPinnedServer() async throws {
        let delegate = PinningDelegate(host: Self.host, pins: Self.pins)
        let (disposition, credential) = await delegate.urlSession(.shared, didReceive: Self.challenge(trust: try Self.trust()))
        #expect(disposition == .useCredential)
        #expect(credential != nil)
    }

    @Test func delegateRejectsWrongPinAndHostMismatch() async throws {
        let wrongPin = PinningDelegate(host: Self.host, pins: [Self.otherPin])
        #expect(await wrongPin.urlSession(.shared, didReceive: Self.challenge(trust: try Self.trust())).0 == .cancelAuthenticationChallenge)

        let delegate = PinningDelegate(host: Self.host, pins: Self.pins)
        let foreignHost = Self.challenge(host: "other.transitplanner.test", trust: try Self.trust())
        #expect(await delegate.urlSession(.shared, didReceive: foreignHost).0 == .cancelAuthenticationChallenge)
        #expect(await delegate.urlSession(.shared, didReceive: Self.challenge(trust: nil)).0 == .cancelAuthenticationChallenge)
    }

    @Test func delegateLeavesOtherAuthMethodsToSystem() async throws {
        let delegate = PinningDelegate(host: Self.host, pins: Self.pins)
        let basic = Self.challenge(method: NSURLAuthenticationMethodHTTPBasic, trust: nil)
        let (disposition, credential) = await delegate.urlSession(.shared, didReceive: basic)
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test func delegateBlocksRedirects() async throws {
        let delegate = PinningDelegate(host: Self.host, pins: Self.pins)
        let url = try #require(URL(string: "https://\(Self.host)/api/routes"))
        let target = try #require(URL(string: "https://evil.example.org/"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                                    headerFields: ["Location": target.absoluteString]))
        let task = URLSession.shared.dataTask(with: url)
        #expect(await delegate.urlSession(.shared, task: task, willPerformHTTPRedirection: response,
                                          newRequest: URLRequest(url: target)) == nil)
    }
}

final class StubProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust?

    init(host: String, method: String, trust: SecTrust?) {
        self.trust = trust
        super.init(host: host, port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil, authenticationMethod: method)
    }

    required init?(coder: NSCoder) { nil }

    override var serverTrust: SecTrust? { trust }
}

final class NoopChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
