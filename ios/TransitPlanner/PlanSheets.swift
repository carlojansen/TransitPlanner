import SwiftUI
import TransitCore

// MARK: - 1 Start

/// Suchfeld (als Knopf) mit Einstellungsknopf rechts daneben (DESIGN.md B1, G1).
struct StartSheet: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            // Nur ein selbst gewaehlter Ort, nie "Mein Standort" oder eine GPS-Koordinate.
            if let destination = flow.destination?.place {
                Button { flow.send(.editEndpoint(.destination)) } label: {
                    ListRow(symbol: "clock.arrow.circlepath", tint: Color(.accentBlue), title: destination.label,
                            subtitle: String(localized: "Zuletzt gesucht"))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .frame(maxHeight: .infinity, alignment: .top)
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

// MARK: - 2 / 2b Suche mit Pflichtschalter

struct SearchSheet: View {
    @Environment(AppFlow.self) private var flow
    let slot: EndpointSlot
    @FocusState private var focused: Bool
    /// Letzte Wahl des Suchmodus (DESIGN.md 2b). Der Suchtext wird nie gemerkt.
    @SceneStorage("searchScope") private var storedScope = "address"

    var body: some View {
        @Bindable var flow = flow
        List {
            Section {
                ForEach(addressRows, id: \.self) { address in
                    Button { flow.choose(.coordinate(address.coordinate, label: address.name)) } label: {
                        ListRow(symbol: "mappin.circle.fill", tint: Color(.accentBlue), title: address.name, subtitle: address.subtitle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("searchResult")
                }
                ForEach(stopRows, id: \.self) { stop in
                    if let id = stop.id, let name = stop.name {
                        let mode = stop.modes?.first ?? .unknown
                        Button { flow.choose(.stop(id: id, label: name)) } label: {
                            ListRow(symbol: mode.symbolName, tint: mode.color, title: name, subtitle: stop.area)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("searchResult")
                    }
                }
            } header: {
                if flow.locationAllowed {
                    Button { flow.useCurrentLocation() } label: {
                        ListRow(symbol: "location.fill", tint: Color(.accentBlue), title: String(localized: "Mein Standort"),
                                subtitle: flow.lastAccuracy.map { String(localized: "Genauigkeit ± \(Int($0.rounded())) m") })
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                    .accessibilityIdentifier("currentLocationRow")
                }
            } footer: {
                if flow.scope == .stops, let attribution = flow.results.attribution, !stopRows.isEmpty {
                    AttributionFooter(attribution: attribution)
                }
            }
            emptyState
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .onChange(of: flow.query) {
            if flow.query.count > AppFlow.maxQueryLength { flow.query = String(flow.query.prefix(AppFlow.maxQueryLength)) }
            flow.queryChanged()
        }
        .onAppear {
            if storedScope == "stops" { flow.setScope(.stops) }
            focused = true
        }
    }

    private var addressRows: [AddressResult] { flow.scope == .address ? flow.results.addresses : [] }
    private var stopRows: [Place] { flow.scope == .stops ? flow.results.stops : [] }

    private var header: some View {
        @Bindable var flow = flow
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: flow.isSearching)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(flow.scope == .stops ? "Haltestelle suchen" : "Adresse oder Ort", text: $flow.query)
                        // Im Haltestellenmodus keine eigenen Adressen vorschlagen, sie gingen sonst als Suchtext ans Backend.
                        .textContentType(flow.scope == .address ? .fullStreetAddress : nil)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($focused)
                        .onSubmit { flow.submitSearch() }
                        .accessibilityIdentifier("searchField")
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color(.fillTertiary), in: .capsule)
                Button("Abbrechen") { flow.send(.back) }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("cancelSearch")
            }
            Picker("Suchmodus", selection: Binding { flow.scope } set: { scope in
                flow.setScope(scope)
                storedScope = scope == .stops ? "stops" : "address"
            }) {
                Text("Adresse").tag(SearchScope.address)
                Text("Haltestelle").tag(SearchScope.stops)
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(.selection, trigger: flow.scope)
            Label(flow.scope == .stops
                  ? "Der Suchtext geht ohne Standort an den Fahrplan-Server."
                  : "Adressen werden nur mit Apple Karten auf dem Gerät gesucht.",
                  systemImage: flow.scope == .stops ? "info.circle" : "lock")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var emptyState: some View {
        let empty = addressRows.isEmpty && stopRows.isEmpty
        if empty, flow.isSearching {
            Section { ProgressView().frame(maxWidth: .infinity) }
                .listRowBackground(Color.clear)
        } else if empty, flow.query.trimmingCharacters(in: .whitespaces).count >= 2, flow.banner == nil {
            ContentUnavailableView.search(text: flow.query)
                .listRowBackground(Color.clear)
        }
    }
}

// MARK: - 2c Von/Nach und Zeit

struct OptionsSheet: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        @Bindable var flow = flow
        List {
            Section {
                Group {
                    endpointRow(.origin, title: "Von", id: "originRow")
                    endpointRow(.destination, title: "Nach", id: "destinationRow")
                }
                .animation(Motion.micro, value: flow.origin)
                Button("Start und Ziel tauschen", systemImage: "arrow.up.arrow.down") { flow.swapEndpoints() }
                .frame(minHeight: 44)
                .sensoryFeedback(.selection, trigger: flow.origin)
                .disabled(!flow.canSwap)
                .accessibilityIdentifier("swapButton")
            }
            Section {
                Picker("Zeitbezug", selection: $flow.isArrivalTime) {
                    Text("Abfahrt").tag(false)
                    Text("Ankunft").tag(true)
                }
                .pickerStyle(.segmented)
                DatePicker("Zeit", selection: Binding { flow.customTime ?? Date() } set: { flow.customTime = $0 })
                    .datePickerStyle(.compact)
                if flow.customTime != nil {
                    Button("Jetzt") { flow.customTime = nil }
                }
            } footer: {
                Text("Mit einer Haltestelle als Start erfährt der Server nicht, wo du gerade bist.")
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button("Verbindungen", systemImage: "chevron.backward") { flow.send(.back) }
                    .frame(minHeight: 44)
                Spacer()
                SettingsButton()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "Verbindungen suchen", systemImage: "magnifyingglass") { flow.send(.planTapped) }
                .disabled(!flow.canPlan)
                .accessibilityIdentifier("planButton")
                .padding(16)
        }
    }

    private func endpointRow(_ slot: EndpointSlot, title: LocalizedStringKey, id: String) -> some View {
        Button { flow.send(.editEndpoint(slot)) } label: {
            HStack {
                Text(title).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                switch flow.endpoint(slot) {
                case .place(let place):
                    Text(place.label).foregroundStyle(.primary)
                case .currentLocation where flow.locationAllowed:
                    Label("Mein Standort", systemImage: "location.fill").foregroundStyle(Color(.accentBlue))
                default:
                    // "Mein Standort" ohne Erlaubnis oder noch nichts gewaehlt
                    Text("Wählen").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
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
                    .padding(16)
            }
        }
    }

    private var noConnectionText: String {
        let time = (flow.customTime ?? Date()).formatted(date: .omitted, time: .shortened)
        return flow.isArrivalTime
            ? String(localized: "Keine Nahverkehrs-Verbindung mit Ankunft bis \(time).")
            : String(localized: "Keine Nahverkehrs-Verbindung ab \(time).")
    }

    /// Kopf: Ziel und "Jetzt" (oeffnet 2c), Einstellungen.
    private var header: some View {
        HStack(spacing: 8) {
            Button { flow.send(.back) } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Schließen")
            .accessibilityIdentifier("closeRoutes")
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
        let time = flow.customTime.map { $0.formatted(date: .omitted, time: .shortened) } ?? String(localized: "Jetzt")
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
                    if routes.removedLongDistance > 0 {
                        Label("Einige Verbindungen wurden ausgeblendet (Fernverkehr).", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.footnote)
                    }
                    AttributionFooter(attribution: routes.attribution)
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
                            HStack(spacing: 4) {
                                TimeText(date: leave)
                                Text(verbatim: "–")
                                TimeText(date: arrive)
                                if let leave, let arrive {
                                    Text(verbatim: "·")
                                    MinutesText(seconds: Int(arrive.timeIntervalSince(leave)))
                                }
                                Text(verbatim: "·")
                                Text("\(journey.transfers) Umstiege").monospacedDigit()
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

    @ViewBuilder private func countdown(leave: Date?, now: Date) -> some View {
        let minutes = leave.map { max(0, Int(($0.timeIntervalSince(now) / 60).rounded(.down))) }
        Group {
            if let minutes, minutes > 0 {
                Text("Los in \(minutes) Min.")
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
        if calibrated?.transfers.contains(where: \.isAtRisk) == true {
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
