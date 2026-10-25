import SwiftUI
import TransitCore

/// Schmaler Testbildschirm (RESEARCH-M3 "Reihenfolge 1a-e"): nur Systemkomponenten, kein Karten-Design.
struct RootView: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var flow = flow
        NavigationStack {
            ZStack {
                content
                    .id(flow.phase)
                    // Reduce Motion: nur Ueberblenden (AGENT.md 4.3.3); sonst gleitet der neue Zustand von rechts ein.
                    .transition(reduceMotion
                        ? .opacity
                        : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
            .animation(Motion.standard, value: flow.phase)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if flow.phase != .start {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Zurück", systemImage: "chevron.backward") { flow.send(.back) }
                                .accessibilityIdentifier("backButton")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Einstellungen", systemImage: "gearshape") { flow.showsSettings = true }
                            .accessibilityIdentifier("settingsButton")
                    }
                }
                .safeAreaInset(edge: .top) {
                    if let error = flow.banner, error.showsBanner {
                        InlineBanner(error: error)
                            .id(error) // neue Ansage fuer VoiceOver bei jedem Fehlerwechsel
                    }
                }
        }
        .sheet(isPresented: $flow.showsSettings) { SettingsSheet() }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    @ViewBuilder private var content: some View {
        switch flow.phase {
        case .start: StartView()
        case .search(let slot): SearchView(slot: slot)
        case .routeSelection: RouteListView()
        case .tripDetails(let index): TripDetailsView(index: index)
        case .navigation:
            ContentUnavailableView {
                Label("Navigation folgt", systemImage: "location.north.line")
            } description: {
                Text("Die Wegführung kommt in einer späteren Etappe.")
            } actions: {
                Button("Angekommen") { flow.send(.arrived) }.buttonStyle(.borderedProminent)
                Button("Beenden") { flow.send(.back) }
            }
        case .arrival:
            ContentUnavailableView {
                Label("Angekommen", systemImage: "flag.checkered")
            } actions: {
                Button("Fertig") { flow.send(.reset) }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var title: LocalizedStringKey {
        switch flow.phase {
        case .start: "Fahrt planen"
        case .search(.origin): "Start suchen"
        case .search(.destination): "Ziel suchen"
        case .routeSelection: "Verbindungen"
        case .tripDetails: "Fahrtdetails"
        case .navigation: "Navigation"
        case .arrival: "Ankunft"
        }
    }
}

// MARK: - Start (Von/Nach, Zeit)

private struct StartView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        @Bindable var flow = flow
        List {
            Section {
                endpointRow(.origin, title: "Von", id: "originRow")
                endpointRow(.destination, title: "Nach", id: "destinationRow")
                Button("Start und Ziel tauschen", systemImage: "arrow.up.arrow.down") { flow.swapEndpoints() }
                    .disabled(flow.origin == nil && flow.destination == nil)
            }
            Section("Zeit") {
                Picker("Zeitbezug", selection: $flow.isArrivalTime) {
                    Text("Abfahrt").tag(false)
                    Text("Ankunft").tag(true)
                }
                .pickerStyle(.segmented)
                if let time = flow.customTime {
                    DatePicker("Zeit", selection: Binding { time } set: { flow.customTime = $0 })
                    Button("Jetzt") { flow.customTime = nil }
                } else {
                    Button("Zeit wählen (jetzt)", systemImage: "clock") { flow.customTime = Date() }
                }
            }
            Section {
                Button("Verbindungen suchen", systemImage: "magnifyingglass") { flow.send(.planTapped) }
                    .disabled(!flow.canPlan)
                    .accessibilityIdentifier("planButton")
            } footer: {
                Text("Mit einer Haltestelle als Start erfährt der Server nicht, wo du gerade bist.")
            }
        }
    }

    private func endpointRow(_ slot: EndpointSlot, title: LocalizedStringKey, id: String) -> some View {
        Button { flow.send(.editEndpoint(slot)) } label: {
            LabeledContent(title) {
                if let endpoint = flow.endpoint(slot) {
                    Text(endpoint.label).foregroundStyle(.primary)
                } else {
                    Text("Wählen").foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Suche mit Pflichtschalter

private struct SearchView: View {
    @Environment(AppFlow.self) private var flow
    let slot: EndpointSlot
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var flow = flow
        List {
            Section {
                Picker("Suchmodus", selection: Binding { flow.scope } set: { flow.setScope($0) }) {
                    Text("Adresse").tag(SearchScope.address)
                    Text("Haltestelle").tag(SearchScope.stops)
                }
                .pickerStyle(.segmented)
                TextField(flow.scope == .stops ? "Haltestelle suchen" : "Adresse oder Ort", text: $flow.query)
                    // Im Haltestellenmodus keine eigenen Adressen vorschlagen, sie gingen sonst als Suchtext ans Backend.
                    .textContentType(flow.scope == .address ? .fullStreetAddress : nil)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .onSubmit { flow.submitSearch() }
                    .accessibilityIdentifier("searchField")
            } footer: {
                if flow.scope == .stops {
                    Label("Der Suchtext geht ohne Standort an den Fahrplan-Server.", systemImage: "info.circle")
                } else {
                    Label("Adressen werden nur mit Apple Karten auf dem Gerät gesucht.", systemImage: "lock")
                }
            }

            results
        }
        .onChange(of: flow.query) {
            if flow.query.count > AppFlow.maxQueryLength { flow.query = String(flow.query.prefix(AppFlow.maxQueryLength)) }
            flow.queryChanged()
        }
        .onAppear { focused = true }
    }

    @ViewBuilder private var results: some View {
        let r = flow.results
        // Alte Treffer bleiben waehrend des Tippens stehen; der Spinner erscheint nur ohne Treffer.
        if flow.scope == .address, !r.addresses.isEmpty {
            Section("Adressen") {
                ForEach(r.addresses, id: \.self) { a in
                    Button { flow.choose(.coordinate(a.coordinate, label: a.name)) } label: {
                        VStack(alignment: .leading) {
                            Text(a.name)
                            if let subtitle = a.subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("searchResult")
                }
            }
        } else if flow.scope == .stops, !r.stops.isEmpty {
            Section {
                ForEach(r.stops, id: \.self) { stop in
                    if let id = stop.id, let name = stop.name {
                        Button { flow.choose(.stop(id: id, label: name)) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(name)
                                    if let area = stop.area { Text(area).font(.footnote).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                ModeSymbols(modes: stop.modes ?? [])
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("searchResult")
                    }
                }
            } header: {
                Text("Haltestellen")
            } footer: {
                if let attribution = r.attribution { AttributionFooter(attribution: attribution) }
            }
        } else if flow.isSearching {
            Section { ProgressView().frame(maxWidth: .infinity) }
        } else if flow.query.trimmingCharacters(in: .whitespaces).count >= 2, flow.banner == nil {
            ContentUnavailableView.search(text: flow.query)
        }
    }
}

// MARK: - Verbindungsliste

private struct RouteListView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        List {
            Section {
                LabeledContent("Von", value: flow.origin?.label ?? "")
                LabeledContent("Nach", value: flow.destination?.label ?? "")
            }
            if flow.banner == .noConnections {
                ContentUnavailableView {
                    Label("Keine Verbindung gefunden", systemImage: "tram")
                } description: {
                    Text("Andere Zeit oder andere Haltestelle versuchen.")
                } actions: {
                    Button("Neu suchen") { flow.send(.back) }
                }
            } else if let routes = flow.routes {
                journeys(routes)
            } else if flow.isPlanning {
                Section {
                    Label("Verbindungen werden gesucht", systemImage: "tram.fill")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
            }
        }
    }

    @ViewBuilder private func journeys(_ routes: RoutesResponse) -> some View {
        Section {
            if routes.walkOnly {
                Label("Start und Ziel liegen nah beieinander. Zu Fuß bist du am schnellsten.", systemImage: "figure.walk")
            }
            ForEach(Array(routes.journeys.enumerated()), id: \.offset) { index, journey in
                Button { flow.send(.journeySelected(index)) } label: {
                    JourneyRow(journey: journey, calibrated: flow.calibratedJourney(at: index))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("journeyRow")
            }
        } header: {
            if flow.calibrated == nil, flow.isPlanning {
                Label("Gehzeiten werden mit Apple Karten berechnet", systemImage: "figure.walk")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if routes.removedLongDistance > 0 {
                    Text("Einige Verbindungen wurden ausgeblendet (Fernverkehr).")
                }
                AttributionFooter(attribution: routes.attribution)
            }
        }
    }
}

private struct JourneyRow: View {
    let journey: Journey
    let calibrated: CalibratedJourney?

    var body: some View {
        let leave = calibrated?.departureFromOrigin ?? journey.departure
        let arrive = calibrated?.arrivalAtDestination ?? journey.arrival
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                TimeText(date: leave)
                Text(verbatim: "–")
                TimeText(date: arrive)
                Spacer()
                if let leave, let arrive {
                    MinutesText(seconds: Int(arrive.timeIntervalSince(leave)))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.headline)
            HStack(spacing: 8) {
                ForEach(journey.legs.filter { !$0.isWalk }, id: \.index) { leg in
                    LineBadge(leg: leg)
                }
            }
            HStack(spacing: 12) {
                if let walk = calibrated?.walks.values.reduce(0, { $0 + $1.seconds }), walk > 0 {
                    Label { MinutesText(seconds: walk) } icon: { Image(systemName: "figure.walk") }
                }
                Label { Text("\(journey.transfers) Umstiege").monospacedDigit().contentTransition(.numericText()) } icon: { Image(systemName: "arrow.triangle.swap") }
                if calibrated?.transfers.contains(where: \.isAtRisk) == true {
                    Label("Umstieg knapp", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if journey.cancelled {
                    Label("Fällt aus", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Spoken.journey(journey, calibrated: calibrated, now: Date()))
    }
}

// MARK: - Fahrtdetails (Zustand, kein Push)

private struct TripDetailsView: View {
    @Environment(AppFlow.self) private var flow
    let index: Int

    var body: some View {
        if let journey = flow.journey(at: index) {
            let calibrated = flow.calibratedJourney(at: index)
            List {
                ForEach(journey.legs, id: \.index) { leg in
                    Section {
                        if leg.isWalk {
                            WalkLegView(leg: leg, estimate: calibrated?.walks[leg.index])
                        } else {
                            VehicleLegView(leg: leg)
                        }
                    }
                }
                if !journey.remarks.isEmpty {
                    Section("Meldungen") {
                        ForEach(journey.remarks, id: \.self) { remark in
                            Label {
                                VStack(alignment: .leading) {
                                    if let summary = remark.summary { Text(summary).font(.headline) }
                                    Text(remark.text)
                                }
                            } icon: {
                                Image(systemName: remark.type == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                            }
                        }
                    }
                }
                Section {
                    Button("Navigation starten", systemImage: "location.fill") { flow.send(.startNavigation) }
                        .buttonStyle(.borderedProminent)
                } footer: {
                    if let attribution = flow.routes?.attribution { AttributionFooter(attribution: attribution) }
                }
            }
        } else {
            ContentUnavailableView("Verbindung nicht mehr vorhanden", systemImage: "tram")
        }
    }
}

private struct WalkLegView: View {
    let leg: Leg
    let estimate: WalkEstimate?

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(leg.isTransfer == true ? "Umstieg zu Fuß" : "Fußweg")
                HStack(spacing: 8) {
                    if let seconds = estimate?.seconds ?? leg.durationSeconds { MinutesText(seconds: seconds) }
                    if let meters = estimate?.distanceMeters ?? leg.distanceMeters {
                        Text("\(meters) m").monospacedDigit().contentTransition(.numericText())
                    }
                    if estimate?.source == .appleMaps { Text("Apple Karten") }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .animation(Motion.micro, value: estimate)
            }
        } icon: {
            Image(systemName: "figure.walk")
        }
        ForEach(Array(leg.steps.enumerated()), id: \.offset) { _, step in
            StepRow(step: step)
        }
    }
}

private struct StepRow: View {
    let step: Step

    var body: some View {
        Label {
            HStack {
                if let street = step.streetName { Text(street) }
                if let from = step.fromLevel, let to = step.toLevel, from != to {
                    Text(to > from ? "Ebene hoch" : "Ebene runter")
                    Text("\(from, format: .number) zu \(to, format: .number)").monospacedDigit()
                }
                Spacer()
                if let meters = step.distanceMeters { Text("\(meters) m").monospacedDigit() }
            }
            .font(.footnote)
        } icon: {
            Image(systemName: step.direction.symbolName).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Spoken.step(step))
    }
}

private struct VehicleLegView: View {
    let leg: Leg

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                LineBadge(leg: leg)
                if let direction = leg.direction { Text("Richtung \(direction)").lineLimit(2) }
            }
            if leg.replacement {
                Label("Ersatzverkehr", systemImage: "bus.fill").foregroundStyle(.orange)
            }
            stopLine(name: leg.origin.name, time: leg.departure, delay: leg.departureDelaySeconds,
                     platform: leg.departurePlatform, changed: leg.platformChanged == true)
            stopLine(name: leg.destination.name, time: leg.arrival, delay: leg.arrivalDelaySeconds,
                     platform: leg.arrivalPlatform, changed: false)
            if leg.cancelled {
                Label("Fällt aus", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            ForEach(leg.remarks ?? [], id: \.self) { remark in
                Label(remark.summary ?? remark.text, systemImage: "exclamationmark.bubble").font(.footnote)
            }
        }
    }

    private func stopLine(name: String?, time: Date?, delay: Int?, platform: String?, changed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            TimeText(date: time)
            if let delay, delay >= 60 {
                Text("+\(delay / 60)").monospacedDigit().contentTransition(.numericText()).foregroundStyle(.orange)
                    .accessibilityLabel(Text("\(delay / 60) Minuten später"))
            }
            Text(name ?? "")
            Spacer()
            if let platform {
                Label {
                    Text("Gleis \(platform)").monospacedDigit()
                } icon: {
                    if changed { Image(systemName: "exclamationmark.triangle.fill") }
                }
                .foregroundStyle(changed ? .orange : .secondary)
                .labelStyle(.titleAndIcon)
            }
        }
        .font(.subheadline)
    }
}

// MARK: - Bausteine

struct TimeText: View {
    let date: Date?

    var body: some View {
        Group {
            if let date { Text(date, format: .dateTime.hour().minute()) } else { Text(verbatim: "--:--") }
        }
        .monospacedDigit()
        .contentTransition(.numericText())
        .animation(Motion.micro, value: date)
    }
}

struct MinutesText: View {
    let seconds: Int

    var body: some View {
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        Text("\(minutes) min")
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(Motion.micro, value: minutes)
    }
}

struct LineBadge: View {
    let leg: Leg

    var body: some View {
        Label(leg.line?.name ?? leg.mode.displayName, systemImage: leg.mode.symbolName)
            .font(.subheadline.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .symbolRenderingMode(.hierarchical)
    }
}

struct ModeSymbols: View {
    let modes: [TransitMode]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Set(modes.map(\.symbolName))).sorted(), id: \.self) { Image(systemName: $0) }
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

extension TransitMode {
    var symbolName: String {
        switch self {
        case .walk: "figure.walk"
        case .tram: "tram.fill"
        case .bus, .onDemand: "bus.fill"
        case .subway: "tram.fill.tunnel"
        case .suburban, .regional, .regionalExpress, .national, .nationalExpress: "train.side.front.car"
        case .ferry: "ferry.fill"
        case .funicular, .aerialLift: "cablecar.fill"
        case .airplane: "airplane"
        case .other, .unknown: "questionmark.circle"
        }
    }

    var displayName: String {
        switch self {
        case .walk: String(localized: "Fußweg")
        case .tram: String(localized: "Straßenbahn")
        case .bus: String(localized: "Bus")
        case .onDemand: String(localized: "Rufbus")
        case .subway: String(localized: "U-Bahn")
        case .suburban: String(localized: "S-Bahn")
        case .regional, .regionalExpress: String(localized: "Regionalzug")
        case .national, .nationalExpress: String(localized: "Fernzug")
        case .ferry: String(localized: "Fähre")
        case .funicular: String(localized: "Standseilbahn")
        case .aerialLift: String(localized: "Seilbahn")
        case .airplane: String(localized: "Flugzeug")
        case .other, .unknown: String(localized: "Verkehrsmittel")
        }
    }
}

extension Step.Direction {
    var symbolName: String {
        switch self {
        case .depart: "figure.walk.departure"
        case .continue, .unknown: "arrow.up"
        case .left, .hardLeft: "arrow.turn.up.left"
        case .slightlyLeft: "arrow.up.left"
        case .right, .hardRight: "arrow.turn.up.right"
        case .slightlyRight: "arrow.up.right"
        case .uturnLeft: "arrow.uturn.left"
        case .uturnRight: "arrow.uturn.right"
        case .circleClockwise: "arrow.clockwise"
        case .circleCounterclockwise: "arrow.counterclockwise"
        case .stairs: "figure.stairs"
        case .elevator: "arrow.up.and.down.square"
        }
    }
}

// MARK: - VoiceOver-Saetze (AGENT.md 4.3.3, RESEARCH-M3 Abschnitt 9)

enum Spoken {
    /// z. B. "In 7 Minuten losgehen. Losgehen um 7:12. Ankunft 7:54. Straßenbahn STR 704, dann Bus SEV RE 5. 1 Umstieg. Mit Ersatzverkehr."
    static func journey(_ journey: Journey, calibrated: CalibratedJourney?, now: Date) -> String {
        var parts: [String] = []
        if let leave = calibrated?.departureFromOrigin ?? journey.departure {
            let time = leave.formatted(date: .omitted, time: .shortened)
            let minutes = Int((leave.timeIntervalSince(now) / 60).rounded(.down))
            if minutes > 0 { parts.append(String(localized: "In \(minutes) Minuten losgehen") + ".") }
            parts.append(String(localized: "Losgehen um \(time)."))
        }
        if let arrive = calibrated?.arrivalAtDestination ?? journey.arrival {
            parts.append(String(localized: "Ankunft \(arrive.formatted(date: .omitted, time: .shortened))."))
        }
        let vehicles = journey.legs.filter { !$0.isWalk }.map { leg in
            [leg.mode.displayName, leg.line?.name].compactMap { $0 }.joined(separator: " ")
        }
        if !vehicles.isEmpty {
            parts.append(vehicles.joined(separator: String(localized: ", dann ")) + ".")
        }
        parts.append(String(localized: "\(journey.transfers) Umstiege") + ".")
        if journey.legs.contains(where: \.replacement) { parts.append(String(localized: "Mit Ersatzverkehr.")) }
        if calibrated?.transfers.contains(where: \.isAtRisk) == true { parts.append(String(localized: "Umstieg knapp.")) }
        if journey.cancelled { parts.append(String(localized: "Fällt aus.")) }
        return parts.joined(separator: " ")
    }

    /// z. B. "Treppe, nach unten, Ebene 1 zu 0, 20 Meter."
    static func step(_ step: Step) -> String {
        var parts = [step.direction.spokenName]
        if let street = step.streetName { parts.append(street) }
        if let from = step.fromLevel, let to = step.toLevel, from != to {
            parts.append(to > from ? String(localized: "nach oben") : String(localized: "nach unten"))
            parts.append(String(localized: "Ebene \(from.formatted(.number)) zu \(to.formatted(.number))"))
        }
        if let meters = step.distanceMeters { parts.append(String(localized: "\(meters) Meter")) }
        return parts.joined(separator: ", ") + "."
    }
}

extension Step.Direction {
    var spokenName: String {
        switch self {
        case .depart: String(localized: "Losgehen")
        case .continue: String(localized: "Geradeaus")
        case .left: String(localized: "Links abbiegen")
        case .slightlyLeft: String(localized: "Leicht links")
        case .hardLeft: String(localized: "Scharf links")
        case .right: String(localized: "Rechts abbiegen")
        case .slightlyRight: String(localized: "Leicht rechts")
        case .hardRight: String(localized: "Scharf rechts")
        case .uturnLeft, .uturnRight: String(localized: "Wenden")
        case .circleClockwise, .circleCounterclockwise: String(localized: "Im Kreisverkehr")
        case .stairs: String(localized: "Treppe")
        case .elevator: String(localized: "Aufzug")
        case .unknown: String(localized: "Weiter")
        }
    }
}
