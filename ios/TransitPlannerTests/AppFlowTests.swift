// Nur Debug: braucht `@testable import` und die Fakes. Im Release-Gate (Release) laeuft nur die Pinning-Sperre.
#if DEBUG
import Foundation
import Testing
import TransitCore
@testable import TransitPlanner

/// Reine Uebergangsfunktion als Tabelle (RESEARCH-M3 Abschnitt 10).
@Suite struct PhaseTransitionTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let from: Phase
        let event: FlowEvent
        let to: Phase?
        var testDescription: String { "\(from) + \(event) -> \(to.map { "\($0)" } ?? "ignoriert")" }
    }

    static let table: [Row] = [
        Row(from: .start, event: .editEndpoint(.origin), to: .search(.origin)),
        Row(from: .start, event: .editEndpoint(.destination), to: .search(.destination)),
        Row(from: .start, event: .planTapped, to: .routeSelection),
        Row(from: .start, event: .back, to: nil),
        Row(from: .start, event: .reset, to: nil),
        Row(from: .start, event: .journeySelected(0), to: nil),
        Row(from: .start, event: .startNavigation, to: nil),
        Row(from: .search(.origin), event: .endpointChosen, to: .start),
        Row(from: .search(.destination), event: .back, to: .start),
        Row(from: .search(.origin), event: .planTapped, to: nil),
        Row(from: .search(.origin), event: .editEndpoint(.destination), to: nil),
        Row(from: .routeSelection, event: .journeySelected(2), to: .tripDetails(2)),
        Row(from: .routeSelection, event: .planTapped, to: .routeSelection),
        Row(from: .routeSelection, event: .editEndpoint(.destination), to: .search(.destination)),
        Row(from: .routeSelection, event: .back, to: .start),
        Row(from: .routeSelection, event: .startNavigation, to: nil),
        Row(from: .tripDetails(1), event: .startNavigation, to: .navigation(1)),
        Row(from: .tripDetails(1), event: .back, to: .routeSelection),
        Row(from: .tripDetails(1), event: .journeySelected(0), to: nil),
        Row(from: .navigation(1), event: .arrived, to: .arrival),
        Row(from: .navigation(1), event: .back, to: .tripDetails(1)),
        Row(from: .navigation(1), event: .reset, to: .start),
        Row(from: .arrival, event: .back, to: .start),
        Row(from: .arrival, event: .reset, to: .start),
        Row(from: .arrival, event: .arrived, to: nil),
    ]

    @Test(arguments: table)
    func transition(_ row: Row) {
        #expect(AppFlow.next(row.from, row.event) == row.to)
    }

    @Test func workContextKeepsPlanningAcrossTripDetails() {
        #expect(Phase.routeSelection.workContext == Phase.tripDetails(0).workContext)
        #expect(Phase.search(.origin).workContext != Phase.start.workContext)
        #expect(Phase.navigation(0).workContext != Phase.routeSelection.workContext)
    }
}

@Suite struct BannerMappingTests {
    @Test func everyErrorHasDefinedPresentation() {
        #expect(!TransitError.cancelled.showsBanner)
        #expect(!TransitError.noConnections.showsBanner) // Leerzustand in der Liste
        for e in TransitError.allCases where e != .cancelled && e != .noConnections {
            #expect(e.showsBanner)
        }
        #expect(TransitError.offline.bannerActions == [.retry])
        #expect(TransitError.missingToken.bannerActions == [.enterKey])
        #expect(TransitError.unauthorized.bannerActions == [.enterKey])
        #expect(TransitError.locationDenied.bannerActions == [.openSettings, .switchToStops])
        #expect(TransitError.notFound.bannerActions == [.newSearch])
        #expect(TransitError.rateLimited.bannerActions.isEmpty) // Restzeit statt Neuversuch
        #expect(TransitError.pinningFailed.bannerActions.isEmpty) // keine Umgehung
    }

    @Test func serverKeyValidationMatchesBackendRules() {
        let valid = String(repeating: "a", count: 32)
        #expect(AppFlow.validatedServerKey("  \(valid)\n") == valid)
        #expect(AppFlow.validatedServerKey(String(repeating: "a", count: 31)) == nil)
        #expect(AppFlow.validatedServerKey(String(repeating: "a", count: 513)) == nil)
        #expect(AppFlow.validatedServerKey(String(repeating: "a", count: 20) + " " + String(repeating: "b", count: 20)) == nil)
        #expect(AppFlow.validatedServerKey(String(repeating: "ä", count: 40)) == nil)
    }
}

@MainActor @Suite struct AppFlowTests {
    static let stopEndpoint = TripEndpoint.stop(id: "de-DELFI_de:05315:11201", label: "Köln Hbf")
    static let addressEndpoint = TripEndpoint.coordinate(GeoCoordinate(latitude: 51.2201, longitude: 6.7905), label: "Musterstraße 1")

