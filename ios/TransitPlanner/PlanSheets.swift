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
                SettingsButton(filled: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
            // Favoriten-Chips gehoeren zum Kopf: schon im kleinen Detent (140 pt) erreichbar, nicht in der Liste versteckt.
            if showsFixedTiles {
                tiles
                    .padding(.bottom, 4)
            }
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
                    // Bei fester Chip-Reihe stehen Chips und "Bearbeiten" im Kopf; ein leerer Abschnitt hinterliess nur Leerraum.
                    if !showsFixedTiles {
                        Section {
                            tiles
                        } header: {
                            if hasRoleFavorites { favoritesHeader }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                    let others = flow.favorites.filter { $0.role == .other }
                    if !others.isEmpty {
                        CardSection("Weitere Favoriten") {
                            ForEach(others) { saved in
                                EndpointRow(endpoint: saved.endpoint, symbol: saved.role.symbol)
                                    .swipeActions {
                                        Button("Entfernen", systemImage: "star.slash", role: .destructive) { flow.removeFavorite(saved.id) }
                                    }
                            }
                        }
                    }
                    if !flow.recents.isEmpty {
                        CardSection("Zuletzt gesucht") {
                            ForEach(flow.recents.prefix(Self.recentLimit)) { RecentRow(saved: $0) }
                        }
                    }
                }
                // Ohne Standort entfaellt der Abschnitt ohne Banner.
                if flow.locationAllowed, !flow.nearby.isEmpty {
                    CardSection(title: "Haltestellen in der Nähe") {
                        ForEach(flow.nearby, id: \.id) { NearbyStopRow(stop: $0) }
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

    /// Chips in einer festen Reihe unter dem Suchfeld (nicht bei AX: dort stehen sie untereinander in der Liste).
    private var showsFixedTiles: Bool {
        !typeSize.isAccessibilitySize && !(flow.favorites.isEmpty && flow.recents.isEmpty)
    }

    private var hasRoleFavorites: Bool { flow.favorites.contains { $0.role != .other } }

    private var favoritesHeader: some View {
        HStack {
            Text("Favoriten")
            Spacer()
            editButton
        }
        .textCase(nil)
    }

    private var editButton: some View {
        Button(editingFavorites ? "Fertig" : "Bearbeiten") {
            withAnimation(Motion.micro) { editingFavorites.toggle() }
        }
        .font(.subheadline)
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityIdentifier("editFavorites")
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

    /// Favoriten als Chips in einer Reihe (Figma), seitlich scrollbar; bei AX-Groessen untereinander.
    @ViewBuilder private var tiles: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tileModels) { tile($0) }
            }
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(tileModels) { tile($0) }
                    if hasRoleFavorites { editButton.padding(.leading, 8) }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func tile(_ tile: Tile) -> some View {
        let isAdd = tile.role == .other && tile.saved == nil
        let title = isAdd ? String(localized: "Hinzufügen") : (tile.role.title ?? tile.saved?.endpoint.label ?? "")
        let removing = editingFavorites && tile.saved != nil
        return Button {
            if let saved = tile.saved {
                if editingFavorites { withAnimation(Motion.standard) { flow.removeFavorite(saved.id) } } else { flow.choose(saved.endpoint) }
            } else {
                flow.assignFavorite(tile.role)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isAdd ? "plus" : tile.role.symbol)
                    .foregroundStyle(Color(.accentBlue))
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(tile.saved == nil && !isAdd ? Color(.labelSecondary) : Color.primary)
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(Color(.surfaceCard), in: .capsule)
            .overlay {
                if colorScheme == .dark { Capsule().strokeBorder(.separator, lineWidth: 0.5) }
            }
            .padding(.vertical, 2) // Tippflaeche 44 pt, sichtbar 40 pt
            .overlay(alignment: .topLeading) {
                if removing {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color(.labelOnAccent), Color(.statusAlert))
                        .font(.title3)
                        .offset(x: -4, y: -4)
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                }
            }
            .opacity(editingFavorites && tile.saved == nil ? 0.4 : 1)
            .contentShape(.capsule)
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

    /// Im Start als graue Kreisflaeche (Figma).
    var filled = false

    var body: some View {
        Button("Einstellungen", systemImage: "gearshape") { flow.showsSettings = true }
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 44, height: 44)
            .background(filled ? Color(.fillTertiary) : .clear, in: .circle)
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
    @Environment(\.sheetLevel) private var level
    @FocusState private var focused: Bool

    /// Kleinster Detent ohne Eingabe: nur Zusammenfassung und Suchen-Knopf (Formular und Liste haetten dort keinen Platz).
    private var showsPeek: Bool { level == .peek && flow.activeSlot == nil && flow.assigningRole == nil }

    var body: some View {
        // Kopf ausserhalb der Liste: als Inset liefe der Listeninhalt durchscheinend darunter durch (Texte ueberlagerten sich).
        VStack(spacing: 0) {
            if showsPeek {
                peek
            } else {
                header
                List {
                    if flow.searchText.count >= 2 { typed } else { suggestions }
                }
                .scrollContentBackground(.hidden)
                // Abschnitte ohne Titel liessen sonst grosse Luecken zwischen Eingabe und Treffern.
                .listSectionSpacing(.compact)
            }
        }
        .onChange(of: flow.query) {
            if flow.query.count > AppFlow.maxQueryLength { flow.query = String(flow.query.prefix(AppFlow.maxQueryLength)) }
            flow.queryChanged()
        }
    }

    // MARK: Peek (140 pt)

    private var peek: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(label(of: .origin) ?? String(localized: "Start"))
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(label(of: .destination) ?? String(localized: "Ziel"))
            }
            .font(.headline)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if flow.endpointsFilled {
                PrimaryButton(title: "Verbindungen suchen", systemImage: "magnifyingglass") { flow.send(.planTapped) }
                    .disabled(!flow.canPlan)
                    .accessibilityIdentifier("planButton")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Kopf

    private var header: some View {
        VStack(spacing: 12) {
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
                card { field(.destination) }
            } else {
                endpointsAndTime
            }
        }
        .animation(Motion.micro, value: flow.endpointsFilled)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    /// Weisse Karte (surface/card) wie in Figma; im Dark Mode mit feinem Rand.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(Color(.surfaceCard), in: .rect(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var endpointsAndTime: some View {
        @Bindable var flow = flow
        HStack(spacing: 8) {
            card {
                VStack(spacing: 0) {
                    field(.origin)
                    Divider().padding(.leading, 16)
                    field(.destination)
                }
            }
            Button("Start und Ziel tauschen", systemImage: "arrow.up.arrow.down") { flow.swapEndpoints() }
                .labelStyle(.iconOnly)
                .foregroundStyle(Color(.accentBlue))
                .frame(width: 44, height: 44)
                .background(Color(.fillTertiary), in: .circle)
                .contentShape(.circle)
                .sensoryFeedback(.selection, trigger: flow.origin)
                .disabled(!flow.canSwap)
                .accessibilityIdentifier("swapButton")
        }
        .animation(Motion.micro, value: flow.origin)
        if !focused { timeRow }
        if !focused { modePills }
        if !focused { StepFreeToggle().font(.subheadline).padding(.horizontal, 6).padding(.top, -6) } // Rand wie die Pillen-Beschriftung
        if !focused, flow.endpointsFilled, flow.assigningRole == nil {
            PrimaryButton(title: "Verbindungen suchen", systemImage: "magnifyingglass") { flow.send(.planTapped) }
                .disabled(!flow.canPlan)
                .accessibilityIdentifier("planButton")
        }
    }

    /// Zeit in einem Segment (Jetzt / Abfahrt / Ankunft); erst bei Abfahrt oder Ankunft erscheint darunter das Datumsfeld.
    @ViewBuilder private var timeRow: some View {
        @Bindable var flow = flow
        VStack(spacing: 8) {
            Picker("Zeit", selection: Binding {
                if flow.customTime == nil { TimeKind.now } else if flow.isArrivalTime { TimeKind.arrival } else { TimeKind.departure }
            } set: { kind in
                flow.isArrivalTime = kind == .arrival
                if kind == .now { flow.customTime = nil } else if flow.customTime == nil { flow.customTime = Date() }
            }) {
                Text("Jetzt").tag(TimeKind.now)
                Text("Abfahrt").tag(TimeKind.departure)
                Text("Ankunft").tag(TimeKind.arrival)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("timeMode")
            if flow.customTime != nil {
                DatePicker(flow.isArrivalTime ? "Ankunft um" : "Abfahrt um", selection: Binding { flow.customTime ?? Date() } set: { flow.customTime = $0 }, in: Date()...Date().addingTimeInterval(59 * 24 * 3600))
                    .datePickerStyle(.compact)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("timePicker")
                    .transition(.opacity)
            }
        }
        .animation(Motion.micro, value: flow.customTime == nil)
    }

    private enum TimeKind: Hashable { case now, departure, arrival }

    /// Verkehrsmittel-Pillen (Figma): Punkt in Modusfarbe + Name; aus = abgeblendet. Mindestens eine bleibt an.
    private var modePills: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("VERKEHRSMITTEL").font(.caption2.weight(.semibold)).foregroundStyle(Color(.labelSecondary))
                .accessibilityHidden(true)
            HFlow(spacing: 8) {
                ForEach(ModeFilter.allCases, id: \.self) { mode in
                    let on = flow.modeFilter.contains(mode)
                    Button { withAnimation(Motion.micro) { flow.toggle(mode) } } label: {
                        HStack(spacing: 4) {
                            Circle().fill(mode.transitMode.color).frame(width: 8, height: 8)
                            Text(mode.title).font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(on ? Color.primary : Color(.labelSecondary))
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                        .background(on ? Color(.surfaceCard) : .clear, in: .capsule)
                        .overlay { if !on { Capsule().strokeBorder(.separator, lineWidth: 1) } }
                        .opacity(on ? 1 : 0.7)
                        .frame(minHeight: 44) // Tippflaeche 44 pt, sichtbar 32 pt
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("modePill.\(mode.rawValue)")
                }
            }
        }
        .sensoryFeedback(.selection, trigger: flow.modeFilter)
    }

    @ViewBuilder private func field(_ slot: EndpointSlot) -> some View {
        let title: LocalizedStringKey = slot == .origin ? "Von" : "Nach"
        if flow.activeSlot == slot {
            fieldContent(slot, title: title)
        } else {
            // Ganzes Feld inkl. Padding ist die Tippflaeche (mind. 56 pt hoch), nicht nur die Textzeile.
            let current = flow.assigningRole == nil ? label(of: slot) : nil
            Button { flow.send(.editEndpoint(slot)) } label: {
                fieldContent(slot, title: title).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(current ?? String(localized: "leer"))
            .accessibilityIdentifier(slot == .origin ? "originRow" : "destinationRow")
        }
    }

    private func fieldContent(_ slot: EndpointSlot, title: LocalizedStringKey) -> some View {
        @Bindable var flow = flow
        // Beim Festlegen eines Favoriten zaehlt das bisherige Ziel nicht.
        let current = self.flow.assigningRole == nil ? label(of: slot) : nil
        return VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color(.labelSecondary))
                .accessibilityHidden(true)
            if self.flow.activeSlot == slot {
                HStack(spacing: 8) {
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
                }
                .frame(minHeight: 28)
            } else {
                HStack(spacing: 6) {
                    if case .currentLocation = self.flow.endpoint(slot) {
                        Image(systemName: "location.fill").accessibilityHidden(true)
                    }
                    Text(current ?? String(localized: "Haltestelle oder Adresse"))
                        .lineLimit(1)
                }
                .foregroundStyle(current == nil ? Color.secondary : (isCurrentLocation(slot) ? Color(.accentBlue) : Color.primary))
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
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

    // MARK: Leeres Feld

    @ViewBuilder private var suggestions: some View {
        let isEmpty = flow.favorites.isEmpty && flow.recents.isEmpty && flow.nearby.isEmpty && !flow.locationAllowed
        if flow.locationAllowed, flow.assigningRole == nil {
            Section { locationRow.listRowBackground(Color(.surfaceCard)) }
        }
        if !flow.favorites.isEmpty {
            CardSection("Favoriten") {
                ForEach(flow.favorites) { saved in
                    EndpointRow(endpoint: saved.endpoint, symbol: saved.role.symbol)
                        .swipeActions {
                            Button("Entfernen", systemImage: "star.slash", role: .destructive) { flow.removeFavorite(saved.id) }
                        }
                }
            }
        }
        if !flow.recents.isEmpty {
            CardSection("Zuletzt gesucht") {
                ForEach(flow.recents) { RecentRow(saved: $0) }
            }
        }
        if !flow.nearby.isEmpty {
            CardSection(title: "In der Nähe") {
                ForEach(flow.nearby, id: \.id) { NearbyStopRow(stop: $0) }
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
        // Entscheidung B (30.10.): Standard-Navigationsleiste. Der NavigationStack lebt nur im Sheet-Inhalt und hat
        // keinen Pfad (kein Push); Phasenwechsel und Detents steuert weiter SheetRoot.
        NavigationStack {
            list
                .navigationTitle(Text("Nach \(flow.destination?.label ?? "")"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
    }

    private var list: some View {
        List {
            // Der Banner liegt hier in der Liste: ueber der Navigationsleiste verdeckte er "Zurueck zur Planung".
            if let error = flow.banner, error.showsBanner {
                InlineBanner(error: error)
                    .id(error)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if flow.banner == .noConnections {
                ContentUnavailableView {
                    Label("Keine Verbindung gefunden", systemImage: "tram")
                } description: {
                    Text(noConnectionText)
                } actions: {
                    Button("Später suchen") { flow.searchLater() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("searchLater")
                    Button("Andere Zeit wählen") { flow.send(.editOptions) }
                        .frame(minHeight: 44)
                }
                .listRowBackground(Color.clear)
            } else if let routes = flow.routes {
                loaded(routes)
            } else if flow.isPlanning {
                loading
            }
        }
        .scrollContentBackground(.hidden)
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

    /// Leiste: Zurueck zur Planung links, Titel "Nach Ziel", Zeit rechts (oeffnet die Planung).
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Zurück zur Planung", systemImage: "chevron.backward") { flow.send(.back) }
                .accessibilityIdentifier("backToPlan")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { flow.send(.editOptions) } label: {
                HStack(spacing: 4) {
                    Text(timeLabel).monospacedDigit().contentTransition(.numericText())
                    Image(systemName: "chevron.down").imageScale(.small)
                }
                .font(.subheadline.weight(.semibold))
            }
            .accessibilityLabel(Text(subtitle))
            .accessibilityHint("Ändert Start, Ziel oder Zeit")
            .accessibilityIdentifier("optionsButton")
        }
    }

    private var timeLabel: String {
        flow.customTime.map {
            Calendar.current.isDateInToday($0) ? $0.clockText
                : $0.formatted(.dateTime.day().month(.abbreviated).hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
        } ?? String(localized: "Jetzt")
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
            // Eine weisse Karte mit Zeilen und Trennern (Figma); Titel unter der Quellenangabe, damit die Alternativen
            // nicht als Teil der Fussnote wirken.
            Section {
                let rest = Array(routes.journeys.enumerated().dropFirst())
                VStack(spacing: 0) {
                    ForEach(Array(rest.enumerated()), id: \.offset) { position, entry in
                        if position > 0 { Divider().padding(.leading, 16) }
                        Button { flow.send(.journeySelected(entry.offset)) } label: {
                            AlternativeRow(journey: entry.element, calibrated: flow.calibratedJourney(at: entry.offset))
                                .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("alternativeRow")
                    }
                }
                .background(Color(.surfaceCard), in: .rect(cornerRadius: 16, style: .continuous))
                .opacity(flow.isStale ? 0.5 : 1)
            } header: {
                SectionTitle("Weitere Verbindungen")
                    .accessibilityAddTraits(.isHeader)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
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
                VStack(alignment: .leading, spacing: 12) {
                    Button { flow.send(.journeySelected(0)) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("BESTE VERBINDUNG").font(.caption2.weight(.semibold)).foregroundStyle(Color(.labelSecondary))
                                Spacer()
                                if let delay = firstTransit?.departureDelayMinutes, !flow.isStale { DelayBadge(minutes: delay) }
                            }
                            countdown(leave: leave, now: context.date)
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
                            // Hinweise als einfache Zeile in Statusfarbe, ohne Kasten (Figma).
                            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: hint.symbol).imageScale(.small).accessibilityHidden(true)
                                    Text(hint.text).fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(hint.tone.foreground)
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
                        // Entscheidung A (30.10.): nur "Starten"; die Fahrtdetails oeffnet ein Tipp auf die Karte.
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
        if let text = journey.legs.lazy.compactMap(\.platformChangeHint).first {
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

/// Alternative (Figma): Uhrzeiten, Badges, Status links, Dauer rechts; 46 pt.
struct AlternativeRow: View {
    let journey: Journey
    let calibrated: CalibratedJourney?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        TimelineView(.everyMinute) { context in
            let leave = calibrated?.departureFromOrigin ?? journey.departure
            let arrive = calibrated?.arrivalAtDestination ?? journey.arrival
            // AX-Groessen: Dauer unter den Block, sonst laeuft der einzeilige Status ueber den Rand.
            let ax = typeSize.isAccessibilitySize
            let layout = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { times(leave, arrive); badges; status }
                    // Lange Ketten: Status neben die Zeiten, Badges brechen um wie in der Leg-Bar. Frueher stand der
                    // Status in einem HStack neben festen Badges, bekam fast keine Breite und brach zeichenweise um.
                    // Die Badges stehen ausserhalb des inneren ViewThatFits, weil FlowLayout als Idealbreite eine
                    // einzige lange Zeile meldet und damit jede Variante "zu breit" waere.
                    VStack(alignment: .leading, spacing: 4) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) { times(leave, arrive); status }
                            // AX-Groessen: Zeiten und Status passen nicht nebeneinander.
                            VStack(alignment: .leading, spacing: 4) { times(leave, arrive); status }
                        }
                        FlowLayout(spacing: 4, lineSpacing: 4) {
                            ForEach(journey.legs.filter { !$0.isWalk }, id: \.index) { LineBadge(leg: $0) }
                        }
                    }
                }
                .layoutPriority(1)
                if !ax { Spacer(minLength: 4) }
                if let leave, let arrive {
                    MinutesText(seconds: Int(arrive.timeIntervalSince(leave)))
                        .font(.footnote)
                        .foregroundStyle(Color(.labelSecondary))
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Spoken.journey(journey, calibrated: calibrated, now: context.date))
        }
    }

    private func times(_ leave: Date?, _ arrive: Date?) -> some View {
        HStack(spacing: 4) {
            TimeText(date: leave)
            Text(verbatim: "–")
            TimeText(date: arrive)
        }
        .font(.footnote.weight(.semibold))
        .fixedSize()
    }

    private var badges: some View {
        HStack(spacing: 4) {
            ForEach(journey.legs.filter { !$0.isWalk }, id: \.index) { LineBadge(leg: $0) }
        }
    }

    /// Immer einzeilig in voller Breite, nie gequetscht.
    private var status: some View {
        statusText.lineLimit(1).fixedSize()
    }

    @ViewBuilder private var statusText: some View {
        if journey.cancelled {
            Text("Fällt aus").font(.caption.weight(.semibold)).foregroundStyle(Color(.statusAlert))
        } else if calibrated?.transfers.contains(where: { $0.status == .missed }) == true {
            // Sonst steht "pünktlich" an einer Verbindung, die wegen des Umstiegs nicht vorn landet.
            Text("Umstieg reicht nicht").font(.caption.weight(.semibold)).foregroundStyle(Color(.statusAlert))
        } else if journey.legs.contains(where: \.replacement) {
            Text("Ersatzverkehr").font(.caption.weight(.semibold)).foregroundStyle(Color(.modeBus))
        } else if let delay = journey.legs.first(where: { !$0.isWalk })?.departureDelayMinutes {
            DelayBadge(minutes: delay)
        } else if journey.realtime {
            Text("pünktlich").font(.caption).foregroundStyle(Color(.statusOk))
        } else if journey.transfers > 0 {
            TransfersText(count: journey.transfers).font(.caption).foregroundStyle(Color(.labelSecondary))
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

/// Pillen laufen in die naechste Zeile, wenn die Breite nicht reicht (AX-Groessen).
private struct HFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        var origins: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

#if DEBUG
// MARK: - Vorschau (Mock-Daten und Flow aus PreviewSupport.swift)

#Preview("Start, Hell", traits: .modifier(PreviewFlow.start)) { PreviewSheetBackdrop { StartSheet() } }
#Preview("Start, Dunkel", traits: .modifier(PreviewFlow.start)) { PreviewSheetBackdrop { StartSheet() }.preferredColorScheme(.dark) }
#Preview("Start, AX3", traits: .modifier(PreviewFlow.start)) { PreviewSheetBackdrop { StartSheet() }.dynamicTypeSize(.accessibility3) }
#Preview("Start, leer", traits: .modifier(PreviewFlow.startEmpty)) { PreviewSheetBackdrop { StartSheet() } }
#Preview("Start, ohne Standort", traits: .modifier(PreviewFlow.startNoLocation)) { PreviewSheetBackdrop { StartSheet() } }

#Preview("Planen, leer", traits: .modifier(PreviewFlow.plan())) { PreviewSheetBackdrop { PlanSheet() } }
#Preview("Planen, Eingabe", traits: .modifier(PreviewFlow.plan(query: "Musterstraße"))) { PreviewSheetBackdrop { PlanSheet() } }
#Preview("Planen, Dunkel", traits: .modifier(PreviewFlow.plan())) { PreviewSheetBackdrop { PlanSheet() }.preferredColorScheme(.dark) }
#Preview("Planen, AX3", traits: .modifier(PreviewFlow.plan())) { PreviewSheetBackdrop { PlanSheet() }.dynamicTypeSize(.accessibility3) }

#Preview("Routen, Störung, Hell", traits: .modifier(PreviewFlow.routes(PreviewData.disrupted))) { PreviewSheetBackdrop { RouteSheet() } }
#Preview("Routen, Störung, Dunkel", traits: .modifier(PreviewFlow.routes(PreviewData.disrupted))) {
    PreviewSheetBackdrop { RouteSheet() }.preferredColorScheme(.dark)
}
#Preview("Routen, Störung, AX3", traits: .modifier(PreviewFlow.routes(PreviewData.disrupted))) {
    PreviewSheetBackdrop { RouteSheet() }.dynamicTypeSize(.accessibility3)
}
#Preview("Routen, kurz", traits: .modifier(PreviewFlow.routes(PreviewData.short))) { PreviewSheetBackdrop { RouteSheet() } }
#Preview("Routen, lang", traits: .modifier(PreviewFlow.routes(PreviewData.long))) { PreviewSheetBackdrop { RouteSheet() } }
#Preview("Routen, lang, AX3", traits: .modifier(PreviewFlow.routes(PreviewData.long))) {
    PreviewSheetBackdrop { RouteSheet() }.dynamicTypeSize(.accessibility3)
}
#Preview("Routen, Laden", traits: .modifier(PreviewFlow.loading)) { PreviewSheetBackdrop { RouteSheet() } }
#Preview("Routen, leer", traits: .modifier(PreviewFlow.noConnections)) { PreviewSheetBackdrop { RouteSheet() } }
#Preview("Routen, Server weg", traits: .modifier(PreviewFlow.failure(.upstreamUnavailable))) {
    PreviewSheetBackdrop { RouteSheet() }
}

/// Hero Card und Alternativen ohne Kalibrierung ("ca."), je Mock-Fall.
private struct JourneyCardsGallery: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(Array([PreviewData.short, PreviewData.disrupted, PreviewData.long, PreviewData.tight]
                    .compactMap { $0?.journeys.first }.enumerated()), id: \.offset) { _, journey in
                    HeroCard(journey: journey, calibrated: nil)
                    AlternativeRow(journey: journey, calibrated: nil)
                }
                HStack(spacing: 16) {
                    TransfersText(count: 0)
                    TransfersText(count: 3)
                }
            }
            .padding(16)
        }
        .background(Color(.surfaceSheet))
    }
}

#Preview("Hero Card, Hell", traits: .modifier(PreviewFlow.start)) { JourneyCardsGallery() }
#Preview("Hero Card, Dunkel", traits: .modifier(PreviewFlow.start)) { JourneyCardsGallery().preferredColorScheme(.dark) }
#Preview("Hero Card, AX3", traits: .modifier(PreviewFlow.start)) { JourneyCardsGallery().dynamicTypeSize(.accessibility3) }

#Preview("Zeilen", traits: .modifier(PreviewFlow.start)) {
    List {
        RecentRow(saved: SavedPlace(id: UUID(), endpoint: .stop(id: "de-DELFI_de:05315:11201", label: "Köln Hbf"), isFavorite: false))
        EndpointRow(endpoint: .stop(id: "hha", label: "Heinrich-Heine-Allee"), symbol: "star.fill")
        ForEach(FakeData.stops, id: \.self) { NearbyStopRow(stop: $0) }
        HStack {
            SettingsButton()
            SettingsButton(filled: true)
        }
    }
}
#endif
