import Foundation
import Testing
import TransitCore

/// Echte Keychain. Laeuft in der Host-App, weil Paket-Tests ohne Host keine Keychain-Berechtigung haben (-34018).
@Suite struct KeychainTests {
    @Test func writeReadOverwriteDelete() throws {
        let store = KeychainSecretStore(service: "TransitPlanner.tests.\(UUID().uuidString)")
        #expect(try store.read(.apiToken) == nil)
        #expect(throws: TransitError.missingToken) { try store.bearerToken() }
        try store.write(Data("eins".utf8), for: .apiToken)
        try store.write(Data("zwei".utf8), for: .apiToken)
        #expect(try store.bearerToken() == "zwei")
        try store.delete(.apiToken)
        try store.delete(.apiToken) // idempotent
        #expect(try store.read(.apiToken) == nil)
    }
}