    func flow(search: FakeStopSearch = FakeStopSearch(), planner: FakeRoutePlanner = FakeRoutePlanner(),
              secrets: InMemorySecretStore = InMemorySecretStore(), blockedUntil: Date? = nil) -> AppFlow {
        AppFlow(.fakes(search: search, planner: planner, secrets: secrets, blockedUntil: blockedUntil,
                       debounce: .milliseconds(30)))
    }

    @Test func startsInAddressModeWithoutKey() {
        let f = flow()
        #expect(f.phase == .start)
        #expect(f.scope == .address)
        #expect(!f.hasServerKey)
        #expect(!f.canPlan)
    }

    @Test func debounceSendsOnlyLastQuery() async {
        let search = FakeStopSearch()
        let f = flow(search: search)
        f.send(.editEndpoint(.destination))
        f.setScope(.stops)
        for text in ["K", "Kö", "Köl", "Köln"] {
            f.query = text
            f.queryChanged()
        }
        await f.waitForWork()
        #expect(search.recorded == ["Köln"])
        #expect(f.results.stops.count == 2)
        #expect(f.attribution != nil)
    }

    @Test func returnSearchesImmediatelyAndShortTextNever() async {
        let search = FakeStopSearch()
        let f = flow(search: search)
        f.send(.editEndpoint(.origin))
        f.query = "a"
        f.submitSearch()
        await f.waitForWork()
        #expect(search.recorded.isEmpty)
        f.query = "Hbf"
        f.submitSearch()
        await f.waitForWork()
        #expect(search.recorded == ["Hbf"])
    }

    @Test func queryIsCappedAt80Characters() async {
        let search = FakeStopSearch()
        let f = flow(search: search)
        f.send(.editEndpoint(.origin))
        f.query = String(repeating: "x", count: 120)
        f.submitSearch()
        await f.waitForWork()
        #expect(search.recorded.first?.count == AppFlow.maxQueryLength)
    }

    @Test func leavingSearchCancelsRunningSearch() async {
        let search = FakeStopSearch(delay: .seconds(5))
        let f = flow(search: search)
        f.send(.editEndpoint(.origin))
        f.query = "Hbf"
        f.submitSearch()
        try? await Task.sleep(for: .milliseconds(50))
        f.send(.back)
        await f.waitForWork()
        #expect(f.phase == .start)
        #expect(!f.isSearching)
        #expect(f.results.addresses.isEmpty)
        #expect(f.banner == nil) // Abbruch zeigt nichts
    }

    @Test func choosingEndpointsEnablesPlanning() {
        let f = flow()
        f.send(.editEndpoint(.origin))
        f.choose(Self.addressEndpoint)
        #expect(f.phase == .start)
        f.send(.editEndpoint(.destination))
        f.choose(Self.stopEndpoint)
        #expect(f.origin == Self.addressEndpoint && f.destination == Self.stopEndpoint)
        #expect(f.canPlan)
        f.swapEndpoints()
        #expect(f.origin == Self.stopEndpoint)
    }

    @Test func planShowsSkeletonThenCalibrated() async {
        let planner = FakeRoutePlanner()
        let f = flow(planner: planner)
        f.send(.editEndpoint(.origin)); f.choose(Self.addressEndpoint)
        f.send(.editEndpoint(.destination)); f.choose(Self.stopEndpoint)
        f.send(.planTapped)
        #expect(f.phase == .routeSelection)
        #expect(f.isPlanning)
        await f.waitForWork()
        #expect(!f.isPlanning)
        #expect(f.routes?.journeys.count == 1)
        #expect(f.calibratedJourney(at: 0)?.walks.count == 3)
        #expect(f.routes?.journeys.first?.legs[3].replacement == true)
        #expect(f.attribution?.httpsLinks.count == 2)
        #expect(planner.callCount == 1)

        // Fahrtdetails und zurueck: keine neue Anfrage (Rate-Limit schonen)
        f.send(.journeySelected(0))
        f.send(.back)
        #expect(planner.callCount == 1)
        #expect(f.calibrated != nil)
    }

    @Test func planFailureShowsBannerAndRetryReplans() async {
        let planner = FakeRoutePlanner(failure: .upstreamUnavailable)
        let f = flow(planner: planner)
        f.send(.editEndpoint(.origin)); f.choose(Self.stopEndpoint)
        f.send(.editEndpoint(.destination)); f.choose(Self.addressEndpoint)
        f.send(.planTapped)
        await f.waitForWork()
        #expect(f.banner == .upstreamUnavailable)
        f.perform(.retry)
        await f.waitForWork()
        #expect(planner.callCount == 2)
        // Phasenwechsel raeumt das Banner weg
        f.send(.back)
        #expect(f.banner == nil)
    }

