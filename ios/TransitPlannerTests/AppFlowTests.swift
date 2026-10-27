// Nur Debug: braucht `@testable import` und die Fakes. Im Release-Gate (Release) laeuft nur die Pinning-Sperre.
#if DEBUG
import Foundation
import Testing
import SwiftData
import Synchronization
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
        Row(from: .start, event: .editEndpoint(.destination), to: .plan(.destination)),
        Row(from: .start, event: .editEndpoint(.origin), to: .plan(.origin)),
        Row(from: .start, event: .planTapped, to: nil),
        Row(from: .start, event: .back, to: nil),
        Row(from: .start, event: .reset, to: nil),
        Row(from: .start, event: .journeySelected(0), to: nil),
        Row(from: .start, event: .startNavigation(0), to: nil),
        // Start (B1, 27.10.): Favorit, Verlauf oder Naehe sucht sofort
        Row(from: .start, event: .endpointChosen, to: .routeSelection),
        // Nur waehrend der Rate-Limit-Sperre: Tipp im Start zeigt Planen mit Restzeit
        Row(from: .start, event: .editOptions, to: .plan(nil)),
        Row(from: .plan(.destination), event: .endpointChosen, to: .routeSelection),
        Row(from: .plan(.destination), event: .planTapped, to: .routeSelection),
        Row(from: .plan(.destination), event: .back, to: .start),
        Row(from: .plan(nil), event: .back, to: .start),
        Row(from: .plan(.origin), event: .editEndpoint(.destination), to: .plan(.destination)),
        Row(from: .plan(nil), event: .editEndpoint(.origin), to: .plan(.origin)),
        Row(from: .plan(.origin), event: .journeySelected(0), to: nil),
        Row(from: .plan(.origin), event: .reset, to: .start),
        // Eine Richtung zurueck: Details > Ergebnisse > Planen > Karte
        Row(from: .routeSelection, event: .editOptions, to: .plan(nil)),
        Row(from: .routeSelection, event: .back, to: .plan(nil)),
        Row(from: .routeSelection, event: .journeySelected(2), to: .tripDetails(2)),
        Row(from: .routeSelection, event: .planTapped, to: .routeSelection),
        Row(from: .routeSelection, event: .startNavigation(0), to: .navigation(0)),
        Row(from: .routeSelection, event: .editEndpoint(.destination), to: nil),
        Row(from: .tripDetails(1), event: .startNavigation(1), to: .navigation(1)),
        Row(from: .tripDetails(1), event: .back, to: .routeSelection),
        Row(from: .tripDetails(1), event: .journeySelected(0), to: nil),
        Row(from: .navigation(1), event: .arrived, to: .arrival),
        Row(from: .navigation(1), event: .back, to: .routeSelection),
        Row(from: .navigation(1), event: .reset, to: .start),
        Row(from: .arrival, event: .back, to: .start),
        Row(from: .arrival, event: .reset, to: .start),
        Row(from: .arrival, event: .arrived, to: nil),
    ]

    @Test(arguments: table)
    func transition(_ row: Row) {
        #expect(AppFlow.next(row.from, row.event) == row.to)
    }

    @Test func workContextKeepsPlanningAcrossDetails() {
        #expect(Phase.routeSelection.workContext == Phase.tripDetails(0).workContext)
        #expect(Phase.plan(.origin).workContext != Phase.routeSelection.workContext)
        #expect(Phase.navigation(0).workContext != Phase.routeSelection.workContext)
    }

    @Test func focusChangeKeepsTheSameView() {
        #expect(Phase.plan(.origin).viewID == Phase.plan(.destination).viewID)
        #expect(Phase.routeSelection.viewID == .routeSelection)
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
        #expect(TransitError.locationDenied.bannerActions == [.openSettings, .chooseOrigin])
        #expect(TransitError.notFound.bannerActions == [.newSearch])
        #expect(TransitError.rateLimited.bannerActions.isEmpty) // Restzeit statt Neuversuch
        #expect(TransitError.pinningFailed.bannerActions.isEmpty) // keine Umgehung
    }

    @Test func toneByError() {
        #expect(InlineBanner.tone(for: .pinningFailed) == .alert)
        #expect(InlineBanner.tone(for: .offline) == .warn)
        #expect(InlineBanner.tone(for: .missingToken) == .info)
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

    @Test func startsWithLocalSearchOnly() {
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
        for text in ["K", "Kö", "Köl", "Köln"] {
            f.query = text
            f.queryChanged()
        }
        await f.waitForWork()
        #expect(search.recorded == [.init(text: "Köln", scope: .address)])
        #expect(f.results.addresses.count == 1)
        #expect(f.results.stops.isEmpty)
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

    /// Zero-Knowledge: Tippen sucht nur auf dem Geraet. Erst der Tipp auf die Server-Zeile sendet den Text,
    /// und jede weitere Eingabe nimmt den Server-Stand zurueck.
    @Test func typingNeverSendsTextToTheServer() async {
        let search = FakeStopSearch()
        let f = flow(search: search)
        f.send(.editEndpoint(.destination))
        f.query = "Musterstraße 5"
        f.queryChanged()
        f.submitSearch()
        await f.waitForWork()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(search.recorded.allSatisfy { $0.scope == .address })

        f.searchOnServer()
        await f.waitForWork()
        #expect(search.recorded.last == .init(text: "Musterstraße 5", scope: .stops))
        #expect(f.scope == .stops)
        #expect(f.results.stops.count == 2)
        #expect(f.attribution != nil)

        f.query = "Musterstraße 55"
        f.queryChanged()
        #expect(f.scope == .address) // geaenderter Text bleibt wieder auf dem Geraet
        await f.waitForWork()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(search.recorded.filter { $0.scope == .stops }.count == 1)
    }

    @Test func serverSearchNeedsTwoCharacters() async {
        let search = FakeStopSearch()
        let f = flow(search: search)
        f.send(.editEndpoint(.destination))
        f.query = "K"
        f.searchOnServer()
        await f.waitForWork()
        #expect(search.recorded.isEmpty)
        #expect(f.scope == .address)
    }

    /// Ohne Standort bleibt die Suche nutzbar: keine Adresssuche, kein Banner, aber Haltestellen per Server-Zeile.
    @Test func withoutLocationSearchStaysUsable() async {
        let search = FakeStopSearch()
        let f = flow(search: search, location: Self.noLocation(), onboarding: .withoutLocation)
        f.send(.editEndpoint(.destination))
        f.query = "Musterstraße"
        f.submitSearch()
        await f.waitForWork()
        #expect(search.recorded.isEmpty) // ohne GPS-Region keine Adresssuche
        #expect(f.banner == nil)
        #expect(f.scope == .address)
        f.searchOnServer()
        await f.waitForWork()
        #expect(search.recorded == [.init(text: "Musterstraße", scope: .stops)])
        #expect(f.results.stops.count == 2)
    }

    /// Ein Standortfehler der Adresssuche zeigt kein Banner.
    @Test func addressSearchLocationErrorIsSilent() async {
        let search = FakeStopSearch(failure: .locationUnavailable)
        let f = flow(search: search)
        f.send(.editEndpoint(.destination))
        f.query = "Musterstraße 5"
        f.submitSearch()
        await f.waitForWork()
        #expect(f.banner == nil)
        #expect(f.results.addresses.isEmpty)
    }

    // MARK: Vorschlaege, Favoriten, Verlauf

    @Test func planShowsFavoritesRecentsAndNearbyStops() async {
        let places = MemoryPlaces(favorites: [Self.stopEndpoint], recents: [Self.addressEndpoint, Self.stopEndpoint])
        let f = AppFlow(.fakes(onboarding: .withLocation, places: places))
        f.send(.editEndpoint(.destination))
        #expect(f.favorites.map(\.endpoint) == [Self.stopEndpoint])
        #expect(f.recents.map(\.endpoint) == [Self.addressEndpoint]) // Favorit nicht doppelt
        await f.waitForNearby()
        #expect(f.nearby.count == 2)
        f.movedToBackground()
        #expect(f.nearby.isEmpty) // nichts Standortbezogenes behalten
    }

    @Test func nearbyStopsNeedLocationPermission() async {
        let f = flow(location: Self.noLocation(), onboarding: .withoutLocation)
        f.send(.editEndpoint(.destination))
        await f.waitForNearby()
        #expect(f.nearby.isEmpty)
    }

    @Test func choosingRemembersPlaceButNeverCurrentLocation() {
        let places = MemoryPlaces()
        let f = AppFlow(.fakes(onboarding: .withLocation, places: places))
        f.send(.editEndpoint(.origin))
        f.useCurrentLocation()
        #expect(places.recents().isEmpty)
        f.send(.back)
        f.send(.editEndpoint(.destination))
        f.choose(Self.stopEndpoint)
        #expect(places.recents().map(\.endpoint) == [Self.stopEndpoint])
    }

    @Test func favoritesCanBeAddedAndRemoved() {
        let places = MemoryPlaces(recents: [Self.stopEndpoint])
        let f = AppFlow(.fakes(onboarding: .withLocation, places: places))
        f.send(.editEndpoint(.destination))
        #expect(f.recents.count == 1)
        f.addFavorite(Self.stopEndpoint)
        #expect(f.favorites.map(\.endpoint) == [Self.stopEndpoint])
        #expect(f.recents.isEmpty)
        if let id = f.favorites.first?.id { f.removeFavorite(id) }
        #expect(f.favorites.isEmpty)
        f.clearRecents()
        #expect(f.recents.isEmpty)
    }

    // MARK: Start (DESIGN.md B1, Ueberarbeitung 27.10.)

    /// Tipp auf Favorit/Verlauf im Start: wie die Wahl eines Orts in Planen, aber immer ab "Mein Standort" und jetzt.
    @Test func startTileSearchesFromCurrentLocationNow() async throws {
        let places = MemoryPlaces()
        places.addFavorite(Self.stopEndpoint, role: .home)
        let planner = FakeRoutePlanner()
        let f = AppFlow(.fakes(planner: planner, onboarding: .withLocation, places: places))
        // Vorige Suche mit anderem Start und eigener Zeit
        f.send(.editEndpoint(.origin))
        f.choose(Self.addressEndpoint)
        f.customTime = Date().addingTimeInterval(3600)
        f.isArrivalTime = true
        f.send(.reset)
        f.loadSuggestions()
        #expect(f.favorites.first?.role == .home)

        f.choose(Self.stopEndpoint)
        #expect(f.phase == .routeSelection)
        #expect(f.origin == .currentLocation)
        #expect(f.customTime == nil && !f.isArrivalTime)
        await f.waitForWork()
        let request = try #require(planner.recordedRequests.last)
        #expect(request.origin == .coordinate(FakeLocation.fix.coordinate))
        #expect(request.destination == .stop(id: "de-DELFI_de:05315:11201"))
    }

    @Test func startTileWithoutLocationAsksForOrigin() {
        let planner = FakeRoutePlanner()
        let f = flow(planner: planner, location: Self.noLocation(), onboarding: .withoutLocation)
        f.choose(Self.stopEndpoint)
        #expect(f.phase == .plan(.origin))
        #expect(planner.callCount == 0)
    }

    /// Leere Kachel: Planen oeffnet, die Wahl wird der Favorit; keine Suche, kein Verlauf, nie "Mein Standort".
    @Test func emptyTileAssignsFavoriteWithoutSearching() {
        let places = MemoryPlaces()
        let planner = FakeRoutePlanner()
        let f = AppFlow(.fakes(planner: planner, onboarding: .withLocation, places: places))
        f.assignFavorite(.uni)
        #expect(f.phase == .plan(.destination))
        #expect(f.assigningRole == .uni)
        f.useCurrentLocation()
        #expect(f.phase == .plan(.destination)) // ignoriert
        f.choose(Self.stopEndpoint)
        #expect(f.phase == .start)
        #expect(f.assigningRole == nil)
        #expect(f.favorites.map(\.role) == [.uni])
        #expect(places.recents().isEmpty)
        #expect(planner.callCount == 0)

        // Abbrechen beendet das Festlegen
        f.assignFavorite(.work)
        f.send(.back)
        #expect(f.assigningRole == nil)
        f.send(.editEndpoint(.destination))
        f.choose(Self.addressEndpoint)
        #expect(f.phase == .routeSelection) // normale Wahl sucht wieder
    }

    @Test func oneFavoritePerRoleAndNoDuplicates() {
        let places = MemoryPlaces()
        places.addFavorite(Self.stopEndpoint, role: .home)
        places.addFavorite(Self.addressEndpoint, role: .home)
        #expect(places.favorites().map(\.endpoint) == [Self.addressEndpoint])
        places.addFavorite(Self.addressEndpoint, role: .other) // schon Favorit: bleibt Zuhause
        #expect(places.favorites().map(\.role) == [.home])
        places.addFavorite(Self.addressEndpoint, role: .work) // gleicher Ort, neue Rolle
        #expect(places.favorites().map(\.role) == [.work])
    }

    /// Wie `oneFavoritePerRoleAndNoDuplicates`, aber im echten SwiftData-Speicher (verschluesselt).
    @Test func swiftDataPlacesKeepRolesLimitAndNoPlaintext() throws {
        let container = try TransitStore.makeContainer(inMemory: true)
        let places = SwiftDataPlaces(container: container, sealer: LocalSealer(secrets: InMemorySecretStore()))
        places.addFavorite(Self.stopEndpoint, role: .home)
        places.addFavorite(Self.addressEndpoint, role: .home)
        #expect(places.favorites().map(\.endpoint) == [Self.addressEndpoint])
        places.addFavorite(Self.addressEndpoint, role: .other) // schon Favorit: bleibt Zuhause
        #expect(places.favorites().map(\.role) == [.home])
        places.addFavorite(Self.addressEndpoint, role: .work) // gleicher Ort, neue Rolle
        #expect(places.favorites().map(\.role) == [.work])
        places.addFavorite(Self.stopEndpoint, role: .uni)
        #expect(places.favorites().first { $0.endpoint == Self.stopEndpoint }?.role == .uni)

        // Verlauf: hoechstens 10, der zuletzt gewaehlte vorn, gleiche Wahl nur einmal
        let stops = (0..<12).map { TripEndpoint.stop(id: "stop-\($0)", label: "Halt \($0)") }
        stops.forEach(places.remember)
        places.remember(stops[5])
        #expect(places.recents().map(\.endpoint) == [stops[5], stops[11], stops[10], stops[9], stops[8], stops[7],
                                                       stops[6], stops[4], stops[3], stops[2]])
        let context = container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<RecentSearch>()) == 10)

        // Im Store nur Chiffrat: weder Namen noch IDs im Klartext
        let blobs = try context.fetch(FetchDescriptor<FavoritePlace>()).map(\.sealedEndpoint)
            + context.fetch(FetchDescriptor<RecentSearch>()).map(\.sealedEndpoint)
        for plain in ["Köln Hbf", "Musterstraße", "de-DELFI", "Halt ", "stop-"] {
            let bytes = Data(plain.utf8)
            #expect(blobs.allSatisfy { $0.range(of: bytes) == nil }, "Klartext im Store: \(plain)")
        }
    }

    @Test func nearbyLoadsOncePerStartAndAtMostEveryTwoMinutes() async {
        let calls = Mutex(0)
        let now = Mutex(Date())
        var deps = AppDependencies.fakes(onboarding: .withLocation)
        deps.nearby = { _ throws(TransitError) in
            calls.withLock { $0 += 1 }
            throw .upstreamUnavailable
        }
        deps.now = { now.withLock { $0 } }
        let f = AppFlow(deps)
        f.becameActive() // scenePhase .active beim Start
        f.loadSuggestions() // Start-Ansicht erscheint
        await f.waitForNearby()
        #expect(calls.withLock { $0 } == 1)
        f.loadSuggestions() // Fehler zaehlt auch: keine neue Anfrage
        await f.waitForNearby()
        #expect(calls.withLock { $0 } == 1)
        now.withLock { $0 = $0.addingTimeInterval(121) }
        f.loadSuggestions()
        await f.waitForNearby()
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func startTileDuringRateLimitOpensPlanWithRemainingTime() async {
        let planner = FakeRoutePlanner(failure: .rateLimited)
        let f = flow(planner: planner, blockedUntil: Date().addingTimeInterval(60))
        chooseDestination(f)
        await f.waitForWork()
        f.send(.reset)
        #expect(f.phase == .start)
        f.choose(Self.addressEndpoint)
        #expect(f.phase == .plan(nil))
        #expect(f.destination == .place(Self.addressEndpoint))
        #expect(f.blockedUntil != nil)
        #expect(f.banner == .rateLimited) // Banner zeigt die Restzeit
        #expect(planner.callCount == 1)
    }

    @Test func startLoadsNearbyAndRecentsCanBeRemoved() async {
        let places = MemoryPlaces(recents: [Self.stopEndpoint, Self.addressEndpoint])
        let f = AppFlow(.fakes(onboarding: .withLocation, places: places))
        f.loadSuggestions()
        await f.waitForNearby()
        #expect(f.phase == .start)
        #expect(f.nearby.count == 2)
        #expect(f.recents.count == 2)
        if let id = f.recents.first?.id { f.removeRecent(id) }
        #expect(f.recents.map(\.endpoint) == [Self.addressEndpoint])
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

    @Test func backThroughPlanKeepsResultsWithoutNewRequest() async {
        let planner = FakeRoutePlanner()
        let f = flow(planner: planner)
        chooseDestination(f)
        await f.waitForWork()
        let firstOverlay = f.overlay?.id
        f.send(.journeySelected(1))
        await f.waitForWork()
        #expect(f.overlay?.id != firstOverlay) // Karte zeigt die gewaehlte Verbindung
        f.send(.back)
        #expect(f.phase == .routeSelection)
        f.send(.back)
        #expect(f.phase == .plan(nil)) // Details > Ergebnisse > Planen
        await f.waitForWork()
        #expect(planner.callCount == 1) // Rate-Limit schonen
        #expect(f.calibrated != nil)
        #expect(f.overlay?.id == firstOverlay)
        #expect(f.destination == .place(Self.stopEndpoint)) // Eingaben bleiben
        f.send(.back)
        #expect(f.phase == .start)
    }

    /// Ohne Standort fehlt der Start: Fokus springt auf Von, die Wahl dort startet die Suche.
    @Test func withoutLocationDestinationLeadsToOriginField() async {
        let planner = FakeRoutePlanner()
        let f = flow(planner: planner, location: Self.noLocation(), onboarding: .withoutLocation)
        chooseDestination(f)
        #expect(f.phase == .plan(.origin))
        #expect(planner.callCount == 0)
        f.choose(Self.addressEndpoint)
        #expect(f.phase == .routeSelection)
        await f.waitForWork()
        #expect(planner.recordedRequests.first?.origin == .coordinate(GeoCoordinate(latitude: 51.2201, longitude: 6.7905)))
    }

    @Test func searchLaterShiftsTimeAndPlansAgain() async {
        let planner = FakeRoutePlanner()
        let f = flow(planner: planner)
        chooseDestination(f)
        await f.waitForWork()
        f.searchLater()
        await f.waitForWork()
        #expect(f.customTime != nil)
        #expect(planner.callCount == 2)
        let first = f.customTime
        f.searchLater()
        #expect(f.customTime == first?.addingTimeInterval(1800))
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
        #expect(f.phase == .plan(nil))
        #expect(planner.callCount == 1)
    }

    // MARK: Schluessel und Status

    @Test func missingKeyBannerOpensServerSettingsAndClearsAfterSave() async throws {
        let f = flow(search: FakeStopSearch(failure: .missingToken))
        f.send(.editEndpoint(.origin))
        f.query = "Hbf"
        f.searchOnServer()
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
    @Test(arguments: [true, false])
    func returningToStartDiscardsRoutes(viaReset: Bool) async {
        let f = flow()
        chooseDestination(f)
        await f.waitForWork()
        #expect(f.routes != nil && f.overlay != nil)
        if viaReset {
            f.send(.reset)
        } else {
            f.send(.back)
            #expect(f.phase == .plan(nil))
            #expect(f.routes != nil) // Planen behaelt die Ergebnisse fuer den Weg zurueck
            f.send(.back)
        }
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
        #expect(f.actions(for: .locationDenied) == [.openSettings, .chooseOrigin])
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
        #expect(Spoken.step(steps[0]) == "Treppe runter, Ebene 1 zu 0, 20 Meter.")
        #expect(Spoken.step(Step(direction: .depart, distanceMeters: 637, streetName: "Hüttenstraße")) == "Hüttenstraße folgen, 637 Meter.")
        let station = Spoken.station(time: nil, name: "Köln Hbf", platform: "7", plannedPlatform: "10",
                                     delayMinutes: 3, leg: nil)
        #expect(station == "Köln Hbf, Gleis 7 statt 10, 3 Minuten später.")
    }
}
#endif
