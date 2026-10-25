// Nur Debug: braucht `@testable import` und die Fakes. Im Release-Gate (Release) laeuft nur die Pinning-Sperre.
#if DEBUG
import Foundation
import Testing
import UIKit
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
        Row(from: .start, event: .editEndpoint(.destination), to: .search(.destination, .start)),
        Row(from: .start, event: .editEndpoint(.origin), to: .search(.origin, .start)),
        Row(from: .start, event: .planTapped, to: nil),
        Row(from: .start, event: .back, to: nil),
        Row(from: .start, event: .reset, to: nil),
        Row(from: .start, event: .journeySelected(0), to: nil),
        Row(from: .start, event: .startNavigation(0), to: nil),
        Row(from: .search(.destination, .start), event: .endpointChosen, to: .routeSelection),
        Row(from: .search(.destination, .start), event: .back, to: .start),
        Row(from: .search(.origin, .options), event: .endpointChosen, to: .options),
        Row(from: .search(.origin, .options), event: .back, to: .options),
        Row(from: .search(.origin, .start), event: .planTapped, to: nil),
        Row(from: .search(.origin, .start), event: .editEndpoint(.destination), to: nil),
        Row(from: .options, event: .editEndpoint(.origin), to: .search(.origin, .options)),
        Row(from: .options, event: .planTapped, to: .routeSelection),
        Row(from: .options, event: .back, to: .routeSelection),
        Row(from: .routeSelection, event: .editOptions, to: .options),
        Row(from: .routeSelection, event: .journeySelected(2), to: .tripDetails(2)),
        Row(from: .routeSelection, event: .planTapped, to: .routeSelection),
        Row(from: .routeSelection, event: .startNavigation(0), to: .navigation(0)),
        Row(from: .routeSelection, event: .back, to: .start),
        Row(from: .routeSelection, event: .editEndpoint(.destination), to: nil),
        Row(from: .tripDetails(1), event: .startNavigation(1), to: .navigation(1)),
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

    @Test func workContextKeepsPlanningAcrossOptionsAndDetails() {
        #expect(Phase.routeSelection.workContext == Phase.tripDetails(0).workContext)
        #expect(Phase.options.workContext == Phase.routeSelection.workContext)
        #expect(Phase.search(.origin, .options).workContext != Phase.options.workContext)
        #expect(Phase.navigation(0).workContext != Phase.routeSelection.workContext)
    }

    @Test func backwardEventsAreMarked() {
        #expect(FlowEvent.back.isBackward && FlowEvent.reset.isBackward)
        #expect(!FlowEvent.planTapped.isBackward && !FlowEvent.editOptions.isBackward)
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

    @Test func toneAndAddressMessage() {
        #expect(InlineBanner.tone(for: .pinningFailed) == .alert)
        #expect(InlineBanner.tone(for: .offline) == .warn)
        #expect(InlineBanner.tone(for: .missingToken) == .info)
        #expect(InlineBanner.message(for: .locationDenied, scope: .address, phase: .search(.destination, .start))
                == "Adresssuche braucht deinen Standort.")
        #expect(InlineBanner.message(for: .locationDenied, scope: .stops, phase: .search(.destination, .start))
                == TransitError.locationDenied.errorDescription)
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
              secrets: InMemorySecretStore = InMemorySecretStore(), location: FakeLocation = FakeLocation(),
              onboarding: OnboardingChoice? = .withLocation, blockedUntil: Date? = nil,
              waitingHint: Duration = .seconds(3)) -> AppFlow {
        AppFlow(.fakes(search: search, planner: planner, secrets: secrets, location: location, onboarding: onboarding,
                       blockedUntil: blockedUntil, debounce: .milliseconds(30), waitingHint: waitingHint))
    }

    /// Ziel ueber 1 Start waehlen: plant sofort (DESIGN.md 2b).
    func chooseDestination(_ f: AppFlow, _ endpoint: TripEndpoint = stopEndpoint) {
        f.send(.editEndpoint(.destination))
        f.choose(endpoint)
    }

    // MARK: Erster Start

    static func noLocation() -> FakeLocation { FakeLocation(status: .notDetermined) }

    @Test func firstStartShowsWelcomeThenServerKey() async {
        let f = flow(location: Self.noLocation(), onboarding: nil)
        #expect(f.onboarding == .welcome)
        #expect(!f.locationAllowed)
        await f.finishWelcome(allowLocation: true)
        #expect(f.onboarding == .serverKey)
        #expect(f.locationAllowed) // aus dem (Fake-)iOS-Status, nicht aus dem Onboarding-Flag
        #expect(f.lastAccuracy == FakeLocation.fix.horizontalAccuracy)
        f.finishServerKeyStep()
        #expect(f.onboarding == nil)
    }

    @Test func welcomeWithKeySkipsServerStepAndRemembersChoice() async throws {
        let f = flow(secrets: InMemorySecretStore(token: String(repeating: "k", count: 40)),
                     location: Self.noLocation(), onboarding: nil)
        await f.finishWelcome(allowLocation: false)
        #expect(f.onboarding == nil)
        #expect(!f.locationAllowed)
        #expect(f.lastAccuracy == nil)
        #expect(flow(onboarding: .withoutLocation).onboarding == nil)
    }

    // MARK: Suche

    @Test func startsInAddressModeOnStart() {
        let f = flow()
        #expect(f.phase == .start)
        #expect(f.scope == .address)
        #expect(!f.hasServerKey)
        #expect(!f.canPlan) // ohne Ziel
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
        #expect(search.recorded == [.init(text: "Köln", scope: .stops)])
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
        #expect(search.recordedTexts == ["Hbf"])
    }

    @Test func queryIsCappedAt80Characters() async {
        let search = FakeStopSearch()
        let f = flow(search: search)
        f.send(.editEndpoint(.origin))
        f.query = String(repeating: "x", count: 120)
        f.submitSearch()
        await f.waitForWork()
        #expect(search.recordedTexts.first?.count == AppFlow.maxQueryLength)
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
        #expect(f.movedBackward)
        #expect(!f.isSearching)
        #expect(f.results.addresses.isEmpty)
        #expect(f.banner == nil) // Abbruch zeigt nichts
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
        #expect(search.recorded.allSatisfy { $0.scope == .address })
        #expect(!search.recorded.contains { $0.scope == .stops })

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
        #expect(denied.recorded == [.init(text: "Musterstraße 5", scope: .address)])
    }

    @Test func addressSearchWithoutLocationAsksInsteadOfSearching() async {
        let search = FakeStopSearch()
        let f = flow(search: search, location: Self.noLocation(), onboarding: .withoutLocation)
        f.send(.editEndpoint(.destination))
        f.query = "Musterstraße"
        f.submitSearch()
        await f.waitForWork()
        #expect(search.recorded.isEmpty) // ohne GPS-Region keine Adresssuche
        #expect(f.banner == .locationDenied)
        #expect(f.actions(for: .locationDenied) == [.allowLocation, .switchToStops])
        #expect(f.scope == .address) // kein automatischer Wechsel
    }

    // MARK: Planung

    @Test func destinationFromStartPlansWithCurrentLocation() async throws {
        let planner = FakeRoutePlanner()
        let f = flow(planner: planner)
        chooseDestination(f)
        #expect(f.phase == .routeSelection)
        #expect(f.isPlanning)
        await f.waitForWork()
        #expect(!f.isPlanning)
        #expect(f.routes?.journeys.count == 2)
        #expect(f.calibratedJourney(at: 0)?.walks.count == 3)
        #expect(f.routes?.journeys.first?.legs[3].replacement == true)
        #expect(f.attribution?.httpsLinks.count == 2)
        #expect(f.overlay?.segments.count == 5)
        #expect(f.overlay?.segments.first?.isWalk == true)

        // "Mein Standort": nur die (gerundete) Koordinate geht raus, kein Label
        let request = try #require(planner.recordedRequests.first)
        #expect(request.origin == .coordinate(FakeLocation.fix.coordinate))
        let body = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!body.contains("Mein Standort") && !body.contains("Köln Hbf"))
    }

    @Test func detailsAndOptionsKeepResultsWithoutNewRequest() async {
        let planner = FakeRoutePlanner()
        let f = flow(planner: planner)
        chooseDestination(f)
        await f.waitForWork()
        let firstOverlay = f.overlay?.id
        f.send(.journeySelected(1))
        await f.waitForWork()
        #expect(f.overlay?.id != firstOverlay) // Karte zeigt die gewaehlte Verbindung
        f.send(.back)
        f.send(.editOptions)
        f.send(.back)
        await f.waitForWork()
        #expect(planner.callCount == 1) // Rate-Limit schonen
        #expect(f.calibrated != nil)
        #expect(f.overlay?.id == firstOverlay)
    }

    @Test func withoutLocationDestinationLeadsToOptions() async {
        let planner = FakeRoutePlanner()
        let f = flow(planner: planner, location: Self.noLocation(), onboarding: .withoutLocation)
        chooseDestination(f)
        #expect(f.phase == .options)
        #expect(planner.callCount == 0)
        f.send(.editEndpoint(.origin))
        f.choose(Self.addressEndpoint)
        #expect(f.phase == .options)
        f.send(.planTapped)
        await f.waitForWork()
        #expect(planner.recordedRequests.first?.origin == .coordinate(GeoCoordinate(latitude: 51.2201, longitude: 6.7905)))
    }

    @Test func locationFailureWhilePlanningShowsBanner() async {
        let planner = FakeRoutePlanner()
        let f = flow(planner: planner, location: FakeLocation(failure: .locationUnavailable))
        chooseDestination(f)
        await f.waitForWork()
        #expect(f.banner == .locationUnavailable)
        #expect(planner.callCount == 0)
        #expect(!f.isPlanning)
    }

    @Test func waitingHintAppearsWhenNetworkIsSlow() async {
        let f = flow(planner: FakeRoutePlanner(delay: .milliseconds(300)), waitingHint: .milliseconds(50))
        chooseDestination(f)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(f.isWaitingForNetwork)
        await f.waitForWork()
        #expect(!f.isWaitingForNetwork)
        #expect(f.routes != nil)
    }

    @Test func offlineReplanKeepsLastAnswerDimmed() async {
        let planner = FakeRoutePlanner()
        let f = flow(planner: planner)
        chooseDestination(f)
        await f.waitForWork()
        planner.setFailure(.offline)
        f.perform(.retry)
        await f.waitForWork()
        #expect(f.banner == .offline)
        #expect(f.isStale)
        #expect(f.routes?.journeys.count == 2)
        planner.setFailure(nil)
        f.perform(.retry)
        await f.waitForWork()
        #expect(!f.isStale)
        #expect(f.banner == nil)

        // Andere Zeit = andere Anfrage: alte Antwort darf nicht als Offline-Stand erscheinen
        planner.setFailure(.offline)
        f.send(.editOptions)
        f.customTime = Date().addingTimeInterval(3600)
        f.send(.planTapped)
        await f.waitForWork()
        #expect(f.routes == nil)
        #expect(!f.isStale)
    }

    @Test func planFailureShowsBannerAndPhaseChangeClearsIt() async {
        let planner = FakeRoutePlanner(failure: .upstreamUnavailable)
        let f = flow(planner: planner)
        chooseDestination(f)
        await f.waitForWork()
        #expect(f.banner == .upstreamUnavailable)
        #expect(f.routes == nil)
        f.perform(.retry)
        await f.waitForWork()
        #expect(planner.callCount == 2)
        f.send(.back)
        #expect(f.banner == nil)
    }

    @Test func rateLimitBlocksPlanningUntilRetryAfter() async {
        let planner = FakeRoutePlanner(failure: .rateLimited)
        let f = flow(planner: planner, blockedUntil: Date().addingTimeInterval(60))
        chooseDestination(f)
        await f.waitForWork()
        #expect(f.banner == .rateLimited)
        #expect(f.blockedUntil != nil)
        #expect(!f.canPlan)
        #expect(f.actions(for: .upstreamUnavailable).isEmpty) // kein "Erneut versuchen" waehrend der Sperre
        f.send(.editOptions)
        f.send(.planTapped) // bei Sperre abgelehnt statt leerer Liste
        await f.waitForWork()
        #expect(f.phase == .options)
        #expect(planner.callCount == 1)
    }

    // MARK: Schluessel und Status

    @Test func missingKeyBannerOpensServerSettingsAndClearsAfterSave() async throws {
        let f = flow(search: FakeStopSearch(failure: .missingToken))
        f.send(.editEndpoint(.origin))
        f.setScope(.stops)
        f.query = "Hbf"
        f.submitSearch()
        await f.waitForWork()
        #expect(f.banner == .missingToken)
        f.perform(.enterKey)
        #expect(f.showsSettings && f.settingsOpensServer)
        try f.saveServerKey(String(repeating: "k", count: 40))
        #expect(f.hasServerKey)
        #expect(f.banner == nil)
        try f.deleteServerKey()
        #expect(!f.hasServerKey)
    }

    @Test func connectionCheckReportsResult() async {
        let ok = flow()
        await ok.checkConnection()
        #expect(ok.connectionCheck == .connected)
        let bad = flow(search: FakeStopSearch(failure: .unauthorized))
        await bad.checkConnection()
        #expect(bad.connectionCheck == .failed(.unauthorized))
    }

    @Test func keychainFailureAtStartShowsBanner() {
        struct BrokenStore: SecretStore {
            func read(_ key: SecretKey) throws(TransitError) -> Data? { throw .keychainFailure }
            func write(_ data: Data, for key: SecretKey) throws(TransitError) { throw .keychainFailure }
            func delete(_ key: SecretKey) throws(TransitError) { throw .keychainFailure }
        }
        var deps = AppDependencies.fakes(onboarding: .withLocation)
        deps.secrets = BrokenStore()
        let f = AppFlow(deps)
        #expect(f.banner == .keychainFailure)
        #expect(!f.hasServerKey)
    }

    /// "Mein Standort" bleibt beim Tauschen Platzhalter: keine GPS-Koordinate im Zustand oder als "Zuletzt gesucht";
    /// aufgeloest wird erst beim Planen, und nur gerundet geht sie raus.
    @Test func swapKeepsCurrentLocationAsPlaceholder() async throws {
        let planner = FakeRoutePlanner()
        let f = flow(planner: planner)
        chooseDestination(f)
        await f.waitForWork()
        #expect(f.canSwap)
        f.swapEndpoints()
        #expect(f.origin == .place(Self.stopEndpoint))
        #expect(f.destination == .currentLocation)
        #expect(f.destination?.place == nil) // nichts fuer "Zuletzt gesucht"
        f.send(.editOptions)
        f.send(.planTapped)
        await f.waitForWork()
        let request = try #require(planner.recordedRequests.last)
        #expect(request.origin == .stop(id: "de-DELFI_de:05315:11201"))
        #expect(request.destination == .coordinate(FakeLocation.fix.coordinate))
    }

    @Test func swapWithoutLocationIsDisabledAndKeepsDestination() {
        let none = flow(location: Self.noLocation(), onboarding: .withoutLocation)
        none.send(.editEndpoint(.destination))
        none.choose(Self.stopEndpoint)
        #expect(!none.canSwap) // Knopf deaktiviert
        none.swapEndpoints()
        #expect(none.destination == .place(Self.stopEndpoint))
        #expect(none.origin == .currentLocation)
    }

    /// AGENT.md 3.1.2: zurueck zum Start verwirft Verbindungen (enthalten gerundete Start-Koordinaten).
    @Test(arguments: [FlowEvent.reset, FlowEvent.back])
    func returningToStartDiscardsRoutes(_ event: FlowEvent) async {
        let f = flow()
        chooseDestination(f)
        await f.waitForWork()
        #expect(f.routes != nil && f.overlay != nil)
        f.send(event)
        #expect(f.phase == .start)
        #expect(f.routes == nil)
        #expect(f.calibrated == nil)
        #expect(f.overlay == nil)
        #expect(!f.isStale)
    }

    /// AGENT.md 3.1.2: keine Koordinate behalten; Status aus iOS bei Rueckkehr in die App.
    @Test func locationStatusFollowsIOSAndBackgroundDropsFix() async {
        let location = FakeLocation()
        let f = flow(location: location)
        f.becameActive()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(f.lastAccuracy == 8)
        f.movedToBackground()
        #expect(f.lastAccuracy == nil)
        location.set(.denied)
        f.becameActive()
        #expect(!f.locationAllowed)
        #expect(f.actions(for: .locationDenied) == [.openSettings, .switchToStops])
    }
}

