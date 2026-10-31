import SwiftUI
import TransitCore

/// 3d Fahrtdetails: Zeitleiste im selben Sheet (Detent large), kein Push (DESIGN.md 3d).
struct TripDetailsSheet: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.dynamicTypeSize) private var typeSize
    let index: Int

    var body: some View {
        // Entscheidung B (30.10.): Standard-Navigationsleiste, NavigationStack nur im Sheet-Inhalt, ohne Push.
        // Einstellungen gehoeren nicht in die Fahrtdetails.
        NavigationStack {
            content
                .navigationTitle(Text("Details"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Verbindungen", systemImage: "chevron.backward") { flow.send(.back) }
                            .accessibilityLabel(Text(verbatim: "Zurück zu Verbindungen"))
                            .accessibilityIdentifier("backToRoutes")
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if let journey = flow.journey(at: index) {
            let calibrated = flow.calibratedJourney(at: index)
            ScrollView {
                VStack(spacing: 12) {
                    DetailsHeader(journey: journey, calibrated: calibrated)
                    if let sev = Spoken.sev(journey) {
                        CardHint(text: sev, symbol: "bus.fill", tone: .alert)
                    }
                    // Eine Karte fuer die ganze Zeitleiste (Figma), keine Listenzeilen mit Trennern.
                    JourneyTimelineCard(journey: journey, calibrated: calibrated, destination: flow.destination?.label)
                    if !journey.remarks.isEmpty {
                        ContentCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Meldungen des Betreibers").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(journey.remarks, id: \.self) { remark in
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            if let summary = remark.summary { Text(summary).font(.subheadline.weight(.semibold)) }
                                            Text(remark.text).font(.footnote)
                                        }
                                    } icon: {
                                        Image(systemName: remark.type == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                                            .foregroundStyle(remark.type == .warning ? Color(.statusWarn) : Color(.accentBlue))
                                    }
                                }
                            }
                        }
                    }
                    if let attribution = flow.routes?.attribution { AttributionFooter(attribution: attribution) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                // Daumenzone: "Erinnern" und "Starten" nebeneinander (Figma), ohne Leistenhintergrund;
                // safeAreaBar statt .background(.bar): nur der System-Scroll-Edge-Effekt hinter den Knoepfen.
                // Bei AX-Groessen untereinander, "Starten" (primaer) unten.
                let reminderTime = flow.reminderTime(forJourney: index)
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    SecondaryButton(title: reminderTime.map { "Erinnerung \($0.clockText)" } ?? "Erinnern",
                                    systemImage: reminderTime == nil ? "bell" : "bell.fill") { flow.reminderJourneyIndex = index }
                        // Eigene Breite: der Starten-Knopf darf "Erinnern" nicht zu einer schmalen, hohen Kapsel quetschen.
                        .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
                        .accessibilityIdentifier("remindButton")
                    PrimaryButton(title: "Starten", systemImage: "location.fill") { flow.send(.startNavigation(index)) }
                        .disabled(flow.blockedUntil != nil || journey.cancelled)
                        .accessibilityIdentifier("startButton")
                        .layoutPriority(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        } else {
            ContentUnavailableView("Verbindung nicht mehr vorhanden", systemImage: "tram")
        }
    }
}

/// Zeitleiste einer Verbindung in einer Karte; unterwegs mit ausgeklappter Wegbeschreibung (`expandWalks`).
struct JourneyTimelineCard: View {
    let journey: Journey
    let calibrated: CalibratedJourney?
    let destination: String?
    var expandWalks = false

    var body: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(journey.legs, id: \.index) { leg in
                    if leg.isWalk {
                        WalkTimelineRow(leg: leg, estimate: calibrated?.walks[leg.index], expanded: expandWalks)
                    } else {
                        VehicleTimeline(leg: leg)
                    }
                }
                if let last = journey.legs.last {
                    StationRow(time: calibrated?.arrivalAtDestination ?? last.arrival, planned: nil, name: destination,
                               platform: nil, plannedPlatform: nil, delayMinutes: nil, rail: nil, leg: nil)
                }
            }
        }
    }
}

