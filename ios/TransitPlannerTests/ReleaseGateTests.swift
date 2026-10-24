import Foundation
import Testing
import TransitCore

/// Erwarteter Release-Blocker: schlaegt fehl, solange kein zweiter (Backup-)SPKI-Pin eingetragen ist.
/// Nur im Schema `TransitPlanner-ReleaseGate` aktiv, damit die normale Testsuite gruen bleibt.
@Suite struct ReleaseGateTests {
    @Test("Release-Blocker: zwei SPKI-Pins hinterlegt",
          .enabled(if: ProcessInfo.processInfo.environment["TRANSITPLANNER_RELEASE_GATE"] == "1"))
    func productionHasTwoPins() {
        #expect(BackendConfig.production.isPinningReleaseReady,
                "Backup-Pin fehlt: backend/deploy/spki-hash.sh new-backup, Pin in BackendConfig.swift eintragen")
    }
}