/// AGENT.md 4.1.2: Linien-Badges AAA (7:1) in Hell, Dunkel und Hoher Kontrast; Hinweise mindestens 4,5:1 (HC 7:1).
/// Rechnet aus den echten Asset-Werten (WCAG 2.x, relative Luminanz).
@MainActor @Suite struct ColorContrastTests {
    static let modes = ["modeTram", "modeSbahn", "modeUbahn", "modeBus", "modeRegio"]

    static func traits(dark: Bool, high: Bool) -> UITraitCollection {
        UITraitCollection { t in
            t.userInterfaceStyle = dark ? .dark : .light
            t.accessibilityContrast = high ? .high : .normal
        }
    }

    static func luminance(_ name: String, _ traits: UITraitCollection) -> Double? {
        guard let color = UIColor(named: name, in: .main, compatibleWith: traits)?.resolvedColor(with: traits) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func lin(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    static func ratio(_ a: String, _ b: String, _ traits: UITraitCollection) -> Double {
        guard let la = luminance(a, traits), let lb = luminance(b, traits) else { return 0 }
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func badgeTextIsAAA(dark: Bool, high: Bool) {
        let t = Self.traits(dark: dark, high: high)
        for mode in Self.modes {
            let r = Self.ratio(mode, "labelOnAccent", t)
            #expect(r >= (high ? 9 : 7), "\(mode) dark=\(dark) high=\(high): \(r)")
        }
    }

    /// Hinweise, Verspaetung und "Pünktlich": mindestens 4,5:1, bei Hohem Kontrast mindestens 7:1.
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func hintsAndStatusTextContrast(dark: Bool, high: Bool) {
        let t = Self.traits(dark: dark, high: high)
        let pairs = [("statusWarn", "statusWarnTint"), ("statusAlert", "statusAlertTint"),
                     ("accentBlue", "accentBlueTint"), ("statusOk", "surfaceCard"),
                     // Hauptknopf: Knopftext auf Knopfflaeche
                     ("buttonLabel", "buttonFill"),
                     // Quellen-Fusszeile (Transitous-Regel: klar lesbar), Annahme surface/sheet
                     ("labelSecondary", "surfaceSheet"), ("accentBlue", "surfaceSheet")]
        for (fg, bg) in pairs {
            let r = Self.ratio(fg, bg, t)
            #expect(r >= (high ? 7 : 4.5), "\(fg) auf \(bg) dark=\(dark) high=\(high): \(r)")
        }
    }
}

@Suite struct SpokenTextTests {
    @Test func pluralFromStringCatalog() {
        #expect(String(localized: "\(1) Umstiege") == "1 Umstieg")
        #expect(String(localized: "\(2) Umstiege") == "2 Umstiege")
        #expect(String(localized: "\(1) Zwischenhalte") == "1 Zwischenhalt")
    }

    @Test func heroSentenceNamesLinesDelayPlatformAndSEV() throws {
        let journey = try #require(FakeData.routes?.journeys.first)
        let departure = try #require(journey.departure)
        let text = Spoken.hero(journey, calibrated: nil, now: departure.addingTimeInterval(-7 * 60))
        #expect(text.hasPrefix("Beste Verbindung: In 7 Minuten losgehen."))
        #expect(text.contains("5 Minuten Fußweg, dann Straßenbahn STR 704 Richtung Derendorf, 2 Minuten verspätet"))
        #expect(text.contains("Ersatzverkehr Bus SEV RE 5"))
        #expect(text.contains("Gleis 2."))
        #expect(text.contains("1 Umstieg."))
        #expect(text.contains("Achtung, Ersatzverkehr: Bus SEV RE 5 bis Köln Hbf, Abfahrt Bilk S Bus."))
    }

    @Test func directJourneySaysDirect() throws {
        let journey = try #require(FakeData.routes?.journeys.last)
        #expect(journey.transfers == 0)
        let text = Spoken.journey(journey, calibrated: nil, now: Date.distantPast)
        #expect(text.contains("Direkt."))
        #expect(!text.contains("0 Umstiege"))
    }

    /// "SEV" nie doppelt: Linienname "SEV RE 5" bleibt so, "RE 5" als Ersatz wird "SEV RE 5".
    @Test func sevPrefixIsNotDoubled() throws {
        let sev = try #require(FakeData.routes?.journeys.first?.legs[3])
        #expect(sev.replacement && sev.badgeText == "SEV RE 5")
        func leg(_ name: String, replacement: Bool) throws -> Leg {
            let json = #"{"index":0,"mode":"bus","origin":{"kind":"stop"},"destination":{"kind":"stop"},"realtime":false,"cancelled":false,"line":{"name":"\#(name)"},"replacement":\#(replacement)}"#
            return try TransitJSON.decoder().decode(Leg.self, from: Data(json.utf8))
        }
        #expect(try leg("RE 5", replacement: true).badgeText == "SEV RE 5")
        #expect(try leg("sev 12", replacement: true).badgeText == "sev 12")
        #expect(try leg("RE 5", replacement: false).badgeText == "RE 5")
    }

    @Test func stationAndStepSentences() throws {
        let steps = try #require(FakeData.routes?.journeys.first?.legs[2].steps)
        #expect(Spoken.step(steps[0]) == "Treppe, nach unten, Ebene 1 zu 0, 20 Meter.")
        let station = Spoken.station(time: nil, name: "Köln Hbf", platform: "7", plannedPlatform: "10",
                                     delayMinutes: 3, leg: nil)
        #expect(station == "Köln Hbf, Gleis 7 statt 10, 3 Minuten später.")
    }
}
#endif
