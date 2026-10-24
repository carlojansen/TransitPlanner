import Foundation

/// Einziger Zugang zum Backend. Sendet nur Koordinaten, Stop-IDs, Haltestellen-Suchtexte, Zeit und Filter.
public actor TransitAPIClient {
    private let config: BackendConfig
    private let transport: any HTTPTransport
    private let secrets: any SecretStore
    private let now: @Sendable () -> Date
    private let decoder = TransitJSON.decoder()
    private let encoder = TransitJSON.encoder()

    /// Gesetzt nach 429/502/503/504 mit Retry-After: bis dahin keine Anfragen (schont Transitous).
    public private(set) var blocked: (until: Date, reason: TransitError)?

    /// Produktiv immer mit gepinnter Session; ein eigener Transport ist nur fuer Tests vorgesehen (internal).
    public init(config: BackendConfig = .production,
                secrets: any SecretStore = KeychainSecretStore(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(config: config, transport: PinnedSessionTransport(config: config), secrets: secrets, now: now)
    }

    init(config: BackendConfig, transport: any HTTPTransport, secrets: any SecretStore,
         now: @escaping @Sendable () -> Date) {
        self.config = config
        self.transport = transport
        self.secrets = secrets
        self.now = now
    }

    // MARK: Endpunkte

    /// Haltestellen-Textsuche. Geht ohne Standort ans Backend (docs/API.md).
    public func searchStops(_ text: String) async throws(TransitError) -> LocationsResponse {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...80).contains(q.count) else { throw .invalidRequest }
        return try await send(path: "/api/locations", query: [URLQueryItem(name: "query", value: q)])
    }

    /// Umkreissuche (500 m). Koordinate wird auf 3 Nachkommastellen gerundet.
    public func nearbyStops(around coordinate: GeoCoordinate) async throws(TransitError) -> LocationsResponse {
        let r = coordinate.rounded(decimals: PrivacyRounding.nearbyDecimals)
        return try await send(path: "/api/locations", query: [
            URLQueryItem(name: "lat", value: String(format: "%.3f", r.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.3f", r.longitude)),
        ])
    }

    public func routes(_ request: RoutesRequest) async throws(TransitError) -> RoutesResponse {
        try await send(path: "/api/routes", body: try encode(request))
    }

    public func refresh(refreshToken: String, polylines: Bool = false) async throws(TransitError) -> RefreshResponse {
        try await send(path: "/api/refresh", body: try encode(RefreshRequest(refreshToken: refreshToken, polylines: polylines)))
    }

    // MARK: Intern

    private func encode(_ value: some Encodable) throws(TransitError) -> Data {
        do { return try encoder.encode(value) } catch { throw .invalidRequest }
    }

    private func send<T: Decodable>(path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws(TransitError) -> T {
        if let blocked, blocked.until > now() { throw blocked.reason }
        blocked = nil

        guard let base = config.baseURL, var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw .internal }
        components.path = path
        // URLComponents kodiert "+" nicht; Server lesen es als Leerzeichen. Daher selbst kodieren.
        components.percentEncodedQueryItems = query.isEmpty ? nil : query.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed))
        }
        guard let url = components.url else { throw .invalidRequest }

        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Bearer \(try secrets.bearerToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Fest statt Geraetesprache: kein zusaetzliches Fingerprinting-Merkmal.
        request.setValue("de", forHTTPHeaderField: "Accept-Language")
        // Fester User-Agent statt CFNetwork-Standard (der OS- und Geraeteversion verraet).
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            throw Self.map(error)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .upstreamUnavailable
        }

        guard (200..<300).contains(response.statusCode) else {
            throw handleFailure(status: response.statusCode, data: data, headers: response)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw .decodingFailed
        }
    }

    private func handleFailure(status: Int, data: Data, headers: HTTPURLResponse) -> TransitError {
        let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
        let code = envelope.flatMap { TransitError(rawValue: $0.error.code) }
            .flatMap { TransitError.backendCodes.contains($0) ? $0 : nil }
            ?? TransitError.fromHTTPStatus(status)
        let headerSeconds = headers.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
        if Self.retryAfterStatuses.contains(status), let seconds = headerSeconds ?? envelope?.error.retryAfterSeconds, seconds > 0 {
            blocked = (now().addingTimeInterval(TimeInterval(min(seconds, 300))), code)
        }
        return code
    }

    static let retryAfterStatuses: Set<Int> = [429, 502, 503, 504]

    static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?#")
        return set
    }()

    static func map(_ error: URLError) -> TransitError {
        switch error.code {
        case .cancelled:
            // Abgebrochene Server-Trust-Pruefung meldet URLSession ebenfalls als .cancelled.
            Task.isCancelled ? .cancelled : .pinningFailed
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut, .callIsActive:
            .offline
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            .pinningFailed
        case .httpTooManyRedirects, .redirectToNonExistentLocation:
            .internal
        default:
            .upstreamUnavailable
        }
    }
}
