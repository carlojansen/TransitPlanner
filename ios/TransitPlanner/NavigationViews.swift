import SwiftUI
import TransitCore

extension AppFlow {
    /// Eingabe fuer den Presenter aus dem aktuellen Navigationsstand.
    var navInput: NavigationPresenter.Input? {
        guard let step = navStep, let journey = navJourney, let geometry = navGeometry else { return nil }
        return NavigationPresenter.Input(step: step, journey: journey, geometry: geometry, walks: navWalks,
                                         position: navPosition, now: navNow, pace: pace,
                                         destinationLabel: destination?.label ?? String(localized: "Ziel"),
                                         startedAt: navStartedAt, expired: navExpired)
    }

    /// Halt, auf den die Navigation zulaeuft (Gleis-Pin auf der Karte).
    var navTargetStop: (place: Place, platform: String?)? {
        guard let step = navStep, let v = NavigationEngine.targetVehicle(step),
              let leg = navJourney?.legs.first(where: { $0.index == v }) else { return nil }
        return (leg.origin, leg.departurePlatform)
    }
}

/// Jetzt-Karte (DESIGN.md C): Glass ueber der Karte, Radius 22, 16 pt Rand, Innenabstand 16, Abstand 6.
struct NowCardView: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.dynamicTypeSize) private var typeSize
    let card: NowCard
    /// AX: hoechstens dieser Anteil des Bildschirms, darueber scrollt die Karte (Sheet und Karte bleiben sichtbar).
    let maxScrollHeight: CGFloat

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            Text(card.eyebrow)
                .textCase(.uppercase)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(.labelSecondary))
            // App/Anweisung: in allen Zustaenden gleich, 28 pt rounded bold, nicht groesser.
            if let maneuver = card.maneuver {
                ManeuverBanner(maneuver: maneuver)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { headline; badge }
                    VStack(alignment: .leading, spacing: 4) { headline; badge }
                }
            }
            if !card.context.isEmpty {
                Text(card.context).font(.subheadline).foregroundStyle(Color(.labelSecondary))
            }
            metrics
            if let hint = card.hint {
                VStack(alignment: .leading, spacing: 6) {
                    CardHint(text: hint.text, symbol: hint.symbol, tone: hint.tone)
                    if hint.action == .nextConnection {
                        Button("Nächste Verbindung", systemImage: "arrow.triangle.branch") { flow.nextConnection() }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("nextConnection")
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)

        Group {
            // AX: Karte scrollt statt abzuschneiden.
            if typeSize.isAccessibilitySize {
                ScrollView { content }.frame(maxHeight: maxScrollHeight)
            } else {
                content
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowCard")
    }

    private var headline: some View {
        Text(card.headline)
            .font(.title.bold())
            .fontDesign(.rounded)
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: true))
            .animation(Motion.micro, value: card.headline)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(card.spokenHeadline ?? card.headline)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var badge: some View {
        if let leg = card.badgeLeg { LineBadge(leg: leg) }
    }

    /// Genau drei Zahlen, Kennzahl-Stil; bei AX untereinander.
    private var metrics: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            ForEach(Array(card.metrics.enumerated()), id: \.offset) { _, metric in
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.label).font(.caption).foregroundStyle(Color(.labelSecondary))
                    MetricValueText(value: metric.value)
                }
                .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Gehen: Richtungssymbol links, Meter gross, Anweisung darunter, optional "Danach". Treppen in Orange.
private struct ManeuverBanner: View {
    let maneuver: NowCard.Maneuver
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let tint = maneuver.isStairs ? Color(.statusWarn) : Color(.accentBlue)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            Image(systemName: maneuver.symbol)
                .font(.title.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 56, height: 56)
                .background(tint.opacity(0.15), in: .rect(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(maneuver.meters) m")
                    .font(.title.bold()).fontDesign(.rounded).monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Motion.micro, value: maneuver.meters)
                Text(maneuver.title.prefix(1).uppercased() + maneuver.title.dropFirst())
                    .font(.headline)
                if let then = maneuver.then {
                    Text(then).font(.subheadline).foregroundStyle(Color(.labelSecondary))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// App/Kennzahl: 22 pt semibold rounded, feste Ziffern, rollende Zahlen.
private struct MetricValueText: View {
    let value: NowCard.Value

    var body: some View {
        Group {
            switch value {
            case .time(let date):
                if let date { Text(date, format: .clock) } else { Text(verbatim: "–") }
            case .minutes(let m):
                Text(DurationLabel.short(minutes: m))
            case .buffer(let seconds, let status):
                Group {
                    if status == .missed {
                        Text("reicht nicht")
                    } else if seconds < 120 {
                        Text("\(seconds) s")
                    } else {
                        Text(DurationLabel.short(minutes: seconds / 60))
                    }
                }
                .foregroundStyle(status.color)
            case .meters(let m):
                if let m { Text("\(m) m") } else { Text(verbatim: "–") }
            case .text(let t):
                Text(t)
            }
        }
        .font(.title2.weight(.semibold))
        .fontDesign(.rounded)
        .monospacedDigit()
        .contentTransition(.numericText(countsDown: true))
        .animation(Motion.micro, value: value)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension WalkBuffer.Status {
    var color: Color {
        switch self {
        case .comfortable: Color(.statusOk)
        case .tight: Color(.statusWarn)
        case .missed: Color(.statusAlert)
        }
    }
}

/// Wunsch an die Karte: diesen Punkt zeigen. `id` macht erneutes Antippen derselben Zeile zu einer Aenderung.
struct NavMapFocus: Equatable {
    let coordinate: GeoCoordinate
    let id = UUID()
}

extension WalkBuffer.Status {
    /// Symbol zur Farbe (Farbe ist nie die einzige Information).
    var symbolName: String {
        switch self {
        case .comfortable: "checkmark.circle.fill"
        case .tight: "exclamationmark.triangle.fill"
        case .missed: "xmark.octagon.fill"
        }
    }
}

/// Danach-Sheet: Restfahrt ab jetzt (aktuelle Etappe zuerst, erledigte weg), Puffer an jedem Umstieg, engste Stelle
/// im Kopf. Kompakt: aktuelle und naechste Etappe; mittel: alles. "Beenden" als Text (4f: "Fertig").
struct NavigationSheet: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Kompakter Detent: Kopf, engste Stelle, aktuelle und naechste Etappe.
    static let compactHeight: CGFloat = 256

    var body: some View {
        if flow.peek != nil { AlternativesView() } else if flow.navMapOnly { mapBar } else { full }
    }

    /// Karte frei: eine Leiste mit dem Weg zurueck zur Anweisung (Daumenzone).
    private var mapBar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(Motion.standard) { flow.navMapOnly = false }
            } label: {
                Label("Anweisung", systemImage: "list.bullet")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .accessibilityHint("Zeigt wieder die aktuelle Anweisung")
            .accessibilityIdentifier("backToInstruction")
            endButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    @ViewBuilder private var full: some View {
        let overview = flow.phase == .arrival ? nil : flow.navInput.map(NavigationPresenter.overview)
        let rows = overview?.rows ?? []
        // Kopf fest, damit ein Zug am Kopf das Sheet vergroessert; bei AX-Groessen scrollt er mit, sonst wuerde er im
        // kompakten Detent gestaucht und ueberdeckt.
        // Hochgezogen auf large (Hochwischen): die ganze Fahrt wie in den Fahrtdetails, mit Wegbeschreibung.
        GeometryReader { proxy in
            let tall = proxy.size.height > 600 && flow.navJourney != nil
            if typeSize.isAccessibilitySize {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) { top(overview); body(rows, tall: tall) }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    top(overview)
                    ScrollView { body(rows, tall: tall) }
                }
            }
        }
    }

    @ViewBuilder private func body(_ rows: [RouteOverview.Row], tall: Bool) -> some View {
        if tall, let journey = flow.navJourney {
            JourneyTimelineCard(journey: journey, calibrated: nil, destination: flow.destination?.label, expandWalks: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        } else {
            list(rows)
        }
    }

    @ViewBuilder private func top(_ overview: RouteOverview?) -> some View {
        // AX: Kopf untereinander statt abgeschnitten.
        ViewThatFits(in: .horizontal) {
            HStack { header(overview); Spacer(); stale; mapButton; endButton }
            VStack(alignment: .leading, spacing: 4) { header(overview); stale; mapButton; endButton }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        if flow.phase != .arrival { compareButton(tight: overview?.tightest != nil).padding(.horizontal, 16) }
        if let tightest = overview?.tightest {
            tightestButton(tightest).padding(.horizontal, 16)
        }
    }

    private func list(_ rows: [RouteOverview.Row]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                Button {
                    if let c = row.coordinate { flow.navFocus = NavMapFocus(coordinate: c) }
                } label: {
                    OverviewRowView(row: row)
                }
                .buttonStyle(.plain)
                .disabled(row.coordinate == nil)
                .accessibilityLabel(row.spoken)
                .accessibilityHint("Zeigt die Stelle auf der Karte")
                .accessibilityIdentifier("overviewRow")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 16)
        .animation(Motion.standard, value: rows.map(\.id))
    }

    @ViewBuilder private func header(_ overview: RouteOverview?) -> some View {
        if let overview {
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if let arrival = overview.arrival {
                        Text("Ankunft \(arrival, format: .clock)")
                    } else {
                        Text("Restfahrt")
                    }
                }
                .font(.headline)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(Motion.micro, value: overview.arrival)
                Text("\(overview.rows.count) Etappen")
                    .font(.subheadline)
                    .foregroundStyle(Color(.labelSecondary))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Motion.micro, value: overview.rows.count)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(NavigationPresenter.spokenHeader(overview))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("overviewHeader")
        } else {
            title
        }
    }

    /// "Engster Umstieg: Köln Messe/Deutz, 20 s": Symbol + Text in Statusfarbe; Tippen zeigt den Halt auf der Karte.
    private func tightestButton(_ t: RouteOverview.Tightest) -> some View {
        Button {
            if let c = t.coordinate { flow.navFocus = NavMapFocus(coordinate: c) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: t.buffer.status.symbolName).accessibilityHidden(true)
                Text(NavigationPresenter.tightestText(t))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(t.buffer.status.color)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(Motion.micro, value: t.buffer)
        .accessibilityLabel(NavigationPresenter.tightestText(t, spoken: true))
        .accessibilityHint("Zeigt die Stelle auf der Karte")
        .accessibilityIdentifier("tightestTransfer")
    }

    private var title: some View {
        Text(flow.phase == .arrival ? "Gut angekommen" : "Restfahrt")
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var stale: some View {
        if flow.navIsStale {
            Label("Echtzeit pausiert", systemImage: "pause.circle")
                .font(.footnote)
                .foregroundStyle(Color(.statusWarn))
        }
    }

    /// Dauerhafter Einstieg in den Vergleich; bei engem Umstieg in Warnfarbe. Die Fahrt laeuft weiter.
    private func compareButton(tight: Bool) -> some View {
        let tone: Tone = tight ? .warn : .info
        return Button {
            withAnimation(Motion.standard) { flow.openAlternatives() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").accessibilityHidden(true)
                Text(tight ? "Knapp: Alternativen vergleichen" : "Alternativen vergleichen")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(tone.tint, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Zeigt andere Verbindungen, die Fahrt läuft weiter")
        .accessibilityIdentifier("alternativesButton")
    }

    /// Karte ganz sehen: blendet Jetzt-Karte und Liste aus.
    @ViewBuilder private var mapButton: some View {
        if flow.phase != .arrival {
            Button {
                withAnimation(Motion.standard) { flow.navMapOnly = true }
            } label: {
                Label("Karte", systemImage: "map")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityHint("Zeigt die Karte ohne Anweisung")
            .accessibilityIdentifier("mapOnly")
        }
    }

    private var endButton: some View {
        Button(flow.phase == .arrival ? "Fertig" : "Beenden") {
            flow.send(flow.phase == .arrival ? .reset : .back)
        }
        .font(.body.weight(.semibold))
        .frame(minHeight: 44)
        .accessibilityIdentifier("endNavigation")
    }
}

/// Eine Etappe: Zeit, Linien-Badge bzw. Symbol, Ziel/Halt, Gleis; bei Umstiegen der Puffer mit Symbol und Text.
private struct OverviewRowView: View {
    let row: RouteOverview.Row
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // AX: Zeit ueber dem Inhalt statt daneben, damit der Text die volle Breite bekommt.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            TimeText(date: row.time)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let leg = row.leg {
                        LineBadge(leg: leg)
                    } else {
                        Image(systemName: row.kind == .transfer ? "arrow.triangle.swap" : "figure.walk")
                            .foregroundStyle(Color(.modeWalk))
                    }
                    Text(row.title)
                        .font(.subheadline.weight(row.isCurrent ? .semibold : .regular))
                        .fixedSize(horizontal: false, vertical: true)
                    if let delay = row.leg?.departureDelayMinutes { DelayBadge(minutes: delay) }
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.footnote)
                        .foregroundStyle(Color(.labelSecondary))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let buffer = row.buffer {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: buffer.status.symbolName)
                        Text(NavigationPresenter.bufferLabel(buffer))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(buffer.status.color)
                    .animation(Motion.micro, value: buffer)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        // Aktuelle Etappe: Flaeche und halbfette Zeile; erledigte stehen nicht mehr in der Liste.
        .background(row.isCurrent ? Color(.accentBlueTint) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect)
    }
}

/// Vergleich unterwegs: andere Verbindungen neben der laufenden Fahrt, mit Zeitunterschied. Start am Standort oder an der
/// naechsten Station (Umschalter). "Zurück zur Fahrt" bringt die laufende Fahrt wieder; ein Wechsel braucht eine Bestaetigung.
struct AlternativesView: View {
    @Environment(AppFlow.self) private var flow
    @State private var chosen: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    withAnimation(Motion.standard) { flow.closeAlternatives() }
                } label: {
                    Label("Zurück zur Fahrt", systemImage: "chevron.backward")
                        .font(.body.weight(.semibold))
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .accessibilityIdentifier("backToTrip")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            originPicker.padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) { current; content }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .confirmationDialog("Zu dieser Verbindung wechseln?", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                            titleVisibility: .visible) {
            Button("Wechseln") { if let chosen { flow.chooseAlternative(chosen) } }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    /// Umschalter: ab aktueller Position oder ab der naechsten Station (z. B. "Köln Messe/Deutz").
    private var originPicker: some View {
        let next = flow.nextStation
        return VStack(alignment: .leading, spacing: 4) {
            Picker("Alternativen ab", selection: Binding {
                flow.peekOrigin
            } set: { flow.openAlternatives(from: $0) }) {
                Text("Mein Standort").tag(AppFlow.PeekOrigin.position)
                Text("Nächste Station").tag(AppFlow.PeekOrigin.nextStation)
            }
            .pickerStyle(.segmented)
            .disabled(next == nil)
            .accessibilityIdentifier("peekOrigin")
            if flow.peekOrigin == .nextStation, let next {
                Text("Ab \(next.name), \(next.time, format: .clock)")
                    .font(.footnote)
                    .foregroundStyle(Color(.labelSecondary))
            }
        }
    }

    /// Referenz: die laufende Fahrt mit Ankunft.
    @ViewBuilder private var current: some View {
        if let journey = flow.navJourney {
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle("Aktuelle Fahrt")
                ContentCard {
                    HStack(spacing: 8) {
                        ForEach(journey.legs.filter { !$0.isWalk }, id: \.index) { LineBadge(leg: $0) }
                        Spacer()
                        if let arrival = journey.arrival {
                            Text("Ankunft \(arrival, format: .clock)").font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.peek {
        case .loaded(let response, let walks):
            SectionTitle("Alternativen")
            if response.journeys.isEmpty {
                Text("Keine Verbindung gefunden").foregroundStyle(.secondary)
            }
            ForEach(Array(response.journeys.enumerated()), id: \.offset) { index, journey in
                Button { chosen = index } label: {
                    ContentCard {
                        VStack(alignment: .leading, spacing: 4) {
                            AlternativeRow(journey: journey, calibrated: walks?[safe: index])
                            delta(journey)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("peekRow")
            }
        case .failed(let error):
            CardHint(text: error.errorDescription ?? "", tone: .warn)
        case .loading, nil:
            Label("Alternativen werden gesucht", systemImage: "tram.fill")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(.secondary)
        }
    }

    /// Ankunft im Vergleich zur laufenden Fahrt: frueher in Gruen, spaeter in Orange.
    @ViewBuilder private func delta(_ journey: Journey) -> some View {
        if let mine = flow.navJourney?.arrival, let other = journey.arrival {
            let minutes = Int((other.timeIntervalSince(mine) / 60).rounded())
            HStack(spacing: 4) {
                Text("Ankunft \(other, format: .clock)")
                Text(verbatim: "·")
                if minutes == 0 {
                    Text("gleich schnell")
                } else if minutes < 0 {
                    Text("\(-minutes) Min. früher").foregroundStyle(Color(.statusOk))
                } else {
                    Text("\(minutes) Min. später").foregroundStyle(Color(.statusWarn))
                }
            }
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Color(.labelSecondary))
        }
    }
}

#if DEBUG
// MARK: - Vorschau (Mock-Daten und Flow aus PreviewSupport.swift)

/// Jetzt-Karte aus dem Navigationsstand des Vorschau-Flows, ueber einer Kartenflaeche (Glass braucht Hintergrund).
private struct NowCardPreview: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        ZStack(alignment: .top) {
            Color(.fillTertiary).ignoresSafeArea()
            if let input = flow.navInput {
                NowCardView(card: NavigationPresenter.card(input), maxScrollHeight: 420)
                    .padding(16)
            }
        }
    }
}

// Zustaende 4 bis 4f: Uhrzeit relativ zu den Mock-Daten (PreviewData.base).
#Preview("Jetzt-Karte, Fußweg, Hell", traits: .modifier(PreviewFlow.navigation(PreviewData.short, atMinute: 7))) { NowCardPreview() }
#Preview("Jetzt-Karte, Fußweg, Dunkel", traits: .modifier(PreviewFlow.navigation(PreviewData.short, atMinute: 7))) {
    NowCardPreview().preferredColorScheme(.dark)
}
#Preview("Jetzt-Karte, Fußweg, AX3", traits: .modifier(PreviewFlow.navigation(PreviewData.short, atMinute: 7))) {
    NowCardPreview().dynamicTypeSize(.accessibility3)
}
#Preview("Jetzt-Karte, Im Zug", traits: .modifier(PreviewFlow.navigation(PreviewData.long, atMinute: 25))) { NowCardPreview() }
#Preview("Jetzt-Karte, Umstieg", traits: .modifier(PreviewFlow.navigation(PreviewData.long, atMinute: 44))) { NowCardPreview() }
#Preview("Jetzt-Karte, Gleiswechsel", traits: .modifier(PreviewFlow.navigation(PreviewData.disrupted, atMinute: 7))) { NowCardPreview() }
#Preview("Jetzt-Karte, Anschluss reicht nicht", traits: .modifier(PreviewFlow.navigation(PreviewData.tight, atMinute: 18))) {
    NowCardPreview()
}
#Preview("Jetzt-Karte, Ankunft", traits: .modifier(PreviewFlow.arrival)) { NowCardPreview() }

#Preview("Restfahrt, Hell", traits: .modifier(PreviewFlow.navigation(PreviewData.long, atMinute: 25))) {
    PreviewSheetBackdrop { NavigationSheet() }
}
#Preview("Restfahrt, Dunkel", traits: .modifier(PreviewFlow.navigation(PreviewData.long, atMinute: 25))) {
    PreviewSheetBackdrop { NavigationSheet() }.preferredColorScheme(.dark)
}
#Preview("Restfahrt, AX3", traits: .modifier(PreviewFlow.navigation(PreviewData.long, atMinute: 25))) {
    PreviewSheetBackdrop { NavigationSheet() }.dynamicTypeSize(.accessibility3)
}
#Preview("Restfahrt, knapper Umstieg", traits: .modifier(PreviewFlow.navigation(PreviewData.tight, atMinute: 18))) {
    PreviewSheetBackdrop { NavigationSheet() }
}
#Preview("Restfahrt, Ankunft", traits: .modifier(PreviewFlow.arrival)) { PreviewSheetBackdrop { NavigationSheet() } }

#Preview("Alternativen, Hell", traits: .modifier(PreviewFlow.alternatives)) { PreviewSheetBackdrop { AlternativesView() } }
#Preview("Alternativen, Dunkel", traits: .modifier(PreviewFlow.alternatives)) {
    PreviewSheetBackdrop { AlternativesView() }.preferredColorScheme(.dark)
}
#endif
