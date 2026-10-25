import SwiftUI
import TransitCore

// Wiederverwendbare Bausteine nach DESIGN.md Abschnitt 4.

/// Hauptknopf im Inhalt: bordered prominent als Kapsel, 50 pt, volle Breite.
/// Glass nur fuer schwebende Elemente ueber der Karte (AGENT.md 4.1.1).
struct PrimaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .font(.headline)
            .foregroundStyle(Color(.buttonLabel))
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(.capsule)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        // Eigene Knopfflaeche: weisse Schrift mind. 4,5:1 (Dunkel), 7:1 bei Hohem Kontrast (AGENT.md 4.1.2).
        .tint(Color(.buttonFill))
    }
}

/// Listenzeile: Symbol in Modusfarbe, Titel, Untertitel, Zusatz rechts; 60 pt.
struct ListRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            trailing.font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .contentShape(.rect)
    }
}

extension ListRow where Trailing == EmptyView {
    init(symbol: String, tint: Color, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Einstellungszeile: Titel, Wert, optional Chevron; 44 pt.
struct SettingsRow: View {
    let title: LocalizedStringKey
    var value: String?
    var chevron = false

    var body: some View {
        HStack {
            Text(title).font(.body).foregroundStyle(.primary)
            Spacer()
            if let value { Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            if chevron {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

/// Linien-Badge: Linienname auf Modusfarbe, Radius 6, Innenabstand 2/6.
struct LineBadge: View {
    let leg: Leg

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: leg.displayMode.symbolName)
            Text(leg.badgeText)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color(.labelOnAccent))
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(leg.displayMode.color, in: .rect(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Spoken.lineName(leg))
    }
}

/// Fussweg-Chip: figure.walk + Minuten; "ca." solange nur die Fahrplan-Schaetzung vorliegt.
struct WalkChip: View {
    let seconds: Int
    let estimated: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        HStack(spacing: 2) {
            Image(systemName: "figure.walk")
            if typeSize.isAccessibilitySize { Text("Fußweg") }
            if estimated { Text("ca.") }
            Text("\(minutes)")
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(Motion.micro, value: minutes)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color(.modeWalk))
        .fixedSize() // nie in Silben umbrechen (AX-Groessen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(estimated ? "Etwa \(minutes) Minuten Fußweg" : "\(minutes) Minuten Fußweg"))
    }
}

/// Verspaetung "+3 Min.": nur mit Echtzeit, pulsiert einmal (PhaseAnimator), bei Reduce Motion ruhig.
struct DelayBadge: View {
    let minutes: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("+\(minutes) Min.")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(Color(.statusWarn))
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(Color(.statusWarnTint), in: .rect(cornerRadius: 6, style: .continuous))
            .phaseAnimator([false, true, false], trigger: minutes) { content, grown in
                content.scaleEffect(grown && !reduceMotion ? 1.12 : 1)
            } animation: { _ in Motion.micro }
            .accessibilityLabel(Text("\(minutes) Minuten später"))
    }
}

/// Karten-Hinweis: Warnung oder Kritisch, Radius 12, Innenabstand 8/12, volle Breite.
struct CardHint: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    let tone: Tone

    var body: some View {
        // Eigenes HStack statt Label: in List-Zeilen vergroessert der Label-Stil sonst das Symbol.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tone.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(tone.tint, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Inhaltskarte ohne Glass: surface/card, Radius 16, 0,5-pt-Rand nur im Dark Mode (DESIGN.md 3 Dark).
struct ContentCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.surfaceCard), in: .rect(cornerRadius: 16, style: .continuous))
            .overlay {
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
                }
            }
    }
}

/// Uhrzeit mit festen Ziffern und rollenden Zahlen.
struct TimeText: View {
    let date: Date?

    var body: some View {
        Group {
            if let date { Text(date, format: .dateTime.hour().minute()) } else { Text(verbatim: "--:--") }
        }
        .monospacedDigit()
        .contentTransition(.numericText(countsDown: true))
        .animation(Motion.micro, value: date)
    }
}

struct MinutesText: View {
    let seconds: Int

    var body: some View {
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        Text("\(minutes) Min.")
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: true))
            .animation(Motion.micro, value: minutes)
    }
}

/// Leg-Bar: Fussweg-Chip > Linien-Badge > Fussweg-Chip; bei AX-Groessen vertikal (DESIGN.md H4).
struct LegBar: View {
    let journey: Journey
    let calibrated: CalibratedJourney?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach(Array(journey.legs.enumerated()), id: \.element.index) { position, leg in
                if position > 0, !typeSize.isAccessibilitySize {
                    Image(systemName: "chevron.compact.right").font(.caption2).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if leg.isWalk {
                    if let seconds = calibrated?.walks[leg.index]?.seconds ?? leg.durationSeconds, seconds > 0 {
                        WalkChip(seconds: seconds, estimated: calibrated == nil)
                    }
                } else {
                    LineBadge(leg: leg)
                }
            }
        }
    }
}

