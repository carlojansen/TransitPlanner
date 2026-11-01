import AppIntents

/// `LiveActivityIntent` laeuft im App-Prozess; das Widget zeigt nur den Knopf und kennt keinen API-Client.
/// Wichtig ohne Push: vor der Navigation ist das der einzige Abgleich, ohne die App zu oeffnen.
struct RefreshTripIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Fahrt aktualisieren"
    static let isDiscoverable = false

    @MainActor func perform() async throws -> some IntentResult {
        await TripRefreshHandler.run?()
        return .result()
    }
}

@MainActor enum TripRefreshHandler {
    /// Setzt die App beim Start; im Widget-Prozess bleibt es nil.
    static var run: (@MainActor () async -> Void)?
}
