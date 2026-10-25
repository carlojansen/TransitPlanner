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
                if let sev = Spoken.sev(journey) {
                    CardHint(text: sev, symbol: "bus.fill", tone: .alert)
                        .listRowBackground(Color.clear)
                }
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
                PrimaryButton(title: "Starten", systemImage: "location.fill") { flow.send(.startNavigation(index)) }
                    .disabled(flow.blockedUntil != nil || journey.cancelled)
                    .padding(16)
            }
        } else {
            ContentUnavailableView("Verbindung nicht mehr vorhanden", systemImage: "tram")
        }
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                if let delayMinutes, delayMinutes > 0 {
                    TimeText(date: planned ?? time).font(.subheadline.weight(.semibold))
                    TimeText(date: time).font(.footnote).foregroundStyle(Color(.statusWarn))
                } else {
                    TimeText(date: time).font(.subheadline.weight(.semibold))
                }
            }
            .frame(width: 56, alignment: .trailing)
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(rail?.displayMode.color ?? Color(.modeWalk))
                .frame(width: 12)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
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

    var body: some View {
        StationRow(time: leg.departure, planned: leg.plannedDeparture, name: leg.origin.name, platform: leg.departurePlatform,
                   plannedPlatform: leg.plannedDeparturePlatform, delayMinutes: leg.departureDelayMinutes, rail: leg, leg: leg)
        HStack(alignment: .top, spacing: 8) {
            Color.clear.frame(width: 56)
            Rail(color: leg.displayMode.color, dotted: false)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Color.clear.frame(width: 56)
            Rail(color: Color(.modeWalk), dotted: true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
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