    @Test func rateLimitBlocksPlanningUntilRetryAfter() async {
        let planner = FakeRoutePlanner(failure: .rateLimited)
        let f = flow(planner: planner, blockedUntil: Date().addingTimeInterval(60))
        f.send(.editEndpoint(.origin)); f.choose(Self.stopEndpoint)
        f.send(.editEndpoint(.destination)); f.choose(Self.addressEndpoint)
        f.send(.planTapped)
        await f.waitForWork()
        #expect(f.banner == .rateLimited)
        #expect(f.blockedUntil != nil)
        #expect(!f.canPlan)
        #expect(f.actions(for: .upstreamUnavailable).isEmpty) // kein "Erneut versuchen" waehrend der Sperre
        f.send(.back)
        f.send(.planTapped) // bei Sperre abgelehnt statt leerer Liste
        await f.waitForWork()
        #expect(f.phase == .start)
        #expect(planner.callCount == 1)
    }

    /// Zero-Knowledge: Text aus dem Adressmodus geht nach Moduswechsel nie ans Backend.
    @Test func switchingToStopsNeverSendsAddressText() async {
        let search = FakeStopSearch()
        let f = flow(search: search)
        f.send(.editEndpoint(.origin))
        f.query = "Musterstraße 5"
        f.queryChanged()
        f.setScope(.stops)
        #expect(f.query.isEmpty)
        f.queryChanged()
        f.submitSearch()
        await f.waitForWork()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(search.recorded.isEmpty)

        // Gleiches ueber die Banner-Aktion bei verweigertem Standort
        let denied = FakeStopSearch(failure: .locationDenied)
        let g = flow(search: denied)
        g.send(.editEndpoint(.origin))
        g.query = "Musterstraße 5"
        g.submitSearch()
        await g.waitForWork()
        g.perform(.switchToStops)
        await g.waitForWork()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(g.query.isEmpty)
        #expect(denied.recorded == ["Musterstraße 5"]) // nur die lokale Adresssuche
    }

    @Test func keychainFailureAtStartShowsBanner() {
        struct BrokenStore: SecretStore {
            func read(_ key: SecretKey) throws(TransitError) -> Data? { throw .keychainFailure }
            func write(_ data: Data, for key: SecretKey) throws(TransitError) { throw .keychainFailure }
            func delete(_ key: SecretKey) throws(TransitError) { throw .keychainFailure }
        }
        var deps = AppDependencies.fakes()
        deps.secrets = BrokenStore()
        let f = AppFlow(deps)
        #expect(f.banner == .keychainFailure)
        #expect(!f.hasServerKey)
    }

    @Test func missingKeyBannerOpensSettingsAndClearsAfterSave() async throws {
        let f = flow(search: FakeStopSearch(failure: .missingToken))
        f.send(.editEndpoint(.origin))
        f.setScope(.stops)
        f.query = "Hbf"
        f.submitSearch()
        await f.waitForWork()
        #expect(f.banner == .missingToken)
        f.perform(.enterKey)
        #expect(f.showsSettings)
        try f.saveServerKey(String(repeating: "k", count: 40))
        #expect(f.hasServerKey)
        #expect(f.banner == nil)
        try f.deleteServerKey()
        #expect(!f.hasServerKey)
    }

    @Test func locationDeniedOffersSwitchToStopsWithoutAutoSwitch() async {
        let f = flow(search: FakeStopSearch(failure: .locationDenied))
        f.send(.editEndpoint(.origin))
        f.query = "Musterstraße"
        f.submitSearch()
        await f.waitForWork()
        #expect(f.banner == .locationDenied)
        #expect(f.scope == .address) // kein automatischer Wechsel
        f.perform(.switchToStops)
        #expect(f.scope == .stops)
    }
}

@Suite struct SpokenTextTests {
    @Test func pluralFromStringCatalog() {
        #expect(String(localized: "\(1) Umstiege") == "1 Umstieg")
        #expect(String(localized: "\(2) Umstiege") == "2 Umstiege")
    }

    @Test func journeySentenceNamesLinesAndFlags() throws {
        let journey = try #require(FakeData.routes?.journeys.first)
        let departure = try #require(journey.departure)
        let text = Spoken.journey(journey, calibrated: nil, now: departure.addingTimeInterval(-7 * 60))
        #expect(text.contains("In 7 Minuten losgehen."))
        #expect(text.contains("Straßenbahn STR 704, dann Bus SEV RE 5."))
        #expect(text.contains("1 Umstieg."))
        #expect(text.contains("Mit Ersatzverkehr."))
    }

    @Test func stepSentence() throws {
        let steps = try #require(FakeData.routes?.journeys.first?.legs[2].steps)
        #expect(Spoken.step(steps[0]) == "Treppe, nach unten, Ebene 1 zu 0, 20 Meter.")
    }
}
#endif