/// Kopf laut Figma: "08:04 – 08:40" gross, darunter "36 Min. · 1 Umstieg".
private struct DetailsHeader: View {
    let journey: Journey
    let calibrated: CalibratedJourney?

    var body: some View {
        let leave = calibrated?.departureFromOrigin ?? journey.departure
        let arrive = calibrated?.arrivalAtDestination ?? journey.arrival
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                TimeText(date: leave)
                Text(verbatim: "–")
                TimeText(date: arrive)
            }
            .font(.title2.weight(.semibold))
            .fontDesign(.rounded)
            HStack(spacing: 4) {
                if let leave, let arrive { MinutesText(seconds: Int(arrive.timeIntervalSince(leave))) }
                Text(verbatim: "·")
                TransfersText(count: journey.transfers)
            }
            .font(.subheadline)
            .foregroundStyle(Color(.labelSecondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Schiene der Zeitleiste: Linienfarbe fuer Fahrten, gepunktet (mode/walk) fuer Fusswege.
private struct Rail: View {
    let color: Color
    let dotted: Bool

    var body: some View {
        GeometryReader { proxy in
            Path { p in
                p.move(to: CGPoint(x: proxy.size.width / 2, y: 0))
                p.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height))
            }
            .stroke(color, style: dotted
                    ? StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1, 6])
                    : StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        .frame(width: 12)
        .accessibilityHidden(true)
    }
}

/// Station mit Zeitspalte (geplant, Echtzeit darunter in status/warn) und Gleis "statt 10".
private struct StationRow: View {
    let time: Date?
    let planned: Date?
    let name: String?
    let platform: String?
    let plannedPlatform: String?
    let delayMinutes: Int?
    let rail: Leg?
    let leg: Leg?
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Geplante Zeit, Echtzeit darunter (status/warn). Bei AX-Groessen nebeneinander ueber dem Namen.
    @ViewBuilder private var times: some View {
        if let delayMinutes, delayMinutes > 0 {
            TimeText(date: planned ?? time).font(.subheadline.weight(.semibold))
            TimeText(date: time).font(.footnote).foregroundStyle(Color(.statusWarn))
        } else {
            TimeText(date: time).font(.subheadline.weight(.semibold))
        }
    }

