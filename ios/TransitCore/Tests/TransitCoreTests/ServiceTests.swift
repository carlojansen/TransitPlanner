import Foundation
import SwiftData
import Testing
@testable import TransitCore

@Suite struct SearchServiceTests {
    /// Zero-Knowledge-Blocker: im Adressmodus erzeugt kein Text einen Backend-Request, auch ohne erkennbares Adressmuster.
    @Test(arguments: ["Musterstrasse", "Musterstraße 5", "Unter den Linden", "Am Markt", "Baker Street", "Frauenhaus", "Hauptbahnhof"])
    func addressTextNeverReachesBackend(text: String) async throws {
        let transport = FakeTransport(json: Fixture.emptyLocations)
        let local = FakeLocalSearch()
        let service = SearchService(location: FakeLocation(result: .success(FakeLocation.duesseldorf)),
                                    localSearch: local, api: client(transport))
        let r = try await service.search(text, scope: .address)
        #expect(transport.requests.isEmpty)
        #expect(r.addresses.count == 1)
        #expect(local.recorded == [SearchRegion(around: FakeLocation.duesseldorf)])
    }

    @Test func explicitStopModeSendsOnlyToBackend() async throws {
        let transport = FakeTransport(json: Fixture.emptyLocations)
        let local = FakeLocalSearch()
        let service = SearchService(location: FakeLocation(result: .success(FakeLocation.duesseldorf)),
                                    localSearch: local, api: client(transport))
        _ = try await service.search("Graf-Adolf-Platz", scope: .stops)
        #expect(transport.requests.count == 1)
        let items = URLComponents(url: try #require(transport.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.map(\.name) == ["query"])
        #expect(local.recorded.isEmpty)
    }

    @Test func addressWithoutGPSThrowsAndSendsNothing() async {
        let transport = FakeTransport(json: Fixture.emptyLocations)
        let service = SearchService(location: FakeLocation(result: .failure(.locationDenied)),
                                    localSearch: FakeLocalSearch(), api: client(transport))
        await #expect(throws: TransitError.locationDenied) { try await service.search("Musterstraße 5", scope: .address) }
        #expect(transport.requests.isEmpty)
    }

    @Test func stopModeWorksWithoutGPS() async throws {
        let local = FakeLocalSearch()
        let service = SearchService(location: FakeLocation(result: .failure(.locationDenied)),
                                    localSearch: local, api: client(FakeTransport(json: Fixture.emptyLocations)))
        let r = try await service.search("Hbf", scope: .stops)
        #expect(r.addressError == nil)
        #expect(r.stopError == nil)
        #expect(local.recorded.isEmpty)
    }

    @Test func stopModeOfflineThrows() async {
        let service = SearchService(location: FakeLocation(result: .failure(.locationUnavailable)),
                                    localSearch: FakeLocalSearch(),
                                    api: client(FakeTransport([.init(error: URLError(.notConnectedToInternet))])))
        await #expect(throws: TransitError.offline) { try await service.search("Hbf", scope: .stops) }
    }

    @Test func regionIsCenteredOnFix() {
        let region = SearchRegion(around: FakeLocation.duesseldorf, radiusMeters: 10_000).mapRegion
        #expect(region.center.latitude == FakeLocation.duesseldorf.coordinate.latitude)
        #expect(region.center.longitude == FakeLocation.duesseldorf.coordinate.longitude)
        #expect(region.span.latitudeDelta > 0)
    }
}

@Suite struct PersistenceTests {
    @Test func sealedEndpointRoundTripsAndHidesPlaintext() throws {
        let secrets = InMemorySecretStore()
        let sealer = LocalSealer(secrets: secrets)
        let home = TripEndpoint.coordinate(GeoCoordinate(latitude: 51.2201, longitude: 6.7905), label: "Musterstrasse 5")
        let sealed = try sealer.seal(home)
        #expect(!String(decoding: sealed, as: UTF8.self).contains("Musterstrasse"))
        #expect(try sealer.open(TripEndpoint.self, from: sealed) == home)
        // Neuer Sealer mit gleicher Keychain liest dieselben Daten
        #expect(try LocalSealer(secrets: secrets).open(TripEndpoint.self, from: sealed) == home)
        // Anderer Schluessel: nicht lesbar
        #expect(throws: TransitError.decodingFailed) {
            try LocalSealer(secrets: InMemorySecretStore()).open(TripEndpoint.self, from: sealed)
        }
    }

    @Test func corruptKeychainKeyIsNotOverwritten() throws {
        let secrets = InMemorySecretStore()
        try secrets.write(Data(repeating: 9, count: 7), for: .coordinateKey)
        #expect(throws: TransitError.keychainFailure) { try LocalSealer(secrets: secrets).seal("x") }
        #expect(try secrets.read(.coordinateKey) == Data(repeating: 9, count: 7))
    }

    @MainActor @Test func storesModelsInMemory() throws {
        let container = try TransitStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let sealer = LocalSealer(secrets: InMemorySecretStore())
        let trip = ManualTripRequest(origin: .stop(id: "a", label: "Hbf"), destination: .stop(id: "b", label: "Arbeit"),
                                     targetTime: Date.iso("2026-10-24T08:00:00Z"), isArrivalTime: true,
                                     trigger: .calendar(eventIdentifier: "E1"))
        context.insert(try PlannedTrip(request: trip, sealer: sealer))
        context.insert(try FavoritePlace(role: .home, sealedEndpoint: sealer.seal(trip.origin)))
        var profile = WalkingPaceFactor()
        profile.record(predictedSeconds: 600, actualSeconds: 540)
        context.insert(PaceProfile(profile))
        let stop = try Fixture.routes().journeys[0].legs[1].origin
        context.insert(try #require(CachedStop.make(from: stop)))
        #expect(try CachedStop.make(from: Fixture.routes().journeys[0].legs[0].origin) == nil) // Koordinate, keine Haltestelle
        try context.save()

        let stored = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(try stored.request(using: sealer) == trip)
        #expect(try context.fetch(FetchDescriptor<PaceProfile>()).first?.pace.value == profile.value)
        #expect(try context.fetch(FetchDescriptor<CachedStop>()).first?.stopID == "de-DELFI_de:05111:18235")
        #expect(try context.fetch(FetchDescriptor<FavoritePlace>()).first?.role == .home)
    }

    // Der Simulator kennt keinen Dateischutz; der Test greift nur auf einem echten Geraet.
    #if os(iOS) && !targetEnvironment(simulator)
    @MainActor @Test func storeFilesAreFileProtected() throws {
        let container = try TransitStore.makeContainer()
        try ModelContext(container).save()
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appending(path: "TransitStore", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        for file in [dir] + files {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect(attrs[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication, "\(file.lastPathComponent)")
        }
    }
    #endif
}
