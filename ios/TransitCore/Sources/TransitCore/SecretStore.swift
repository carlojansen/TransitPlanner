import Foundation
import Security

/// Schluessel fuer Geheimnisse in der Keychain.
public enum SecretKey: Sendable, Hashable {
    /// Bearer-Token fuer das eigene Backend (wird vom Nutzer eingetragen, nie im Code).
    case apiToken
    /// AES-GCM-Schluessel fuer lokal verschluesselte Koordinaten (Wohn-/Arbeitsort).
    case coordinateKey
    /// refreshToken einer aktiven/geplanten Fahrt (AGENT.md 3.3.2).
    case refreshToken(tripID: UUID)

    var account: String {
        switch self {
        case .apiToken: "api-token"
        case .coordinateKey: "coordinate-key"
        case .refreshToken(let id): "refresh-\(id.uuidString)"
        }
    }
}

public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) throws(TransitError) -> Data?
    func write(_ data: Data, for key: SecretKey) throws(TransitError)
    func delete(_ key: SecretKey) throws(TransitError)
}

public extension SecretStore {
    func bearerToken() throws(TransitError) -> String {
        guard let data = try read(.apiToken), let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { throw .missingToken }
        return token
    }
}

/// Keychain mit `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (kein Backup, kein Geraetewechsel).
public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "TransitPlanner.secrets") {
        self.service = service
    }

    private func baseQuery(_ key: SecretKey) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.account,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    public func read(_ key: SecretKey) throws(TransitError) -> Data? {
        var q = baseQuery(key)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        default: throw .keychainFailure
        }
    }

    public func write(_ data: Data, for key: SecretKey) throws(TransitError) {
        let q = baseQuery(key)
        let attrs: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(q.merging(attrs) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw .keychainFailure }
    }

    public func delete(_ key: SecretKey) throws(TransitError) {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychainFailure }
    }
}
