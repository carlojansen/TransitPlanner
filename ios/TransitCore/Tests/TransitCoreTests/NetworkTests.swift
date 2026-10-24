import Foundation
import Security
import Synchronization
import Testing
@testable import TransitCore

@Suite struct NetworkTests {
    // MARK: Request-Aufbau

    @Test func sendsBearerFixedUserAgentAndHTTPS() async throws {
        let transport = FakeTransport(json: Fixture.emptyLocations)
        _ = try await client(transport).searchStops("  Hbf  ")
        let req = try #require(transport.requests.first)
        #expect(req.url?.scheme == "https")
        #expect(req.url?.host() == BackendConfig.production.host)
        #expect(req.url?.path() == "/api/locations")
        #expect(req.url?.query() == "query=Hbf")
        #expect(req.httpMethod == "GET")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "TransitPlanner-iOS")
        #expect(req.value(forHTTPHeaderField: "Accept-Language") == "de")
    }

    @Test func plusAndAmpersandInQueryArePercentEncoded() async throws {
        let transport = FakeTransport(json: Fixture.emptyLocations)
        _ = try await client(transport).searchStops("C+A & Co")
        #expect(transport.requests.first?.url?.query(percentEncoded: true) == "query=C%2BA%20%26%20Co")
    }

    @Test func retryAfterOnlyHonouredForThrottlingStatuses() async throws {
        let unauthorized = FakeTransport.Reply(status: 401, body: Data(#"{"error":{"code":"UNAUTHORIZED","message":"x"}}"#.utf8),
                                               headers: ["Retry-After": "120"])
        let transport = FakeTransport([unauthorized, .init(status: 200, body: Fixture.emptyLocations)])
        let api = client(transport)
        await #expect(throws: TransitError.unauthorized) { try await api.searchStops("Hbf") }
        _ = try await api.searchStops("Hbf") // nicht gesperrt
        #expect(transport.requests.count == 2)

        let unavailable = FakeTransport([.init(status: 503, body: Data(), headers: ["Retry-After": "120"])])
        let api2 = client(unavailable)
        await #expect(throws: TransitError.upstreamUnavailable) { try await api2.searchStops("Hbf") }
        await #expect(throws: TransitError.upstreamUnavailable) { try await api2.searchStops("Hbf") }
        #expect(unavailable.requests.count == 1)
    }

    @Test func nearbySearchRoundsToThreeDecimals() async throws {
        let transport = FakeTransport(json: Fixture.emptyLocations)
        _ = try await client(transport).nearbyStops(around: FakeLocation.duesseldorf.coordinate)
        let items = URLComponents(url: try #require(transport.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(items == [URLQueryItem(name: "lat", value: "51.220"), URLQueryItem(name: "lon", value: "6.790")])
    }

    @Test func routesPostsJSONBody() async throws {
        let transport = FakeTransport(json: try Fixture.data("routes", "json"))
        let request = RoutesRequest(origin: .coordinate(FakeLocation.duesseldorf.coordinate), destination: .stop(id: "s"))
        let response = try await client(transport).routes(request)
        #expect(response.journeys.count == 2)
        let req = try #require(transport.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let origin = try #require(try jsonObject(req.httpBody)["origin"] as? [String: Any])
        #expect(origin["latitude"] as? Double == 51.2201)
    }

    @Test func shortQueryIsRejectedLocally() async throws {
        let transport = FakeTransport(json: Fixture.emptyLocations)
        await #expect(throws: TransitError.invalidRequest) { try await client(transport).searchStops(" a ") }
        #expect(transport.requests.isEmpty)
    }

    @Test func missingTokenSendsNothing() async throws {
        let transport = FakeTransport(json: Fixture.emptyLocations)
        await #expect(throws: TransitError.missingToken) {
            try await client(transport, secrets: InMemorySecretStore(token: nil)).searchStops("Hbf")
        }
        #expect(transport.requests.isEmpty)
    }

    // MARK: Fehler

    @Test(arguments: [
        (410, "REFRESH_EXPIRED", TransitError.refreshExpired),
        (404, "NO_CONNECTIONS", .noConnections),
        (404, "NOT_FOUND", .notFound),
        (401, "UNAUTHORIZED", .unauthorized),
        (504, "UPSTREAM_TIMEOUT", .upstreamTimeout),
        (500, "SOMETHING_NEW", .internal),
        (502, "CLIENT_OFFLINE", .upstreamUnavailable), // lokale Codes vom Server werden nicht uebernommen
    ])
    func mapsErrorEnvelope(status: Int, code: String, expected: TransitError) async throws {
        let body = Data(#"{"error":{"code":"\#(code)","message":"x"}}"#.utf8)
        let transport = FakeTransport(json: body, status: status)
        await #expect(throws: expected) { try await client(transport).refresh(refreshToken: "token-123") }
    }

    @Test func retryAfterBlocksFurtherRequestsUntilExpired() async throws {
        let clock = TestClock(Date.iso("2026-10-24T06:00:00Z"))
        let limited = FakeTransport.Reply(status: 429, body: Data(#"{"error":{"code":"RATE_LIMITED","message":"x","retryAfterSeconds":60}}"#.utf8),
                                          headers: ["Retry-After": "30"])
        let ok = FakeTransport.Reply(status: 200, body: Fixture.emptyLocations)
        let transport = FakeTransport([limited, ok])
        let api = client(transport, now: { clock.now })

        await #expect(throws: TransitError.rateLimited) { try await api.searchStops("Hbf") }
        clock.advance(10)
        await #expect(throws: TransitError.rateLimited) { try await api.searchStops("Hbf") }
        #expect(transport.requests.count == 1) // zweite Anfrage gar nicht gesendet
        clock.advance(25) // Header (30 s) hat Vorrang vor dem Body
        _ = try await api.searchStops("Hbf")
        #expect(transport.requests.count == 2)
    }

    @Test func undecodableSuccessIsDecodingFailed() async throws {
        let transport = FakeTransport(json: Data("{}".utf8))
        await #expect(throws: TransitError.decodingFailed) { try await client(transport).searchStops("Hbf") }
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, TransitError.offline),
        (.timedOut, .offline),
        (.serverCertificateUntrusted, .pinningFailed),
        (.secureConnectionFailed, .pinningFailed),
        (.cancelled, .pinningFailed),
        (.badServerResponse, .upstreamUnavailable),
    ])
    func mapsURLErrors(code: URLError.Code, expected: TransitError) async throws {
        let transport = FakeTransport([.init(error: URLError(code))])
        await #expect(throws: expected) { try await client(transport).searchStops("Hbf") }
    }

    // MARK: Session und Pinning

    @Test func sessionConfigurationFollowsAgentRules() {
        let c = PinnedSessionTransport.makeConfiguration()
        #expect(c.tlsMinimumSupportedProtocolVersion == .TLSv13)
        #expect(c.waitsForConnectivity)
        #expect(c.urlCache == nil)
        #expect(c.httpCookieStorage == nil)
        #expect(c.urlCredentialStorage == nil)
        #expect(c.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(c.timeoutIntervalForResource <= 60)
    }

    /// Das echte Leaf-Zertifikat des Servers (Stand 24.10.2026) ergibt exakt den konfigurierten Pin.
    @Test func spkiHashOfLiveCertificateMatchesPrimaryPin() throws {
        let der = try Fixture.data("backend-leaf-2026-10", "der")
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let hash = try #require(PinValidator.spkiSHA256(of: cert))
        #expect(hash.base64EncodedString() == BackendConfig.production.primaryPin)
    }

    @Test func releaseReadinessNeedsTwoDistinctValidPins() {
        let pin = BackendConfig.production.primaryPin
        #expect(BackendConfig(host: "h", primaryPin: pin, backupPin: nil).isPinningReleaseReady == false)
        #expect(BackendConfig(host: "h", primaryPin: pin, backupPin: pin).isPinningReleaseReady == false)
        #expect(BackendConfig(host: "h", primaryPin: pin, backupPin: "kaputt").isPinningReleaseReady == false)
        let other = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(BackendConfig(host: "h", primaryPin: pin, backupPin: other).isPinningReleaseReady)
    }
}

final class TestClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
