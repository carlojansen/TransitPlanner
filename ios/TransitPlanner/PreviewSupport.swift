#if DEBUG
import SwiftUI
import TransitCore

// Vorschau-Fundament: Mock-Daten und ein PreviewModifier, der `AppFlow` mit den vorhandenen Fakes
// (Dependencies.swift) in einen Zustand faehrt. Kein Netz, kein CoreLocation.

/// Mock-Antworten relativ zur aktuellen Uhrzeit, damit Countdowns sinnvolle Werte zeigen.
/// Modelle haben keinen oeffentlichen Init; daher JSON wie in `FakeData`.
enum PreviewData {
    /// Volle Minute beim ersten Zugriff; alle Zeiten der Mock-Daten zaehlen ab hier.
    static let base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)

    /// Kurze Verbindung: Fussweg, U 79 ohne Umstieg, Fussweg.
    static let short: RoutesResponse? = response([journey(token: "cHJldmlldy1zaG9ydA==", dep: 6, arr: 19, transfers: 0, modes: ["subway"], legs: [
        walk(0, coordinate(51.2201, 6.7905), stop("dus-u", "Düsseldorf Hbf (U)", 51.2203, 6.7930), 6, 9, meters: 190, transfer: false,
             steps: #"[{"direction":"depart","distanceMeters":150,"streetName":"Graf-Adolf-Straße"},{"direction":"stairs","distanceMeters":40,"fromLevel":0,"toLevel":-1}]"#),
        ride(1, "subway", line: "U 79", direction: "Duisburg Meiderich Süd Bf", stop("dus-u", "Düsseldorf Hbf (U)", 51.2203, 6.7930),
             stop("hha", "Heinrich-Heine-Allee", 51.2250, 6.7745), 10, 16, platforms: ("2", "1"),
             stopovers: [("Oststraße", 51.2235, 6.7850, 12), ("Steinstraße/Königsallee", 51.2210, 6.7790, 14)]),
        walk(2, stop("hha", "Heinrich-Heine-Allee", 51.2250, 6.7745), coordinate(51.2262, 6.7731), 16, 19, meters: 220, transfer: false),
    ])])

    /// Sehr lange Route: vier Fahrzeuge, drei Umstiege (Treppe, Aufzug), viele Zwischenhalte.
    static let long: RoutesResponse? = response([journey(token: "cHJldmlldy1sb25n", dep: 4, arr: 125, transfers: 3,
                                                        modes: ["regional", "subway", "bus"], legs: [
        walk(0, coordinate(50.7330, 7.0950), stop("bn", "Bonn Hbf", 50.7320, 7.0970), 4, 12, meters: 600, transfer: false,
             steps: #"[{"direction":"depart","distanceMeters":250,"streetName":"Poststraße"},{"direction":"left","distanceMeters":320,"streetName":"Maximilianstraße"},{"direction":"right","distanceMeters":30}]"#),
        ride(1, "regional", line: "RB 48", direction: "Wuppertal-Oberbarmen", stop("bn", "Bonn Hbf", 50.7320, 7.0970),
             stop("k4", "Köln Hbf", 50.9430, 6.9589), 12, 42, platforms: ("1", "4"),
             stopovers: [("Roisdorf", 50.7510, 7.0400, 17), ("Sechtem", 50.7850, 6.9820, 21), ("Brühl", 50.8300, 6.9040, 26),
                         ("Hürth-Kalscheuren", 50.8740, 6.9130, 31), ("Köln Süd", 50.9270, 6.9380, 36), ("Köln West", 50.9410, 6.9350, 39)]),
        walk(2, stop("k4", "Köln Hbf", 50.9430, 6.9589), stop("k11", "Köln Hbf", 50.9432, 6.9592), 42, 48, meters: 250, transfer: true,
             steps: #"[{"direction":"stairs","distanceMeters":30,"fromLevel":1,"toLevel":0},{"direction":"continue","distanceMeters":180},{"direction":"stairs","distanceMeters":40,"fromLevel":0,"toLevel":1}]"#),
        ride(3, "regional", line: "RE 1", direction: "Hamm (Westf) Hbf", stop("k11", "Köln Hbf", 50.9432, 6.9592),
             stop("dus", "Düsseldorf Hbf", 51.21996, 6.79432), 50, 78, platforms: ("11", "16"),
             stopovers: [("Köln Messe/Deutz", 50.9409, 6.9750, 53), ("Köln-Mülheim", 50.9580, 7.0080, 57),
                         ("Leverkusen Mitte", 51.0310, 6.9880, 64), ("Düsseldorf-Benrath", 51.1630, 6.8730, 71)]),
        walk(4, stop("dus", "Düsseldorf Hbf", 51.21996, 6.79432), stop("dus-u", "Düsseldorf Hbf (U)", 51.2203, 6.7930), 78, 84,
             meters: 300, transfer: true, steps: #"[{"direction":"continue","distanceMeters":260},{"direction":"elevator","fromLevel":1,"toLevel":-2}]"#),
        ride(5, "subway", line: "U 79", direction: "Duisburg Meiderich Süd Bf", stop("dus-u", "Düsseldorf Hbf (U)", 51.2203, 6.7930),
             stop("nordpark", "Nordpark/Aquazoo", 51.2600, 6.7680), 86, 101, platforms: ("2", "1"),
             stopovers: [("Oststraße", 51.2235, 6.7850, 88), ("Steinstraße/Königsallee", 51.2210, 6.7790, 90),
                         ("Heinrich-Heine-Allee", 51.2250, 6.7745, 92), ("Tonhalle/Ehrenhof", 51.2320, 6.7720, 94),
                         ("Victoriaplatz/Klever Straße", 51.2385, 6.7735, 96), ("Golzheimer Platz", 51.2490, 6.7740, 98)]),
        walk(6, stop("nordpark", "Nordpark/Aquazoo", 51.2600, 6.7680), stop("nordpark-bus", "Nordpark/Aquazoo", 51.2604, 6.7672),
             101, 104, meters: 120, transfer: true),
        ride(7, "bus", line: "896", direction: "Flughafen Terminal", stop("nordpark-bus", "Nordpark/Aquazoo", 51.2604, 6.7672),
             stop("dus-air", "Flughafen Terminal", 51.2789, 6.7660), 108, 120, platforms: nil,
             stopovers: [("Stockum Kirche", 51.2660, 6.7550, 112), ("Messe Ost/Stockumer Kirchstraße", 51.2620, 6.7450, 116)]),
        walk(8, stop("dus-air", "Flughafen Terminal", 51.2789, 6.7660), coordinate(51.2795, 6.7672), 120, 125, meters: 150, transfer: false),
    ])])

    /// Stoerung: Verspaetung, Gleiswechsel, Meldung des Betreibers, Ersatzverkehr; dazu eine Alternative (FakeData.routes).
    static let disrupted = shifted(FakeData.routes, departingIn: 5)

    /// Anschluss reicht nicht: ICE 47 rund 7 Min. verspaetet, Umstieg in Koeln Messe/Deutz zu kurz (FakeData.deutz).
    static let tight = shifted(FakeData.deutz(iceDelay: 400), departingIn: 3)

    static var attribution: Attribution? { FakeData.routes?.attribution }

    /// Favoriten (Zuhause, Uni) und Verlauf fuer Start und Planen.
    @MainActor static func places() -> MemoryPlaces {
        let places = MemoryPlaces(recents: [.stop(id: "de-DELFI_de:05315:11201", label: "Köln Hbf"),
                                            .stop(id: "hha", label: "Heinrich-Heine-Allee")])
        places.addFavorite(.coordinate(GeoCoordinate(latitude: 51.2262, longitude: 6.7731), label: "Altstadt"), role: .home)
        places.addFavorite(.coordinate(GeoCoordinate(latitude: 50.9258, longitude: 6.9218), label: "Weyertal 119a"), role: .uni)
        return places
    }

    /// Ziel der Planung: letzter Halt der ersten Verbindung.
    static func destination(_ response: RoutesResponse?) -> TripEndpoint {
        let place = response?.journeys.first?.legs.last(where: { !$0.isWalk })?.destination
        return .stop(id: place?.id ?? "de-DELFI_de:05315:11201", label: place?.name ?? "Köln Hbf")
    }

    // MARK: JSON-Bausteine

    private static func t(_ minutes: Int) -> String {
        Date.ISO8601FormatStyle().format(base.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    private static func stop(_ id: String, _ name: String, _ lat: Double, _ lon: Double) -> String {
        #"{"kind":"stop","id":"\#(id)","name":"\#(name)","latitude":\#(lat),"longitude":\#(lon)}"#
    }

    private static func coordinate(_ lat: Double, _ lon: Double) -> String {
        #"{"kind":"coordinate","latitude":\#(lat),"longitude":\#(lon)}"#
    }

    private static func walk(_ index: Int, _ origin: String, _ destination: String, _ start: Int, _ end: Int,
                             meters: Int, transfer: Bool, steps: String = "[]") -> String {
        #"""
        {"index":\#(index),"mode":"walk","origin":\#(origin),"destination":\#(destination),"departure":"\#(t(start))",
         "arrival":"\#(t(end))","durationSeconds":\#((end - start) * 60),"realtime":false,"cancelled":false,
         "isTransfer":\#(transfer),"distanceMeters":\#(meters),"durationSource":"motis-osm","steps":\#(steps)}
        """#
    }

    private static func ride(_ index: Int, _ mode: String, line: String, direction: String, _ origin: String, _ destination: String,
                             _ start: Int, _ end: Int, platforms: (String, String)?,
                             stopovers: [(name: String, lat: Double, lon: Double, minute: Int)]) -> String {
        let halts = stopovers.enumerated().map { i, s in
            #"{"stop":\#(stop("\(index)-\(i)", s.name, s.lat, s.lon)),"arrival":"\#(t(s.minute))","departure":"\#(t(s.minute))","cancelled":false}"#
        }.joined(separator: ",")
        let platformFields = platforms.map {
            #""departurePlatform":"\#($0.0)","plannedDeparturePlatform":"\#($0.0)","arrivalPlatform":"\#($0.1)","plannedArrivalPlatform":"\#($0.1)","platformChanged":false,"#
        } ?? ""
        return #"""
        {"index":\#(index),"mode":"\#(mode)","origin":\#(origin),"destination":\#(destination),
         "departure":"\#(t(start))","plannedDeparture":"\#(t(start))","departureDelaySeconds":0,
         "arrival":"\#(t(end))","plannedArrival":"\#(t(end))","arrivalDelaySeconds":0,"durationSeconds":\#((end - start) * 60),
         "realtime":true,"cancelled":false,"line":{"name":"\#(line)"},"direction":"\#(direction)",\#(platformFields)
         "replacement":false,"stopovers":[\#(halts)]}
        """#
    }

    private static func journey(token: String, dep: Int, arr: Int, transfers: Int, modes: [String], legs: [String]) -> String {
        #"""
        {"refreshToken":"\#(token)","departure":"\#(t(dep))","arrival":"\#(t(arr))","durationSeconds":\#((arr - dep) * 60),
         "transfers":\#(transfers),"modes":[\#(modes.map { "\"\($0)\"" }.joined(separator: ","))],"cancelled":false,
         "realtime":true,"hasPolylines":false,"legs":[\#(legs.joined(separator: ","))],"remarks":[]}
        """#
    }

    private static func response(_ journeys: [String]) -> RoutesResponse? {
        let json = #"""
        {"journeys":[\#(journeys.joined(separator: ","))],"earlierRef":null,"laterRef":"later","walkOnly":false,
         "removedLongDistance":0,"fetchedAt":"\#(t(0))","attribution":\#(FakeData.attributionJSON)}
        """#
        return try? TransitJSON.decoder().decode(RoutesResponse.self, from: Data(json.utf8))
    }

    /// Verschiebt alle Zeiten einer festen Fake-Antwort, sodass die erste Verbindung in `minutes` Minuten beginnt.
    static func shifted(_ response: RoutesResponse?, departingIn minutes: Int) -> RoutesResponse? {
        guard let response, let first = response.journeys.first?.departure else { return nil }
        let offset = base.addingTimeInterval(TimeInterval(minutes * 60)).timeIntervalSince(first)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.addingTimeInterval(offset).timeIntervalSinceReferenceDate)
        }
        guard let data = try? encoder.encode(response) else { return nil }
        return try? JSONDecoder().decode(RoutesResponse.self, from: data)
    }
}

/// Faehrt `AppFlow` mit Fakes in einen Zustand und legt ihn in die Umgebung.
/// Beispiel: `#Preview(traits: .modifier(PreviewFlow.routes(PreviewData.short))) { RouteSheet() }`
struct PreviewFlow: PreviewModifier {
    enum Stage: Equatable {
        case onboarding, start, plan(query: String), routes, details(Int), navigation(Int), alternatives(Int)
    }

    var stage: Stage
    var response: RoutesResponse? = PreviewData.disrupted
    var failure: TransitError?
    /// Planung antwortet nie (3a Laden).
    var loading = false
    var location: LocationAuthorization = .allowed
    var savedPlaces = true
    /// Navigation: App-Uhr so viele Minuten nach jetzt (Mock-Daten beginnen bei `PreviewData.base`).
    var clockMinutes: Int?
    /// Navigation: fester Standort (z. B. am Ziel fuer 4f Ankunft).
    var position: GeoCoordinate?

    func body(content: Content, context: Void) -> some View {
        PreviewFlowHost(setup: self) { content }
    }

    @MainActor func dependencies() -> AppDependencies {
        let planner = loading ? FakeRoutePlanner(delay: .seconds(3600)) : FakeRoutePlanner(failure: failure, response: response)
        let choice: OnboardingChoice? = stage == .onboarding ? nil : (location == .allowed ? .withLocation : .withoutLocation)
        var deps = AppDependencies.fakes(planner: planner, secrets: InMemorySecretStore(token: String(repeating: "k", count: 40)),
                                         location: FakeLocation(status: location), onboarding: choice,
                                         places: savedPlaces ? PreviewData.places() : MemoryPlaces())
        let journeys = response?.journeys ?? []
        deps.refresh = { token throws(TransitError) in
            guard let journey = journeys.first(where: { $0.refreshToken == token }) else { throw .refreshExpired }
            return journey
        }
        if let clockMinutes {
            let offset = PreviewData.base.addingTimeInterval(TimeInterval(clockMinutes * 60)).timeIntervalSinceNow
            deps.now = { Date().addingTimeInterval(offset) }
        }
        if let position {
            let fix = LocationFix(coordinate: position, horizontalAccuracy: 5, timestamp: Date())
            deps.positions = { AsyncStream { $0.yield(fix) } }
        }
        return deps
    }

    @MainActor func drive(_ flow: AppFlow) async {
        switch stage {
        case .onboarding:
            return
        case .start:
            flow.loadSuggestions()
            await flow.waitForNearby()
        case .plan(let query):
            flow.send(.editEndpoint(.destination))
            guard !query.isEmpty else { return }
            flow.query = query
            flow.submitSearch()
            await flow.waitForWork()
        case .routes, .details, .navigation, .alternatives:
            flow.choose(PreviewData.destination(response))
            guard !loading else { return }
            await flow.waitForWork()
            switch stage {
            case .details(let i): flow.send(.journeySelected(i))
            case .navigation(let i): flow.send(.startNavigation(i))
            case .alternatives(let i):
                flow.send(.startNavigation(i))
                flow.openAlternatives(from: .nextStation)
            default: break
            }
        }
    }

    // MARK: Voreinstellungen

    static var onboarding: PreviewFlow { PreviewFlow(stage: .onboarding, location: .notDetermined) }
    static var start: PreviewFlow { PreviewFlow(stage: .start) }
    /// Leere Liste: keine Favoriten, kein Verlauf.
    static var startEmpty: PreviewFlow { PreviewFlow(stage: .start, savedPlaces: false) }
    static var startNoLocation: PreviewFlow { PreviewFlow(stage: .start, location: .denied) }
    static func plan(query: String = "") -> PreviewFlow { PreviewFlow(stage: .plan(query: query)) }
    static var loading: PreviewFlow { PreviewFlow(stage: .routes, loading: true) }
    static func routes(_ response: RoutesResponse?) -> PreviewFlow { PreviewFlow(stage: .routes, response: response) }
    /// Leere Ergebnisliste (H2).
    static var noConnections: PreviewFlow { PreviewFlow(stage: .routes, failure: .noConnections) }
    static func failure(_ error: TransitError) -> PreviewFlow { PreviewFlow(stage: .routes, failure: error) }
    static func details(_ response: RoutesResponse?, index: Int = 0) -> PreviewFlow {
        PreviewFlow(stage: .details(index), response: response)
    }
    static func navigation(_ response: RoutesResponse?, atMinute minute: Int, position: GeoCoordinate? = nil) -> PreviewFlow {
        PreviewFlow(stage: .navigation(0), response: response, clockMinutes: minute, position: position)
    }
    static var alternatives: PreviewFlow {
        PreviewFlow(stage: .alternatives(0), response: PreviewData.long, clockMinutes: 20)
    }
    /// 4f Ankunft: nach der Ankunft am Ziel stehen.
    static var arrival: PreviewFlow {
        let target = PreviewData.short?.journeys.first?.legs.last?.destination.coordinate
        return PreviewFlow(stage: .navigation(0), response: PreviewData.short, clockMinutes: 20, position: target)
    }
}

/// Haelt den Flow ueber die Lebensdauer der Vorschau und faehrt ihn einmal in den Zielzustand.
private struct PreviewFlowHost<Content: View>: View {
    let setup: PreviewFlow
    @ViewBuilder let content: Content
    @State private var flow: AppFlow

    init(setup: PreviewFlow, @ViewBuilder content: () -> Content) {
        self.setup = setup
        self.content = content()
        _flow = State(initialValue: AppFlow(setup.dependencies()))
    }

    var body: some View {
        content
            .environment(flow)
            .task { await setup.drive(flow) }
    }
}

/// Sheet-Inhalt wie in der App: ueber einer Kartenflaeche, im System-Sheet mit Liquid Glass.
struct PreviewSheetBackdrop<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Color(.fillTertiary)
            .ignoresSafeArea()
            .sheet(isPresented: .constant(true)) {
                content.interactiveDismissDisabled()
            }
    }
}
#endif