// MARK: - Inline-Banner (DESIGN.md H1)

struct InlineBanner: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.openURL) private var openURL
    let error: TransitError

    var body: some View {
        let message = Self.message(for: error, scope: flow.scope, phase: flow.phase)
        let tone = Self.tone(for: error)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Self.symbol(for: error))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tone.foreground)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.subheadline).foregroundStyle(.primary)
                if let until = flow.blockedUntil {
                    let now = Date()
                    HStack(spacing: 4) {
                        Text("Wieder möglich in")
                        Text(timerInterval: now...max(now, until), countsDown: true)
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                let actions = flow.actions(for: error)
                if !actions.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack { buttons(actions) }
                        VStack(alignment: .leading) { buttons(actions) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        // Kein Glass auf Glass (AGENT.md 4.1): das Banner liegt im Glass-Sheet, daher Tint-Flaeche (DESIGN.md H1).
        .background(tone.tint, in: .rect(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("banner")
        .onAppear { AccessibilityNotification.Announcement(message).post() }
    }

    @ViewBuilder private func buttons(_ actions: [BannerAction]) -> some View {
        ForEach(actions, id: \.self) { action in
            Button(action.title) {
                if action == .openSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                } else {
                    flow.perform(action)
                }
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        }
    }

    nonisolated static func message(for error: TransitError, scope: SearchScope, phase: Phase) -> String {
        if case .search = phase, scope == .address, error == .locationDenied || error == .locationUnavailable {
            return String(localized: "Adresssuche braucht deinen Standort.")
        }
        return error.errorDescription ?? ""
    }

    nonisolated static func tone(for error: TransitError) -> Tone {
        switch error {
        case .missingToken, .unauthorized, .locationDenied, .locationUnavailable: .info
        case .pinningFailed, .internal, .decodingFailed, .invalidRequest, .keychainFailure: .alert
        default: .warn
        }
    }

    nonisolated static func symbol(for error: TransitError) -> String {
        switch error {
        case .offline: "wifi.slash"
        case .upstreamUnavailable, .upstreamTimeout: "server.rack"
        case .rateLimited: "hourglass"
        case .missingToken, .unauthorized, .keychainFailure: "key.fill"
        case .locationDenied, .locationUnavailable: "location.slash"
        case .pinningFailed: "lock.trianglebadge.exclamationmark"
        case .refreshExpired, .notFound: "clock.arrow.circlepath"
        default: "exclamationmark.triangle.fill"
        }
    }
}

extension BannerAction {
    var title: LocalizedStringKey {
        switch self {
        case .retry: "Erneut versuchen"
        case .enterKey: "Schlüssel eintragen"
        case .openSettings: "Einstellungen"
        case .allowLocation: "Standort erlauben"
        case .switchToStops: "Haltestelle suchen"
        case .newSearch: "Neu suchen"
        }
    }
}

// MARK: - Quellenangabe (erste Stufe, DESIGN.md G2)

/// Text und Links aus `attribution` der Antwort; nur https-Links. Tipp auf "Quellen und Lizenzen" oeffnet G2.
struct AttributionFooter: View {
    let attribution: Attribution
    @State private var showsSources = false

    var body: some View {
        // Links zuerst: der Transitous-Link muss auch im mittleren Detent sichtbar sein (Nutzungsregel).
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { links }
                VStack(alignment: .leading, spacing: 0) { links }
            }
            Text(attribution.text)
                .fixedSize(horizontal: false, vertical: true) // nie kuerzen (Transitous-Regel)
                .accessibilityIdentifier("attributionText")
            Button("Quellen und Lizenzen") { showsSources = true }
                .foregroundStyle(Color(.accentBlue))
                .frame(minHeight: 44)
                .contentShape(.rect)
                .accessibilityIdentifier("sourcesButton")
        }
        .font(.footnote)
        // Feste Farbe statt .secondary: ueber Glass wird .secondary zu blass (Transitous-Regel: klar lesbar).
        .foregroundStyle(Color(.labelSecondary))
        .sheet(isPresented: $showsSources) {
            NavigationStack {
                SourcesView(attribution: attribution)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { showsSources = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder private var links: some View {
        ForEach(attribution.httpsLinks, id: \.self) { link in
            Link(destination: link.url) {
                Label(link.label, systemImage: "arrow.up.right")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color(.accentBlue))
            }
            .frame(minHeight: 44) // Touch-Flaeche (AGENT.md 4.3.1)
            .contentShape(.rect)
            .accessibilityLabel(link.label)
            .accessibilityIdentifier("attributionLink.\(link.label)")
        }
    }
}