    var body: some View {
        let ax = typeSize.isAccessibilitySize
        HStack(alignment: .top, spacing: 8) {
            if !ax {
                VStack(alignment: .trailing, spacing: 2) { times }
                    .frame(width: 56, alignment: .trailing)
            }
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(rail?.displayMode.color ?? Color(.modeWalk))
                .frame(width: 12)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // AX: Zeit ueber dem Stationsnamen statt schmaler Spalte (kein "08:" / "20").
                if ax { HStack(spacing: 8) { times } }
                Text(name ?? String(localized: "Ziel")).font(.subheadline.weight(.semibold))
                if let platform {
                    let changed = plannedPlatform != nil && plannedPlatform != platform
                    HStack(spacing: 4) {
                        Text("Gleis \(platform)").monospacedDigit()
                            .foregroundStyle(changed ? Color(.statusWarn) : .secondary)
                            .fontWeight(changed ? .semibold : .regular)
                        if changed, let plannedPlatform { Text("statt \(plannedPlatform)").foregroundStyle(.secondary) }
                    }
                    .font(.footnote)
                    .sensoryFeedback(.warning, trigger: changed) { _, now in now }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Spoken.station(time: time, name: name, platform: platform, plannedPlatform: plannedPlatform,
                                           delayMinutes: delayMinutes, leg: leg))
    }
}

/// Fahrt: Abfahrt, Linie, Zwischenhalte (aufklappbar), Ankunft.
private struct VehicleTimeline: View {
    let leg: Leg
    @State private var expanded = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let ax = typeSize.isAccessibilitySize
        StationRow(time: leg.departure, planned: leg.plannedDeparture, name: leg.origin.name, platform: leg.departurePlatform,
                   plannedPlatform: leg.plannedDeparturePlatform, delayMinutes: leg.departureDelayMinutes, rail: leg, leg: leg)
        HStack(alignment: .top, spacing: 8) {
            if !ax { Color.clear.frame(width: 56) }
            Rail(color: leg.displayMode.color, dotted: false)
            VStack(alignment: .leading, spacing: 6) {
                let line = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
                line {
                    LineBadge(leg: leg)
                    if let direction = leg.direction { Text("Richtung \(direction)").font(.footnote) }
                }
                if leg.cancelled {
                    CardHint(text: String(localized: "Fällt aus"), symbol: "xmark.octagon.fill", tone: .alert)
                }
                ForEach(leg.remarks ?? [], id: \.self) { remark in
                    CardHint(text: remark.summary ?? remark.text, symbol: "exclamationmark.bubble.fill",
                             tone: remark.type == .warning ? .alert : .warn)
                }
                let stops = leg.stopovers ?? []
                if !stops.isEmpty {
                    DisclosureGroup(isExpanded: $expanded.animation(Motion.micro)) {
                        ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in
                            HStack {
                                TimeText(date: stop.departure ?? stop.arrival).font(.footnote)
                                Text(stop.stop.name ?? "").font(.footnote)
                            }
                            .foregroundStyle(stop.cancelled ? Color(.statusAlert) : .secondary)
                            .accessibilityElement(children: .combine)
                        }
                    } label: {
                        Text("\(stops.count) Zwischenhalte").font(.footnote)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        StationRow(time: leg.arrival, planned: leg.plannedArrival, name: leg.destination.name, platform: leg.arrivalPlatform,
                   plannedPlatform: leg.plannedArrivalPlatform,
                   delayMinutes: leg.realtime ? (leg.arrivalDelaySeconds).flatMap { $0 >= 60 ? $0 / 60 : nil } : nil,
                   rail: leg, leg: nil)
    }
}

/// Fussweg: gepunktete Schiene, kalibrierte Gehzeit, Wegschritte (API v0.3).
private struct WalkTimelineRow: View {
    let leg: Leg
    let estimate: WalkEstimate?
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsAll: Bool
    init(leg: Leg, estimate: WalkEstimate?, expanded: Bool = false) {
        self.leg = leg; self.estimate = estimate; _showsAll = State(initialValue: expanded)
    }

    /// "12 Min. · 875 m" mit klarem Trennzeichen; "ca." solange nur die Fahrplanzeit vorliegt.
    private var walkHeader: some View {
        let minutes = Int((Double(estimate?.seconds ?? leg.durationSeconds ?? 0) / 60).rounded(.up))
        let meters = estimate?.distanceMeters ?? leg.distanceMeters
        let text = meters.map { String(localized: "\(minutes) Min. · \($0) m") } ?? String(localized: "\(minutes) Min.")
        return HStack(spacing: 4) {
            Image(systemName: "figure.walk").accessibilityHidden(true)
            Text(estimate == nil ? String(localized: "ca. \(text)") : text)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(Motion.micro, value: minutes)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Color(.modeWalk))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(estimate == nil ? String(localized: "Etwa ") : "")\(minutes) Minuten Fußweg"))
    }

    var body: some View {
        let ax = typeSize.isAccessibilitySize
        HStack(alignment: .top, spacing: 8) {
            // AX: keine schmale Spalte, Zeile untereinander statt in Silben gebrochen.
            if !ax { Color.clear.frame(width: 56) }
            Rail(color: Color(.modeWalk), dotted: true)
            VStack(alignment: .leading, spacing: 4) {
                let row = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
                row {
                    walkHeader
                    Text(leg.isTransfer == true ? "Umstieg" : "Fußweg").font(.footnote).foregroundStyle(.secondary)
                }
                if estimate != nil {
                    Text("An dein Gehtempo angepasst").font(.caption).foregroundStyle(Color(.labelSecondary))
                }
                // Wegbeschreibung eingeklappt (Figma); OSM-Teilstuecke und Treppen zusammengefasst.
                let all = WalkDirections.grouped(WalkDirections.condensed(leg.steps))
                if showsAll { ForEach(Array(all.indices), id: \.self) { WalkStepRow(line: all[$0]) } }
                if !all.isEmpty {
                    Button {
                        withAnimation(Motion.micro) { showsAll.toggle() }
                    } label: {
                        Label(showsAll ? String(localized: "Weniger Schritte") : String(localized: "Wegbeschreibung (\(all.count))"),
                              systemImage: showsAll ? "chevron.up" : "chevron.down")
                            .font(.footnote)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Ein Wegschritt: Richtungssymbol, Anweisung, Distanz. Abbiegungen und Ebenenwechsel hervorgehoben,
/// Geradeaus-Strecken ruhig ("Hüttenstraße folgen").
private struct WalkStepRow: View {
    let line: WalkDirections.Line
    private var step: Step { line.step }

    var body: some View {
        let maneuver = step.isManeuver
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: step.symbolName)
                .foregroundStyle(maneuver ? Color(.accentBlue) : Color(.labelSecondary))
                .frame(minWidth: 20)
                .accessibilityHidden(true)
            Text(NavigationPresenter.lineTitle(line))
                .fontWeight(maneuver ? .semibold : .regular)
                .foregroundStyle(maneuver ? Color.primary : Color(.labelSecondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let meters = step.distanceMeters {
                Text("\(meters) m")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Color(.labelSecondary))
            }
        }
        .font(.footnote)
        .frame(minHeight: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Spoken.line(line))
    }
}

#if DEBUG
// MARK: - Vorschau (Mock-Daten und Flow aus PreviewSupport.swift)

#Preview("Details, Störung, Hell", traits: .modifier(PreviewFlow.details(PreviewData.disrupted))) {
    PreviewSheetBackdrop { TripDetailsSheet(index: 0) }
}
#Preview("Details, Störung, Dunkel", traits: .modifier(PreviewFlow.details(PreviewData.disrupted))) {
    PreviewSheetBackdrop { TripDetailsSheet(index: 0) }.preferredColorScheme(.dark)
}
#Preview("Details, Störung, AX3", traits: .modifier(PreviewFlow.details(PreviewData.disrupted))) {
    PreviewSheetBackdrop { TripDetailsSheet(index: 0) }.dynamicTypeSize(.accessibility3)
}
#Preview("Details, kurz", traits: .modifier(PreviewFlow.details(PreviewData.short))) {
    PreviewSheetBackdrop { TripDetailsSheet(index: 0) }
}
#Preview("Details, lang", traits: .modifier(PreviewFlow.details(PreviewData.long))) {
    PreviewSheetBackdrop { TripDetailsSheet(index: 0) }
}
#Preview("Details, lang, AX3", traits: .modifier(PreviewFlow.details(PreviewData.long))) {
    PreviewSheetBackdrop { TripDetailsSheet(index: 0) }.dynamicTypeSize(.accessibility3)
}
/// Index ausserhalb der Antwort: Leerzustand "Verbindung nicht mehr vorhanden".
#Preview("Details, nicht mehr vorhanden", traits: .modifier(PreviewFlow.details(PreviewData.short))) {
    PreviewSheetBackdrop { TripDetailsSheet(index: 5) }
}

#Preview("Zeitleiste, lang, Wege offen") {
    ScrollView {
        if let journey = PreviewData.long?.journeys.first {
            JourneyTimelineCard(journey: journey, calibrated: nil, destination: "Flughafen Terminal", expandWalks: true)
                .padding(16)
        }
    }
    .background(Color(.surfaceSheet))
}
#Preview("Zeitleiste, Störung, Dunkel") {
    ScrollView {
        if let journey = PreviewData.disrupted?.journeys.first {
            JourneyTimelineCard(journey: journey, calibrated: nil, destination: "Köln Hbf").padding(16)
        }
    }
    .background(Color(.surfaceSheet))
    .preferredColorScheme(.dark)
}
#endif
