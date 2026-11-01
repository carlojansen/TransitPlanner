import Foundation

/// Spiegel der Backend-Fehlercodes aus docs/API.md (gleiche Rohwerte) plus wenige rein lokale Faelle,
/// die nie vom Backend kommen (Netz, Pinning, Keychain, Standort). Alle Fehler der Core-Engine sind `TransitError`.
public enum TransitError: String, LocalizedError, Codable, Sendable, CaseIterable {
    // Backend (docs/API.md, Tabelle "Fehler")
    case invalidRequest = "INVALID_REQUEST"
    case unauthorized = "UNAUTHORIZED"
    case notFound = "NOT_FOUND"
    case noConnections = "NO_CONNECTIONS"
    case refreshExpired = "REFRESH_EXPIRED"
    case rateLimited = "RATE_LIMITED"
    case upstreamUnavailable = "UPSTREAM_UNAVAILABLE"
    case upstreamTimeout = "UPSTREAM_TIMEOUT"
    case `internal` = "INTERNAL"

    // Nur lokal (App)
    case offline = "CLIENT_OFFLINE"
    case pinningFailed = "CLIENT_PINNING_FAILED"
    case decodingFailed = "CLIENT_DECODING_FAILED"
    case missingToken = "CLIENT_MISSING_TOKEN"
    case keychainFailure = "CLIENT_KEYCHAIN_FAILURE"
    case storageUnavailable = "CLIENT_STORAGE_UNAVAILABLE"
    case locationDenied = "CLIENT_LOCATION_DENIED"
    case locationUnavailable = "CLIENT_LOCATION_UNAVAILABLE"
    case cancelled = "CLIENT_CANCELLED"

    /// Codes, die das Backend senden kann.
    public static let backendCodes: [TransitError] = [
        .invalidRequest, .unauthorized, .notFound, .noConnections, .refreshExpired,
        .rateLimited, .upstreamUnavailable, .upstreamTimeout, .internal,
    ]

    /// Ruhiger Text fuer das Inline-Banner (AGENT.md Punkt 7), ohne technische Details. Texte im String Catalog.
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: String(localized: "Die Anfrage war ungültig.", bundle: .module)
        case .unauthorized, .missingToken: String(localized: "Zugang zum Fahrplan-Server fehlt oder ist abgelaufen.", bundle: .module)
        case .notFound: String(localized: "Haltestelle nicht mehr bekannt. Bitte neu suchen.", bundle: .module)
        case .noConnections: String(localized: "Keine Verbindung gefunden.", bundle: .module)
        case .refreshExpired: String(localized: "Die Verbindung ist nicht mehr aktuell. Bitte neu suchen.", bundle: .module)
        case .rateLimited: String(localized: "Zu viele Anfragen. Bitte kurz warten.", bundle: .module)
        case .upstreamUnavailable: String(localized: "Fahrplandaten sind gerade nicht erreichbar.", bundle: .module)
        case .upstreamTimeout: String(localized: "Fahrplandaten antworten zu langsam.", bundle: .module)
        case .internal, .decodingFailed: String(localized: "Unerwartete Antwort vom Fahrplan-Server.", bundle: .module)
        case .offline: String(localized: "Keine Internetverbindung.", bundle: .module)
        case .pinningFailed: String(localized: "Sichere Verbindung zum Server nicht möglich.", bundle: .module)
        case .keychainFailure: String(localized: "Zugangsdaten konnten nicht gelesen werden.", bundle: .module)
        case .storageUnavailable: String(localized: "Erinnerungen können gerade nicht gespeichert werden.", bundle: .module)
        case .locationDenied: String(localized: "Standortzugriff ist nicht erlaubt.", bundle: .module)
        case .locationUnavailable: String(localized: "Standort ist gerade nicht verfügbar.", bundle: .module)
        case .cancelled: String(localized: "Abgebrochen.", bundle: .module)
        }
    }

    /// Lohnt sich ein spaeterer automatischer Neuversuch?
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .upstreamUnavailable, .upstreamTimeout, .offline: true
        default: false
        }
    }

    /// Fallback, wenn der Fehlerbody fehlt oder unbekannt ist.
    static func fromHTTPStatus(_ status: Int) -> TransitError {
        switch status {
        case 400: .invalidRequest
        case 401, 403: .unauthorized
        case 404: .notFound
        case 410: .refreshExpired
        case 429: .rateLimited
        case 502, 503: .upstreamUnavailable
        case 504: .upstreamTimeout
        default: .internal
        }
    }
}
