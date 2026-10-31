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
        // Gleiche Hoehe wie SecondaryButton (50 pt): .borderedProminent addiert eigenen Innenabstand (62 pt).
        .buttonStyle(FilledCapsuleStyle())
    }
}

/// Eigene Knopfflaeche: weisse Schrift mind. 4,5:1 (Dunkel), 7:1 bei Hohem Kontrast (AGENT.md 4.1.2).
struct FilledCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FilledCapsuleBody(configuration: configuration)
    }

    private struct FilledCapsuleBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background(Color(.buttonFill), in: .capsule)
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
        }
    }
}

/// Zweitknopf neben dem Hauptknopf (Figma): graue Kapsel, Akzent-Schrift, 50 pt.
struct SecondaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .font(.headline)
            .foregroundStyle(Color(.accentBlue))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background(Color(.fillTertiary), in: .capsule)
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
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(Color(.fillTertiary), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            trailing.font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
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
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(Color(.labelOnAccent))
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background(leg.displayMode.color, in: .rect(cornerRadius: 8, style: .continuous))
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
        // AX: ausgeschrieben und mit Abstand ("Fußweg 4", nicht "Fußweg4")
        HStack(spacing: typeSize.isAccessibilitySize ? 6 : 2) {
            Image(systemName: "figure.walk")
            if typeSize.isAccessibilitySize { Text("Fußweg") }
            if estimated { Text("ca.") }
            Text("\(minutes)")
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(Motion.micro, value: minutes)
        }
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(Color(.modeWalk))
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background(Color(.fillTertiary), in: .rect(cornerRadius: 8, style: .continuous))
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

extension FormatStyle where Self == Date.FormatStyle {
    /// Einheitliche Uhrzeit in UI und VoiceOver: zweistellige Stunde ("08:32"), 12-Std.-Gebietsschemata mit AM/PM.
    static var clock: Date.FormatStyle { .dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits) }
}

extension Date {
    var clockText: String { formatted(.clock) }
}

/// Uhrzeit mit festen Ziffern und rollenden Zahlen.
struct TimeText: View {
    let date: Date?

    var body: some View {
        Group {
            if let date { Text(date, format: .clock) } else { Text(verbatim: "--:--") }
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
        // Umbricht statt zu quetschen: lange Ketten (4 Fahrzeuge, 3 Umstiege) bleiben lesbar (Chips nie umgebrochen).
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(FlowLayout(spacing: 4, lineSpacing: 8))
        layout {
            ForEach(Array(journey.legs.enumerated()), id: \.element.index) { position, leg in
                if leg.isWalk, (calibrated?.walks[leg.index]?.seconds ?? leg.durationSeconds ?? 0) <= 0 {
                    EmptyView()
                } else {
                    HStack(spacing: 4) {
                        if position > 0, !typeSize.isAccessibilitySize {
                            Image(systemName: "chevron.compact.right").font(.caption).foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        if leg.isWalk {
                            WalkChip(seconds: calibrated?.walks[leg.index]?.seconds ?? leg.durationSeconds ?? 0, estimated: calibrated == nil)
                        } else {
                            LineBadge(leg: leg)
                        }
                    }
                }
            }
        }
    }
}

/// Zeilenumbruch fuer Chip-Ketten: jedes Kind behaelt seine Idealgroesse, passt es nicht mehr, beginnt eine neue Zeile.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 8

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: maxX, height: y + lineHeight), origins)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(bounds.width, subviews).origins
        for (view, origin) in zip(subviews, origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }
}

// MARK: - Inline-Banner (DESIGN.md H1)

struct InlineBanner: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.openURL) private var openURL
    let error: TransitError

    var body: some View {
        let message = error.errorDescription ?? ""
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
        case .chooseOrigin: "Start wählen"
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

/// Abschnittstitel wie in Figma: kleine Versalien in label/secondary.
struct SectionTitle: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color(.labelSecondary))
            .textCase(.uppercase)
    }
}

/// Listenabschnitt als weisse Karte (surface/card) mit Titel in Versalien.
struct CardSection<Content: View, Footer: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        Section {
            content.listRowBackground(Color(.surfaceCard))
        } header: {
            SectionTitle(title)
        } footer: {
            footer
        }
    }
}

