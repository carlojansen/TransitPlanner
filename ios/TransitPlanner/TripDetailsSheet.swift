import SwiftUI
import TransitCore

/// 3d Fahrtdetails: Zeitleiste im selben Sheet (Detent large), kein Push (DESIGN.md 3d).
struct TripDetailsSheet: View {
    @Environment(AppFlow.self) private var flow
    let index: Int

    var body: some View {
        if let journey = flow.journey(at: index) {
            let calibrated = flow.calibratedJourney(at: index)
            List {
                Section {
                    DetailsHeader(journey: journey, calibrated: calibrated)
                    if let sev = Spoken.sev(journey) {
                        CardHint(text: sev, symbol: "bus.fill", tone: .alert)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                Section {
                    ForEach(journey.legs, id: \.index) { leg in
                        if leg.isWalk {
                            WalkTimelineRow(leg: leg, estimate: calibrated?.walks[leg.index])
                        } else {
                            VehicleTimeline(leg: leg)
                        }
                    }
                    if let last = journey.legs.last {
                        StationRow(time: calibrated?.arrivalAtDestination ?? last.arrival, planned: nil, name: flow.destination?.label,
                                   platform: nil, plannedPlatform: nil, delayMinutes: nil, rail: nil, leg: nil)
                    }
                } footer: {
                    if let attribution = flow.routes?.attribution { AttributionFooter(attribution: attribution) }
                }
                if !journey.remarks.isEmpty {
                    Section("Meldungen des Betreibers") {
                        ForEach(journey.remarks, id: \.self) { remark in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let summary = remark.summary { Text(summary).font(.headline) }
                                    Text(remark.text).font(.subheadline)
                                }
                            } icon: {
                                Image(systemName: remark.type == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                                    .foregroundStyle(remark.type == .warning ? Color(.statusWarn) : Color(.accentBlue))
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            // Kompakt: keine grossen Leerflaechen ueber und zwischen Kopf, Hinweis und Zeitleiste.
            .listSectionSpacing(.compact)
            .contentMargins(.top, 0, for: .scrollContent)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Button("Verbindungen", systemImage: "chevron.backward") { flow.send(.back) }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("backToRoutes")
                    Spacer()
                    SettingsButton()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .safeAreaInset(edge: .bottom) {
                // Daumenzone: "Starten". "Erinnern" (D1) kommt mit Meilenstein 4.
                // Fussleiste mit Hintergrund: die Zeitleiste endet darueber und scrollt, nichts wird ueberdeckt.
                PrimaryButton(title: "Starten", systemImage: "location.fill") { flow.send(.startNavigation(index)) }
                    .disabled(flow.blockedUntil != nil || journey.cancelled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        } else {
            ContentUnavailableView("Verbindung nicht mehr vorhanden", systemImage: "tram")
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

    var body: some View {
        let ax = typeSize.isAccessibilitySize
        HStack(alignment: .top, spacing: 8) {
            // AX: keine schmale Spalte, Zeile untereinander statt in Silben gebrochen.
            if !ax { Color.clear.frame(width: 56) }
            Rail(color: Color(.modeWalk), dotted: true)
            VStack(alignment: .leading, spacing: 4) {
                let row = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
                row {
                    WalkChip(seconds: estimate?.seconds ?? leg.durationSeconds ?? 0, estimated: estimate == nil)
                    if let meters = estimate?.distanceMeters ?? leg.distanceMeters {
                        Text("\(meters) m").font(.footnote).monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .animation(Motion.micro, value: meters)
                    }
                    Text(leg.isTransfer == true ? "Umstieg" : "Fußweg").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(leg.steps.enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 6) {
                        Image(systemName: step.direction.symbolName).foregroundStyle(.secondary)
                        if let street = step.streetName { Text(street) }
                        if let from = step.fromLevel, let to = step.toLevel, from != to {
                            Text(to > from ? "Ebene hoch" : "Ebene runter")
                        }
                        Spacer(minLength: 0)
                        if let meters = step.distanceMeters { Text("\(meters) m").monospacedDigit() }
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Spoken.step(step))
                }
            }
            .padding(.vertical, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
