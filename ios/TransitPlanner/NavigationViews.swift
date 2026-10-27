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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { headline; badge }
                VStack(alignment: .leading, spacing: 4) { headline; badge }
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
    static let compactHeight: CGFloat = 210

    var body: some View {
        if flow.navMapOnly { mapBar } else { full }
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
        .padding(.top, 20)
    }

    @ViewBuilder private var full: some View {
        let overview = flow.phase == .arrival ? nil : flow.navInput.map(NavigationPresenter.overview)
        let rows = overview?.rows ?? []
        // Kopf fest, damit ein Zug am Kopf das Sheet vergroessert; bei AX-Groessen scrollt er mit, sonst wuerde er im
        // kompakten Detent gestaucht und ueberdeckt.
        if typeSize.isAccessibilitySize {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) { top(overview); list(rows) }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                top(overview)
                ScrollView { list(rows) }
            }
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

    /// Karte ganz sehen: blendet Jetzt-Karte und Liste aus.
    @ViewBuilder private var mapButton: some View {
        if flow.phase != .arrival {
            Button {
                withAnimation(Motion.standard) { flow.navMapOnly = true }
            } label: {
                Label("Karte", systemImage: "map")
                    .font(.body.weight(.semibold))
                    .frame(minHeight: 44)
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