extension CardSection where Footer == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content, footer: { EmptyView() })
    }
}

#if DEBUG
// MARK: - Vorschau

/// Alle Bausteine auf einer Seite (Mock-Daten aus PreviewSupport.swift).
private struct ComponentsGallery: View {
    private var journeys: [Journey] {
        [PreviewData.short, PreviewData.disrupted, PreviewData.long].compactMap { $0?.journeys.first }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PrimaryButton(title: "Starten", systemImage: "location.fill") {}
                PrimaryButton(title: "Starten", systemImage: "location.fill") {}.disabled(true)
                SecondaryButton(title: "Erinnern", systemImage: "bell") {}
                SectionTitle("Favoriten")
                ContentCard {
                    VStack(spacing: 0) {
                        ListRow(symbol: TransitMode.tram.symbolName, tint: TransitMode.tram.color, title: "Düsseldorf Hbf",
                                subtitle: "Düsseldorf") { Text(verbatim: "8 Min.") }
                        ListRow(symbol: "clock.arrow.circlepath", tint: Color(.accentBlue),
                                title: "Messe Ost/Stockumer Kirchstraße, Düsseldorf-Stockum")
                        SettingsRow(title: "Favoriten", value: "3", chevron: true)
                    }
                }
                ForEach(Array(journeys.enumerated()), id: \.offset) { _, journey in
                    HStack(spacing: 4) {
                        ForEach(journey.legs.filter { !$0.isWalk }, id: \.index) { LineBadge(leg: $0) }
                    }
                    LegBar(journey: journey, calibrated: nil)
                }
                HStack(spacing: 8) {
                    WalkChip(seconds: 240, estimated: true)
                    WalkChip(seconds: 720, estimated: false)
                    DelayBadge(minutes: 3)
                }
                CardHint(text: "Gleiswechsel: Gleis 2 statt 1", tone: .warn)
                CardHint(text: "Anschluss RB 25 in Köln Messe/Deutz reicht nicht mehr.", symbol: "xmark.octagon.fill", tone: .alert)
                ContentCard {
                    HStack {
                        TimeText(date: PreviewData.base)
                        TimeText(date: nil)
                        Spacer()
                        MinutesText(seconds: 754)
                    }
                }
                if let attribution = PreviewData.attribution { AttributionFooter(attribution: attribution) }
            }
            .padding(16)
        }
        .background(Color(.surfaceSheet))
    }
}

#Preview("Bausteine, Hell") { ComponentsGallery() }
#Preview("Bausteine, Dunkel") { ComponentsGallery().preferredColorScheme(.dark) }
#Preview("Bausteine, AX3") { ComponentsGallery().dynamicTypeSize(.accessibility3) }

/// Inline-Banner fuer die haeufigen Fehlerarten (H1); Aktionen kommen aus dem Flow.
private struct BannerGallery: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach([TransitError.offline, .upstreamUnavailable, .rateLimited, .missingToken, .locationDenied,
                         .refreshExpired, .pinningFailed], id: \.self) { InlineBanner(error: $0) }
            }
            .padding(.vertical, 16)
        }
    }
}

#Preview("Inline-Banner, Hell", traits: .modifier(PreviewFlow.start)) { BannerGallery() }
#Preview("Inline-Banner, Dunkel", traits: .modifier(PreviewFlow.start)) { BannerGallery().preferredColorScheme(.dark) }
#Preview("Inline-Banner, AX3", traits: .modifier(PreviewFlow.start)) { BannerGallery().dynamicTypeSize(.accessibility3) }

#Preview("Abschnitt in Liste") {
    List {
        CardSection("Favoriten") {
            ListRow(symbol: "house.fill", tint: Color(.accentBlue), title: "Altstadt")
            ListRow(symbol: "graduationcap.fill", tint: Color(.accentBlue), title: "Weyertal 119a")
        }
    }
    .scrollContentBackground(.hidden)
    .background(Color(.surfaceSheet))
}
#endif
