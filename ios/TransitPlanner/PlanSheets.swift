import SwiftUI
import TransitCore

// MARK: - 1 Start

/// Start (DESIGN.md B1, Ueberarbeitung 27.10.): Suchfeld und Einstellungen, Favoriten-Kacheln, Zuletzt gesucht
/// (hoechstens 4), Haltestellen in der Naehe mit Gehzeit. Ein Tipp auf ein Ziel sucht sofort ab "Mein Standort", jetzt.
struct StartSheet: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let recentLimit = 4

    /// Bearbeiten: belegte Kacheln zeigen ein Minus, ein Tipp entfernt genau diesen Favoriten (bewusst ohne
    /// Rueckfrage: Favoriten sind in Sekunden neu gesetzt, Familiennutzung).
    @State private var editingFavorites = false

    var body: some View {
        // Kopf ausserhalb der Liste (wie Planen): bleibt bei 140 pt sichtbar, die Liste scrollt darunter.
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { flow.send(.editEndpoint(.destination)) } label: {
                    Label("Wohin?", systemImage: "magnifyingglass")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(Color(.fillTertiary), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("searchEntry")
                SettingsButton()
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 8)
            List {
                if flow.favorites.isEmpty, flow.recents.isEmpty {
                    // Leerzustand statt leerer Flaeche.
                    Section {
                        Button { flow.assignFavorite(.home) } label: {
                            ListRow(symbol: FavoritePlace.Role.home.symbol, tint: Color(.accentBlue),
                                    title: String(localized: "Zuhause festlegen"),
                                    subtitle: String(localized: "Danach bringt dich ein Tipp nach Hause."))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("setHome")
                    }
                } else {
                    Section {
                        tiles
                    } header: {
                        if flow.favorites.contains(where: { $0.role != .other }) { favoritesHeader }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    let others = flow.favorites.filter { $0.role == .other }
                    if !others.isEmpty {
                        Section("Weitere Favoriten") {
                            ForEach(others) { saved in
                                EndpointRow(endpoint: saved.endpoint, symbol: saved.role.symbol)
                                    .swipeActions {
                                        Button("Entfernen", systemImage: "star.slash", role: .destructive) { flow.removeFavorite(saved.id) }
                                    }
                            }
                        }
                    }
                    if !flow.recents.isEmpty {
                        Section("Zuletzt gesucht") {
                            ForEach(flow.recents.prefix(Self.recentLimit)) { RecentRow(saved: $0) }
                        }
                    }
                }
                // Ohne Standort entfaellt der Abschnitt ohne Banner.
                if flow.locationAllowed, !flow.nearby.isEmpty {
                    Section {
                        ForEach(flow.nearby, id: \.id) { NearbyStopRow(stop: $0) }
                    } header: {
                        Text("Haltestellen in der Nähe")
                    } footer: {
                        if let attribution = flow.attribution { AttributionFooter(attribution: attribution) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Beim Erscheinen und bei geaenderter Erlaubnis; die Naehe hoechstens alle 2 Min.
        .task(id: flow.locationAllowed) { flow.loadSuggestions() }
        // Letzter Favorit entfernt: nichts mehr zu bearbeiten.
        .onChange(of: flow.favorites.contains { $0.role != .other }) { if !flow.favorites.contains(where: { $0.role != .other }) { editingFavorites = false } }
    }

    private var favoritesHeader: some View {
        HStack {
            Text("Favoriten")
            Spacer()
            Button(editingFavorites ? "Fertig" : "Bearbeiten") {
                withAnimation(Motion.micro) { editingFavorites.toggle() }
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
            .accessibilityIdentifier("editFavorites")
        }
        .textCase(nil)
    }

    private struct Tile: Identifiable {
        let id: String
        let role: FavoritePlace.Role
        let saved: SavedPlace?
    }

    /// Zuhause, Uni, Arbeit (belegt oder leer) und "+"; weitere Favoriten stehen als Zeilen darunter (Wischen entfernt).
    private var tileModels: [Tile] {
        let fixed = FavoritePlace.Role.tiles.map { role in
            Tile(id: role.rawValue, role: role, saved: flow.favorites.first { $0.role == role })
        }
        return fixed + [Tile(id: "add", role: .other, saved: nil)]
    }

    /// Vier Kacheln in einer Reihe, weitere seitlich scrollbar; bei AX-Groessen untereinander.
    @ViewBuilder private var tiles: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                ForEach(tileModels) { tile($0) }
            }
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(tileModels) { tile($0).containerRelativeFrame(.horizontal, count: 4, spacing: 8) }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func tile(_ tile: Tile) -> some View {
        let isAdd = tile.role == .other && tile.saved == nil
        let title = isAdd ? String(localized: "Hinzufügen") : (tile.role.title ?? tile.saved?.endpoint.label ?? "")
        let subtitle: String? = tile.role == .other ? nil : (tile.saved?.endpoint.label ?? String(localized: "Festlegen"))
        let removing = editingFavorites && tile.saved != nil
        return Button {
            if let saved = tile.saved {
                if editingFavorites { withAnimation(Motion.standard) { flow.removeFavorite(saved.id) } } else { flow.choose(saved.endpoint) }
            } else {
                flow.assignFavorite(tile.role)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isAdd ? "plus" : tile.role.symbol)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color(.accentBlue))
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            // Nur in der Kachelreihe gekuerzt; bei AX-Groessen nie (H4).
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .multilineTextAlignment(.center)
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(Color(.surfaceCard), in: .rect(cornerRadius: 16, style: .continuous))
            .overlay {
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
                }
            }
            .overlay(alignment: .topLeading) {
                if removing {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color(.labelOnAccent), Color(.statusAlert))
                        .font(.title3)
                        .padding(4)
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                }
            }
            .opacity(editingFavorites && tile.saved == nil ? 0.4 : 1)
            .contentShape(.rect(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(editingFavorites && tile.saved == nil)
        .accessibilityLabel(removing ? String(localized: "\(tile.role.title ?? tile.saved?.endpoint.label ?? "") entfernen") : tileLabel(tile, isAdd: isAdd))
        .accessibilityHint(removing ? Text(verbatim: "") : tile.saved != nil && flow.locationAllowed ? Text("Sucht Verbindungen ab deinem Standort") : Text("Öffnet die Planung"))
        .accessibilityIdentifier("favoriteTile.\(tile.id)")
        .accessibilityActions {
            if let saved = tile.saved {
                Button("Entfernen") { flow.removeFavorite(saved.id) }
            }
        }
        .contextMenu {
            if let saved = tile.saved {
                Button("Entfernen", systemImage: "star.slash", role: .destructive) { flow.removeFavorite(saved.id) }
            }
        }
    }

    private func tileLabel(_ tile: Tile, isAdd: Bool) -> String {
        if isAdd { return String(localized: "Favorit hinzufügen") }
        guard let saved = tile.saved else { return String(localized: "\(tile.role.title ?? "") festlegen") }
        guard let role = tile.role.title else { return saved.endpoint.label }
        return String(localized: "\(role), \(saved.endpoint.label)")
    }
}

extension FavoritePlace.Role {
    /// Feste Kacheln im Start, in dieser Reihenfolge.
    static let tiles: [Self] = [.home, .uni, .work]

    /// nil = weiterer Favorit, dann zaehlt der Name des Orts.
    var title: String? {
        switch self {
        case .home: String(localized: "Zuhause")
        case .uni: String(localized: "Uni")
        case .work: String(localized: "Arbeit")
        case .other: nil
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .uni: "graduationcap.fill"
        case .work: "briefcase.fill"
        case .other: "star.fill"
        }
    }
}

/// Verlaufszeile in Start und Planen: Tipp = Ziel, Wischen = Favorit oder entfernen.
struct RecentRow: View {
    @Environment(AppFlow.self) private var flow
    let saved: SavedPlace

    var body: some View {
        EndpointRow(endpoint: saved.endpoint, symbol: "clock.arrow.circlepath")
            .swipeActions {
                Button("Entfernen", systemImage: "trash", role: .destructive) { flow.removeRecent(saved.id) }
                Button("Favorit", systemImage: "star") { flow.addFavorite(saved.endpoint) }
                    .tint(Color(.accentBlue))
            }
    }
}

/// Gemerkter Ort als Zeile; Tipp waehlt ihn (Start: sucht sofort).
struct EndpointRow: View {
    @Environment(AppFlow.self) private var flow
    let endpoint: TripEndpoint
    let symbol: String

    var body: some View {
        Button { flow.choose(endpoint) } label: {
            ListRow(symbol: symbol, tint: Color(.accentBlue), title: endpoint.label)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("savedPlace")
    }
}

/// Haltestelle in der Naehe mit Gehzeit (Luftlinie im gelernten Tempo).
struct NearbyStopRow: View {
    @Environment(AppFlow.self) private var flow
    let stop: Place

    var body: some View {
        if let id = stop.id, let name = stop.name {
            let mode = stop.modes?.first ?? .unknown
            Button { flow.choose(.stop(id: id, label: name)) } label: {
                ListRow(symbol: mode.symbolName, tint: mode.color, title: name) {
                    if let meters = stop.distanceMeters {
                        let minutes = flow.pace.walkMinutes(meters: meters)
                        Text("\(minutes) Min. zu Fuß")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(Motion.micro, value: minutes)
                            .accessibilityLabel(Text("\(minutes) Minuten zu Fuß"))
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("nearbyStop")
        }
    }
}

struct SettingsButton: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        Button("Einstellungen", systemImage: "gearshape") { flow.showsSettings = true }
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .accessibilityIdentifier("settingsButton")
    }
}

// MARK: - 2 Planen (Von/Nach, Zeit, Vorschlaege, Suche)

/// Ein Bildschirm fuer Start, Ziel, Zeit und Suche. Ein Suchfeld ohne Modus: Treffer kommen zuerst vom Geraet
/// (Favoriten, Verlauf, Haltestellen in der Naehe, Apple Karten). Der Suchtext geht erst nach einem Tipp auf
/// "beim Fahrplan-Server suchen" ans Backend.
struct PlanSheet: View {
    @Environment(AppFlow.self) private var flow
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth = 44.0

    var body: some View {
        // Kopf ausserhalb der Liste: als Inset liefe der Listeninhalt durchscheinend darunter durch (Texte ueberlagerten sich).
        VStack(spacing: 0) {
            header
            List {
                if flow.searchText.count >= 2 { typed } else { suggestions }
            }
            .scrollContentBackground(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            // Erst mit beiden Feldern: vorher gaebe es einen toten Knopf. Beim Festlegen eines Favoriten nie.
            if flow.endpointsFilled, flow.assigningRole == nil {
                PrimaryButton(title: "Verbindungen suchen", systemImage: "magnifyingglass") { flow.send(.planTapped) }
                    .disabled(!flow.canPlan)
                    .accessibilityIdentifier("planButton")
                    .padding(16)
            }
        }
        .onChange(of: flow.query) {
            if flow.query.count > AppFlow.maxQueryLength { flow.query = String(flow.query.prefix(AppFlow.maxQueryLength)) }
            flow.queryChanged()
        }
    }

    // MARK: Kopf

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Abbrechen") { flow.send(.back) }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("cancelSearch")
                Spacer()
                SettingsButton()
            }
            if let role = flow.assigningRole {
                // Favorit festlegen: nur ein Feld, keine Zeit, keine Suche.
                Text(role.title.map { String(localized: "\($0) festlegen") } ?? String(localized: "Favorit hinzufügen"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                field(.destination)
            } else {
                endpointsAndTime
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var endpointsAndTime: some View {
        HStack(spacing: 8) {
            VStack(spacing: 8) {
                field(.origin)
                field(.destination)
            }
            Button("Start und Ziel tauschen", systemImage: "arrow.up.arrow.down") { flow.swapEndpoints() }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                .sensoryFeedback(.selection, trigger: flow.origin)
                .disabled(!flow.canSwap)
                .accessibilityIdentifier("swapButton")
        }
        .animation(Motion.micro, value: flow.origin)
        HStack(spacing: 8) {
            timeMenu
            if flow.customTime != nil {
                @Bindable var flow = flow
                // System-Pille fuer Datum und Uhrzeit; auch Tage im Voraus.
                DatePicker("Zeit", selection: Binding { flow.customTime ?? Date() } set: { flow.customTime = $0 },
                           in: Date()...)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("timePicker")
            }
            Spacer(minLength: 0)
        }
    }

    private func field(_ slot: EndpointSlot) -> some View {
        @Bindable var flow = flow
        let title: LocalizedStringKey = slot == .origin ? "Von" : "Nach"
        // Beim Festlegen eines Favoriten zaehlt das bisherige Ziel nicht.
        let current = self.flow.assigningRole == nil ? label(of: slot) : nil
        return HStack(spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
                .accessibilityHidden(true)
            if self.flow.activeSlot == slot {
                TextField(title, text: $flow.query, prompt: Text(current ?? String(localized: "Haltestelle oder Adresse")))
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit { self.flow.submitSearch() }
                    .accessibilityIdentifier("searchField")
                Image(systemName: "magnifyingglass")
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: self.flow.isSearching)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                Button { self.flow.send(.editEndpoint(slot)) } label: {
                    HStack(spacing: 6) {
                        if case .currentLocation = self.flow.endpoint(slot) {
                            Image(systemName: "location.fill").accessibilityHidden(true)
                        }
                        Text(current ?? String(localized: "Haltestelle oder Adresse"))
                            .lineLimit(1)
                    }
                    .foregroundStyle(current == nil ? Color.secondary : (isCurrentLocation(slot) ? Color(.accentBlue) : Color.primary))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(title))
                .accessibilityValue(current ?? String(localized: "leer"))
                .accessibilityIdentifier(slot == .origin ? "originRow" : "destinationRow")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color(.fillTertiary), in: .capsule)
    }

    /// Text des Feldes; "Mein Standort" ohne Erlaubnis zaehlt als leer, dann ist das Feld einfach tippbar.
    private func label(of slot: EndpointSlot) -> String? {
        switch flow.endpoint(slot) {
        case .place(let place): place.label
        case .currentLocation where flow.locationAllowed: PlanEndpoint.currentLocation.label
        default: nil
        }
    }

    private func isCurrentLocation(_ slot: EndpointSlot) -> Bool {
        flow.endpoint(slot) == .currentLocation && flow.locationAllowed
    }

    private var timeMode: LocalizedStringKey {
        flow.customTime == nil ? "Jetzt" : (flow.isArrivalTime ? "Ankunft" : "Abfahrt")
    }

    /// Pille links: Jetzt / Abfahrt / Ankunft. Die Zeit steht rechts daneben im Datumsfeld.
    private var timeMenu: some View {
        Menu {
            Button("Jetzt", systemImage: "clock") {
                flow.customTime = nil
                flow.isArrivalTime = false
            }
            Button("Abfahrt", systemImage: "figure.walk.departure") {
                flow.isArrivalTime = false
                if flow.customTime == nil { flow.customTime = Date() }
            }
            Button("Ankunft", systemImage: "figure.walk.arrival") {
                flow.isArrivalTime = true
                if flow.customTime == nil { flow.customTime = Date() }
            }
        } label: {
            Label(timeMode, systemImage: "clock")
                .font(.subheadline)
                .foregroundStyle(flow.customTime != nil ? Color(.accentBlue) : Color.primary)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(flow.customTime != nil ? Color(.accentBlueTint) : Color(.fillTertiary), in: .capsule)
                .contentShape(.capsule)
        }
        .accessibilityIdentifier("timeChip")
    }

    // MARK: Leeres Feld

    @ViewBuilder private var suggestions: some View {
        let isEmpty = flow.favorites.isEmpty && flow.recents.isEmpty && flow.nearby.isEmpty && !flow.locationAllowed
        if flow.locationAllowed, flow.assigningRole == nil {
            Section { locationRow }
        }
        if !flow.favorites.isEmpty {
            Section("Favoriten") {
                ForEach(flow.favorites) { saved in
                    EndpointRow(endpoint: saved.endpoint, symbol: saved.role.symbol)
                        .swipeActions {
                            Button("Entfernen", systemImage: "star.slash", role: .destructive) { flow.removeFavorite(saved.id) }
                        }
                }
            }
        }
        if !flow.recents.isEmpty {
            Section("Zuletzt gesucht") {
                ForEach(flow.recents) { RecentRow(saved: $0) }
            }
        }
        if !flow.nearby.isEmpty {
            Section {
                ForEach(flow.nearby, id: \.id) { NearbyStopRow(stop: $0) }
            } header: {
                Text("In der Nähe")
            } footer: {
                if let attribution = flow.attribution { AttributionFooter(attribution: attribution) }
            }
        }
        if isEmpty {
            Text("Tippe einen Ort, eine Adresse oder eine Haltestelle.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
    }

    private var locationRow: some View {
        Button { flow.useCurrentLocation() } label: {
            ListRow(symbol: "location.fill", tint: Color(.accentBlue), title: String(localized: "Mein Standort"),
                    subtitle: flow.lastAccuracy.map { String(localized: "Genauigkeit ± \(Int($0.rounded())) m") })
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("currentLocationRow")
    }

    // MARK: Getippter Text

    /// Favoriten, Verlauf und Haltestellen in der Naehe, die zum Text passen (nur auf dem Geraet).
    private var localMatches: [(endpoint: TripEndpoint, symbol: String)] {
        let text = flow.searchText
        let nearby = flow.nearby.compactMap { stop -> TripEndpoint? in
            guard let id = stop.id, let name = stop.name else { return nil }
            return .stop(id: id, label: name)
        }
        let all = flow.favorites.map { ($0.endpoint, "star.fill") }
            + flow.recents.map { ($0.endpoint, "clock.arrow.circlepath") }
            + nearby.map { ($0, "mappin.and.ellipse") }
        var seen = Set<TripEndpoint>()
        return all.filter { $0.0.label.localizedCaseInsensitiveContains(text) && seen.insert($0.0).inserted }
            .prefix(5)
            .map { (endpoint: $0.0, symbol: $0.1) }
    }

    @ViewBuilder private var typed: some View {
        let local = localMatches
        if !local.isEmpty {
            Section {
                ForEach(local, id: \.endpoint) { match in
                    EndpointRow(endpoint: match.endpoint, symbol: match.symbol)
                }
            }
        }
        if flow.scope == .stops {
            serverResults
        } else {
            if !flow.results.addresses.isEmpty {
                Section {
                    ForEach(flow.results.addresses, id: \.self) { address in
                        Button { flow.choose(.coordinate(address.coordinate, label: address.name)) } label: {
                            ListRow(symbol: "mappin.circle.fill", tint: Color(.accentBlue), title: address.name, subtitle: address.subtitle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("searchResult")
                    }
                } footer: {
                    Label("Adressen werden nur mit Apple Karten auf dem Gerät gesucht.", systemImage: "lock")
                }
            }
            Section {
                Button { flow.searchOnServer() } label: {
                    ListRow(symbol: "server.rack", tint: Color(.accentBlue),
                            title: String(localized: "Haltestelle „\(flow.searchText)“ beim Fahrplan-Server suchen"),
                            subtitle: String(localized: "Sendet den Text, nicht deinen Standort."))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("serverSearchRow")
            } footer: {
                if !flow.locationAllowed {
                    Label("Adressen brauchen deinen Standort.", systemImage: "location.slash")
                }
            }
        }
    }

    @ViewBuilder private var serverResults: some View {
        Section {
            if flow.isSearching {
                ProgressView().frame(maxWidth: .infinity)
            } else if flow.results.stops.isEmpty, flow.banner == nil {
                ContentUnavailableView.search(text: flow.searchText)
            }
            ForEach(flow.results.stops, id: \.self) { stop in
                if let id = stop.id, let name = stop.name {
                    let mode = stop.modes?.first ?? .unknown
                    Button { flow.choose(.stop(id: id, label: name)) } label: {
                        ListRow(symbol: mode.symbolName, tint: mode.color, title: name, subtitle: stop.area)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("searchResult")
                }
            }
        } footer: {
            if let attribution = flow.results.attribution, !flow.results.stops.isEmpty {
                AttributionFooter(attribution: attribution)
            }
        }
    }
}

// MARK: - 3 / 3a / 3e Routenauswahl

struct RouteSheet: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        List {
            if flow.banner == .noConnections {
                ContentUnavailableView {
                    Label("Keine Verbindung gefunden", systemImage: "tram")
                } description: {
                    Text(noConnectionText)
                } actions: {
                    Button("Später suchen") { flow.searchLater() }
                        .accessibilityIdentifier("searchLater")
                    Button("Andere Zeit wählen") { flow.send(.editOptions) }
                }
                .listRowBackground(Color.clear)
            } else if let routes = flow.routes {
                loaded(routes)
            } else if flow.isPlanning {
                loading
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom) {
            // H4: bei AX-Groessen bleibt "Starten" als Knopf unten in der Daumenzone.
            if typeSize.isAccessibilitySize, flow.routes?.journeys.isEmpty == false {
                PrimaryButton(title: "Starten", systemImage: "location.fill") { flow.send(.startNavigation(0)) }
                    .accessibilityIdentifier("startButton")
                    .padding(16)
            }
        }
    }

    private var noConnectionText: String {
        let time = (flow.customTime ?? flow.now).clockText
        return flow.isArrivalTime
            ? String(localized: "Keine Nahverkehrs-Verbindung mit Ankunft bis \(time).")
            : String(localized: "Keine Nahverkehrs-Verbindung ab \(time).")
    }

    /// Kopf: Ziel und Zeit (zurueck zur Planung), Einstellungen.
    private var header: some View {
        HStack(spacing: 8) {
            Button { flow.send(.back) } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Zurück zur Planung")
            .accessibilityIdentifier("backToPlan")
            Button { flow.send(.editOptions) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(flow.destination?.label ?? "").font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("optionsButton")
            SettingsButton()
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
    }

    private var subtitle: String {
        let from = flow.origin.label
        let time = flow.customTime.map {
            Calendar.current.isDateInToday($0) ? $0.clockText
                : $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
        } ?? String(localized: "Jetzt")
        return String(localized: "Von \(from) · \(flow.isArrivalTime ? String(localized: "Ankunft") : String(localized: "Abfahrt")) \(time)")
    }

    // 3a: Skelett in fester Hoehe, redacted; VoiceOver hoert eine Ansage statt der Platzhalter.
    @ViewBuilder private var loading: some View {
        Section {
            Label("Verbindungen werden gesucht", systemImage: "tram.fill")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(.secondary)
                .onAppear { AccessibilityNotification.Announcement(String(localized: "Verbindungen werden gesucht")).post() }
            if flow.isWaitingForNetwork {
                HStack {
                    Label("Warte auf Verbindung", systemImage: "wifi.exclamationmark")
                    Spacer()
                    Button("Abbrechen") { flow.send(.back) }
                }
                .foregroundStyle(Color(.statusWarn))
                .accessibilityIdentifier("waitingRow")
            }
            ContentCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("BESTE VERBINDUNG").font(.caption2)
                    Text("Los in 10 Min.").font(.largeTitle.bold())
                    Text("10:00 – 10:45 · 45 Min.")
                    Text("Platzhalter für die Leg-Bar")
                }
            }
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    @ViewBuilder private func loaded(_ routes: RoutesResponse) -> some View {
        if let best = routes.journeys.first {
            Section {
                if routes.walkOnly {
                    CardHint(text: String(localized: "Start und Ziel liegen nah beieinander. Zu Fuß bist du am schnellsten."),
                             symbol: "figure.walk", tone: .info)
                }
                HeroCard(journey: best, calibrated: flow.calibratedJourney(at: 0))
                    .opacity(flow.isStale ? 0.5 : 1)
                    .transition(.opacity)
            } footer: {
                // Quellenangabe direkt unter der Hero Card, damit sie im mittleren Detent sichtbar bleibt (DESIGN.md 3).
                VStack(alignment: .leading, spacing: 4) {
                    AttributionFooter(attribution: routes.attribution)
                    // Nach der Quellenangabe, damit der Transitous-Link im mittleren Detent sichtbar bleibt.
                    if routes.removedLongDistance > 0 {
                        Label("Einige Verbindungen wurden ausgeblendet (Fernverkehr).", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.footnote)
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        }
        if routes.journeys.count > 1 {
            Section("Alternativen") {
                ForEach(Array(routes.journeys.enumerated().dropFirst()), id: \.offset) { index, journey in
                    Button { flow.send(.journeySelected(index)) } label: {
                        AlternativeRow(journey: journey, calibrated: flow.calibratedJourney(at: index))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("alternativeRow")
                }
            }
            .opacity(flow.isStale ? 0.5 : 1)
        }
    }
}

/// Hero Card (DESIGN.md 3): Eyebrow, Countdown, Zeiten, Leg-Bar, Hinweis, "Starten".
struct HeroCard: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.dynamicTypeSize) private var typeSize
    let journey: Journey
    let calibrated: CalibratedJourney?

    var body: some View {
        // Countdown und VoiceOver-Satz rechnen jede Minute neu.
        TimelineView(.everyMinute) { context in
            let leave = calibrated?.departureFromOrigin ?? journey.departure
            let arrive = calibrated?.arrivalAtDestination ?? journey.arrival
            let firstTransit = journey.legs.first { !$0.isWalk }
            ContentCard {
                VStack(alignment: .leading, spacing: 8) {
                    Button { flow.send(.journeySelected(0)) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("BESTE VERBINDUNG").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline) {
                                countdown(leave: leave, now: context.date)
                                Spacer()
                                if let delay = firstTransit?.departureDelayMinutes, !flow.isStale { DelayBadge(minutes: delay) }
                            }
                            // AX: Uhrzeiten und Dauer untereinander statt gequetscht in einer Zeile.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 4) {
                                    HStack(spacing: 4) { TimeText(date: leave); Text(verbatim: "–"); TimeText(date: arrive) }
                                    Text(verbatim: "·")
                                    summary(leave: leave, arrive: arrive)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) { TimeText(date: leave); Text(verbatim: "–"); TimeText(date: arrive) }
                                    summary(leave: leave, arrive: arrive)
                                }
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            LegBar(journey: journey, calibrated: calibrated)
                            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                                CardHint(text: hint.text, symbol: hint.symbol, tone: hint.tone)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Spoken.hero(journey, calibrated: calibrated, now: context.date))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Öffnet die Fahrtdetails")
                    .accessibilityIdentifier("heroCard")
                    if !typeSize.isAccessibilitySize {
                        PrimaryButton(title: "Starten", systemImage: "location.fill") { flow.send(.startNavigation(0)) }
                            .disabled(flow.blockedUntil != nil || journey.cancelled)
                            .accessibilityIdentifier("startButton")
                    }
                }
            }
        }
        .sensoryFeedback(.warning, trigger: journey.legs.contains { $0.platformChanged == true }) { _, changed in changed }
    }

    private func summary(leave: Date?, arrive: Date?) -> some View {
        HStack(spacing: 4) {
            if let leave, let arrive {
                MinutesText(seconds: Int(arrive.timeIntervalSince(leave)))
                Text(verbatim: "·")
            }
            TransfersText(count: journey.transfers)
        }
    }

    @ViewBuilder private func countdown(leave: Date?, now: Date) -> some View {
        let minutes = leave.map { max(0, Int(($0.timeIntervalSince(now) / 60).rounded(.down))) }
        Group {
            if let minutes, minutes > 0 {
                Text("Los in \(DurationLabel.short(minutes: minutes))")
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Motion.micro, value: minutes)
            } else {
                Text("Jetzt los")
            }
        }
        .font(.largeTitle.bold())
        .fontDesign(.rounded)
        .monospacedDigit()
        .foregroundStyle(.primary)
    }

    private struct Hint { let text: String; let symbol: String; let tone: Tone }

    /// Hinweiszeile: Ausfall, Ersatzverkehr (wo der Bus abfaehrt), Gleiswechsel, knapper Umstieg.
    private var hints: [Hint] {
        var out: [Hint] = []
        if journey.cancelled {
            out.append(Hint(text: String(localized: "Fällt aus"), symbol: "xmark.octagon.fill", tone: .alert))
        }
        if let sev = journey.legs.first(where: \.replacement) {
            let from = sev.origin.name ?? ""
            out.append(Hint(text: String(localized: "Ersatzverkehr: Bus ab \(from)"), symbol: "bus.fill", tone: .alert))
        }
        if let changed = journey.legs.first(where: { $0.platformChanged == true }), let platform = changed.departurePlatform {
            let text = changed.plannedDeparturePlatform.map { String(localized: "Gleis \(platform) statt \($0)") }
                ?? String(localized: "Gleis \(platform)")
            out.append(Hint(text: text, symbol: "exclamationmark.triangle.fill", tone: .warn))
        }
        if calibrated?.transfers.contains(where: { $0.status == .missed }) == true {
            out.append(Hint(text: String(localized: "Umstieg reicht nicht"), symbol: "figure.walk.motion", tone: .alert))
        } else if calibrated?.transfers.contains(where: \.isAtRisk) == true {
            out.append(Hint(text: String(localized: "Umstieg knapp"), symbol: "figure.walk.motion", tone: .warn))
        }
        return out
    }
}

/// Alternative: Uhrzeiten, Badges, Status, Dauer; 46 pt.
struct AlternativeRow: View {
    let journey: Journey
    let calibrated: CalibratedJourney?

    var body: some View {
        TimelineView(.everyMinute) { context in
            let leave = calibrated?.departureFromOrigin ?? journey.departure
            let arrive = calibrated?.arrivalAtDestination ?? journey.arrival
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        TimeText(date: leave)
                        Text(verbatim: "–")
                        TimeText(date: arrive)
                    }
                    .font(.subheadline.weight(.semibold))
                    HStack(spacing: 4) {
                        ForEach(journey.legs.filter { !$0.isWalk }, id: \.index) { LineBadge(leg: $0) }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if let leave, let arrive { MinutesText(seconds: Int(arrive.timeIntervalSince(leave))).font(.subheadline) }
                    status
                }
            }
            .frame(minHeight: 46)
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Spoken.journey(journey, calibrated: calibrated, now: context.date))
        }
    }

    @ViewBuilder private var status: some View {
        if journey.cancelled {
            Text("Fällt aus").font(.caption.weight(.semibold)).foregroundStyle(Color(.statusAlert))
        } else if journey.legs.contains(where: \.replacement) {
            Text("Ersatzverkehr").font(.caption.weight(.semibold)).foregroundStyle(Color(.modeBus))
        } else if let delay = journey.legs.first(where: { !$0.isWalk })?.departureDelayMinutes {
            DelayBadge(minutes: delay)
        } else if journey.realtime {
            Text("Pünktlich").font(.caption).foregroundStyle(Color(.statusOk))
        }
    }
}

/// "1 Umstieg" / "2 Umstiege", ohne Umstieg "direkt" (Figma).
struct TransfersText: View {
    let count: Int

    var body: some View {
        if count == 0 {
            Text("direkt")
        } else {
            Text("\(count) Umstiege").monospacedDigit().contentTransition(.numericText())
        }
    }
}
