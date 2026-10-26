import MapKit
import SwiftUI
import TransitCore

/// Wurzel: erster Start (A1/A2) oder die persistente Karte mit Sheet.
struct RootView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        Group {
            if let step = flow.onboarding {
                OnboardingView(step: step)
            } else {
                MapScreen()
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }
}

/// Ebene 0 Karte, Ebene 1 Kopf-Steuerung, Ebene 2 System-Sheet (DESIGN.md B1, RESEARCH-M3 1-3).
struct MapScreen: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var mapScope
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var sheetHeight: CGFloat = 140
    @State private var nowCardHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 800
    /// "Ganze Route" oder Zeile angetippt: Kamera folgt nicht mehr, bis "Zentrieren".
    @State private var followPaused = false
    /// Kartenrichtung: der Kompass ist nur sichtbar (und braucht Platz), wenn die Karte nicht genordet ist.
    @State private var heading: Double = 0

    /// Unterwegs ist die Karte nur Kontext: keine Kartenknoepfe, kein Status, oben die Jetzt-Karte (DESIGN.md C).
    private var guiding: Bool { flow.phase.isGuiding }

    var body: some View {
        GeometryReader { proxy in
            Map(position: $camera, scope: mapScope) {
                if guiding {
                    // Eigene Position aus dem Navigations-Stream (gleiche Quelle wie die Logik).
                    if let p = flow.navPosition {
                        Annotation("Mein Standort", coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)) {
                            Circle()
                                .fill(Color(.accentBlue))
                                .stroke(Color(.labelOnAccent), lineWidth: 3)
                                .frame(width: 18, height: 18)
                        }
                        .annotationTitles(.hidden)
                    }
                    // Enge Umstiege (Puffer knapp oder zu kurz): Symbol in Statusfarbe, Titel nennt Halt und Puffer.
                    ForEach(tightTransfers) { row in
                        if let c = row.coordinate, let buffer = row.buffer {
                            Annotation(String(localized: "\(row.stop ?? row.title): \(NavigationPresenter.bufferLabel(buffer))"),
                                       coordinate: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)) {
                                Image(systemName: buffer.status.symbolName)
                                    .font(.title2)
                                    .foregroundStyle(buffer.status.color)
                                    .padding(4)
                                    .background(Color(.surfaceCard), in: .circle)
                                    .accessibilityLabel(String(localized: "Umstieg \(row.stop ?? row.title), Puffer \(NavigationPresenter.spokenBuffer(buffer.seconds))"))
                            }
                        }
                    }
                    if let target = flow.navTargetStop, let c = target.place.coordinate {
                        Annotation(target.platform.map { String(localized: "Gleis \($0)") } ?? (target.place.name ?? ""),
                                   coordinate: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title)
                                .foregroundStyle(Color(.accentBlue))
                                .background(Color(.labelOnAccent), in: .circle)
                        }
                    }
                } else {
                    UserAnnotation()
                }
                if let overlay = flow.overlay {
                    ForEach(overlay.segments) { segment in
                        MapPolyline(coordinates: segment.coordinates)
                            .stroke(segment.mode == .walk ? Color(.modeWalk) : segment.mode.color,
                                    style: segment.isWalk
                                        ? StrokeStyle(lineWidth: 4, lineCap: .round, dash: [1, 7])
                                        : StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .onMapCameraChange { heading = $0.camera.heading }
            // Unterwegs steht der Kompass im Overlay ueber "Zentrieren", sonst ueberdecken sie sich.
            .mapControls { if !guiding { MapCompass(scope: mapScope) } }
            // Optisches Zentrum folgt dem Sheet, gedeckelt bei der Haelfte (sonst springt die Karte bei .large).
            .safeAreaPadding(.bottom, min(sheetHeight, proxy.size.height * 0.5))
            // Kopf-Steuerung oben (44 pt + 16 pt Rand) bzw. Jetzt-Karte + 16 pt Luft: die Route endet nie darunter.
            .safeAreaPadding(.top, (guiding ? nowCardHeight : 44 + 16) + 16)
            .ignoresSafeArea(edges: .bottom)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { containerHeight = $0 }
        // Kopf-Steuerung ausserhalb des Karten-Polsters, damit sie oben bleibt.
        .overlay(alignment: .top) {
            if guiding, let input = flow.navInput {
                NowCardView(card: NavigationPresenter.card(input), maxScrollHeight: nowCardLimit)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { nowCardHeight = $0 }
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) { if !guiding { MapButtons(scope: mapScope).padding(16) } }
        // Unterwegs: erst wenn der Nutzer die Karte selbst bewegt hat, holt "Zentrieren" sie zurueck.
        .overlay(alignment: .topTrailing) {
            if guiding {
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 8) {
                        // Blendet sich selbst aus, solange die Karte genordet ist.
                        MapCompass(scope: mapScope)
                        if showsFitRoute {
                            Button("Ganze Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { fitRemainingRoute() }
                                .labelStyle(.iconOnly)
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .accessibilityHint("Zeigt die restliche Route auf der Karte")
                                .accessibilityIdentifier("fitRoute")
                        }
                        if camera.positionedByUser || followPaused {
                            Button("Zentrieren", systemImage: "location.fill") { focusNavigation(force: true) }
                                .labelStyle(.iconOnly)
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .accessibilityHint("Karte folgt wieder deiner Position")
                                .accessibilityIdentifier("recenterMap")
                                .transition(.opacity)
                        }
                    }
                }
                .padding(.top, buttonsTop)
                .padding(.trailing, 16)
                .animation(Motion.standard, value: camera.positionedByUser || followPaused)
            }
        }
        .overlay(alignment: .topLeading) { if !guiding { StatusIndicator().padding(16) } }
        .animation(Motion.standard, value: guiding)
        .mapScope(mapScope)
        .onChange(of: flow.overlay?.id) { moveCamera() }
        // Kamera folgt Position (AppFlow meldet erst ab 3 m Bewegung) und Ziel-Halt, solange der Nutzer die Karte
        // nicht selbst verschoben, gezoomt oder gedreht hat.
        .onChange(of: flow.navPosition) { focusNavigation() }
        .onChange(of: flow.navFocus) {
            guard let c = flow.navFocus?.coordinate else { return }
            followPaused = true
            setCamera(.camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude),
                                        distance: 800)))
        }
        .onChange(of: flow.navStep) { old, new in
            // Navigationsstart: immer ausrichten, auch wenn die Karte beim Planen verschoben wurde.
            focusNavigation(force: old == nil)
            // Ansage bei Zustandswechsel (VoiceOver), Erfolgshaptik am Einstiegs- bzw. Umsteigehalt.
            if new != nil, old != new, let input = flow.navInput {
                AccessibilityNotification.Announcement(NavigationPresenter.spoken(NavigationPresenter.card(input))).post()
            }
        }
        .sensoryFeedback(.warning, trigger: flow.navWarnings)
        .sensoryFeedback(.success, trigger: flow.navStep) { _, new in
            if case .waitingAtPlatform = new { return true }
            return false
        }
        .onChange(of: scenePhase, initial: true) {
            switch scenePhase {
            case .active: flow.becameActive()
            case .background: flow.movedToBackground()
            default: break
            }
        }
        .sheet(isPresented: .constant(true)) {
            SheetRoot()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
        }
    }

    /// Unterwegs: eigene Position und Ziel-Halt im Bild. Hat der Nutzer die Karte bewegt, bleibt sie, bis `force`.
    private func focusNavigation(force: Bool = false) {
        guard guiding, force || (!camera.positionedByUser && !followPaused) else { return }
        if force { followPaused = false }
        guard let p = flow.navPosition else {
            // Ohne Fix: ganze Route.
            if force { fitOverlay() }
            return
        }
        var points = [MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))]
        if let c = flow.navTargetStop?.place.coordinate {
            points.append(MKMapPoint(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)))
        }
        let rect = points.dropFirst().reduce(MKMapRect(origin: points[0], size: MKMapSize(width: 0, height: 0))) {
            $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 0, height: 0)))
        }
        setCamera(.rect(rect.insetBy(dx: -rect.width * 0.3 - 250, dy: -rect.height * 0.3 - 250)))
    }

    private var compassVisible: Bool { min(heading, 360 - heading) > 0.5 }
    private var recenterVisible: Bool { camera.positionedByUser || followPaused }

    /// Hoehe des Knopfstapels (44 pt je Knopf, 8 pt Abstand) mit oder ohne "Ganze Route".
    private func stackHeight(fitRoute: Bool) -> CGFloat {
        let count = [compassVisible, fitRoute, recenterVisible].filter { $0 }.count
        return count == 0 ? 0 : CGFloat(count) * 44 + CGFloat(count - 1) * 8
    }

    /// Freier Kartenraum zwischen Jetzt-Karte und Sheet.
    private var freeBelowCard: CGFloat { containerHeight - sheetHeight - nowCardHeight - 16 }

    /// AX: Jetzt-Karte hoechstens so hoch, dass der Knopfstapel darunter noch Platz hat (mind. ein Viertel, hoechstens die
    /// Haelfte des Bildschirms; darueber scrollt die Karte).
    private var nowCardLimit: CGFloat {
        min(containerHeight * 0.5, max(containerHeight * 0.25, containerHeight - sheetHeight - stackHeight(fitRoute: true) - 32))
    }

    /// "Ganze Route" nur, wenn der Stapel zwischen Jetzt-Karte und Sheet passt (nie ueber Glass, nie unter das Sheet).
    private var showsFitRoute: Bool { stackHeight(fitRoute: true) <= freeBelowCard }

    /// Unter der Jetzt-Karte; reicht der Platz selbst ohne "Ganze Route" nicht, rutschen Kompass/Zentrieren hoch, damit
    /// sie nie unter dem Sheet verschwinden.
    private var buttonsTop: CGFloat {
        max(0, min(nowCardHeight + 8, containerHeight - sheetHeight - stackHeight(fitRoute: showsFitRoute) - 8))
    }

    /// Enge Umstiege der Restfahrt fuer die Karten-Markierung.
    private var tightTransfers: [RouteOverview.Row] {
        guard let input = flow.navInput else { return [] }
        return NavigationPresenter.overview(input).rows.filter { $0.kind == .transfer && ($0.buffer.map { $0.status != .comfortable } ?? false) }
    }

    /// "Ganze Route": eigene Position und die restliche Route im Bild; Folgen pausiert bis "Zentrieren".
    private func fitRemainingRoute() {
        guard let input = flow.navInput else { return }
        let points = (NavigationPresenter.overview(input).points + [flow.navPosition].compactMap { $0 })
            .map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        guard let first = points.first else { return }
        let rect = points.dropFirst().reduce(MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))) {
            $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 0, height: 0)))
        }
        followPaused = true
        setCamera(.rect(rect.insetBy(dx: -rect.width * 0.15 - 200, dy: -rect.height * 0.15 - 200)))
    }

    private func setCamera(_ position: MapCameraPosition) {
        if reduceMotion {
            camera = position
        } else {
            withAnimation(Motion.standard) { camera = position }
        }
    }

    private func moveCamera() {
        if guiding { return focusNavigation() }
        fitOverlay()
    }

    private func fitOverlay() {
        guard let overlay = flow.overlay else { return }
        setCamera(.rect(overlay.rect.insetBy(dx: -overlay.rect.width * 0.15 - 300, dy: -overlay.rect.height * 0.15 - 300)))
    }
}

/// Kartenknoepfe oben rechts (Glass, 44 x 44, Abstand 8). Statistik (M5) und Erinnerungen (M4) kommen dazu,
/// sobald sie etwas tun; bis dahin nur Standort.
private struct MapButtons: View {
    let scope: Namespace.ID

    var body: some View {
        // Einzelner Knopf: kein GlassEffectContainer noetig; kommt mit Statistik/Erinnerungen zurueck.
        MapUserLocationButton(scope: scope)
            .frame(width: 44, height: 44)
    }
}

/// Oben links: GPS-Genauigkeit und aktiver Verkehrsmittel-Filter.
private struct StatusIndicator: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        HStack(spacing: 8) {
            if let accuracy = flow.lastAccuracy {
                Label {
                    Text("± \(Int(accuracy.rounded())) m")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                } icon: {
                    Image(systemName: "location.fill")
                }
            } else if !flow.locationAllowed {
                Label("Ohne Standort", systemImage: "location.slash")
            }
            Text("Nahverkehr")
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// Inhalt des persistenten Sheets; wechselt mit der Phase (Zustand, kein Push).
struct SheetRoot: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var detent: PresentationDetent = .height(140)
    /// Von der App gesetzter Detent; nur Nutzer-Wechsel loesen Haptik aus.
    @State private var appDetent: PresentationDetent?
    @State private var userDetentChanges = 0

    /// Mittlerer Detent 474 pt statt fraction(0.5): so viel braucht die Routenauswahl, damit die Quellenangabe
    /// unter der Hero Card sichtbar bleibt (DESIGN.md 3, Figma-Mass). Auf kleinen Geraeten hoechstens 60 % der Hoehe.
    static let middle = PresentationDetent.custom(MiddleDetent.self)
    static let detents: Set<PresentationDetent> = [.height(140), middle, .large]

    var body: some View {
        @Bindable var flow = flow
        ZStack {
            content
                .id(flow.phase)
                .transition(transition)
        }
        .animation(Motion.standard, value: flow.phase)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = flow.banner, error.showsBanner {
                InlineBanner(error: error)
                    .id(error) // neue Ansage fuer VoiceOver bei jedem Fehlerwechsel
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.standard, value: flow.banner)
        .presentationDetents(flow.phase.isGuiding ? navDetents : Self.detents, selection: $detent)
        // Unterwegs ist der mittlere Detent nicht im Satz; `upThrough: middle` dimmte dann die Karte und sperrte
        // jede Geste. Daher dort immer frei bedienbar.
        .presentationBackgroundInteraction(flow.phase.isGuiding ? .enabled : .enabled(upThrough: Self.middle))
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .onChange(of: detent) {
            if detent != appDetent { userDetentChanges += 1 }
            appDetent = nil
        }
        .sensoryFeedback(.selection, trigger: userDetentChanges)
        .sensoryFeedback(.success, trigger: flow.phase) { _, new in new == .arrival }
        .onChange(of: flow.phase, initial: true) { old, new in
            // Unterwegs bleibt der vom Nutzer gewaehlte Detent (z. B. Navigation -> Ankunft).
            if old.isGuiding, new.isGuiding, old != new, navDetents.contains(detent) { return }
            applyPreferredDetent()
        }
        // Schriftgroesse waehrend der Navigation geaendert: Detent-Menge wechselt, gewaehlter Detent ggf. ungueltig.
        .onChange(of: typeSize) {
            let current = flow.phase.isGuiding ? navDetents : Self.detents
            if !current.contains(detent) { applyPreferredDetent() }
        }
        .sheet(isPresented: $flow.showsSettings, onDismiss: { flow.settingsOpensServer = false }) {
            SettingsSheet(opensServer: flow.settingsOpensServer)
        }
    }

    private func applyPreferredDetent() {
        let target = preferredDetent
        if target != detent {
            appDetent = target
            detent = target
        }
    }

    /// DESIGN.md 3: height(140) Start, Mitte (474 pt) Routenauswahl/2c, large Suche/Details; AX-Groessen immer large.
    /// Danach-Sheet startet kompakt (Kopf, engste Stelle, aktuelle und naechste Etappe), hochziehbar auf .medium fuer die
    /// ganze Restfahrt; die App wechselt den Detent unterwegs nie selbst, damit die Karte nicht springt. AX: Anteile, Inhalt scrollt.
    private var navDetents: Set<PresentationDetent> { [navDetent, .medium] }
    private var navDetent: PresentationDetent { typeSize.isAccessibilitySize ? .fraction(0.3) : .height(NavigationSheet.compactHeight) }

    private var preferredDetent: PresentationDetent {
        if flow.phase.isGuiding { return navDetent }
        if typeSize.isAccessibilitySize, flow.phase != .start { return .large }
        switch flow.phase {
        case .start: return .height(140)
        case .search, .tripDetails: return .large
        case .options, .routeSelection: return Self.middle
        case .navigation, .arrival: return navDetent
        }
    }

    /// Vorwaerts kommt der neue Zustand von rechts, zurueck von links; bei Reduce Motion nur Ueberblenden.
    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        let edge: Edge = flow.movedBackward ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: edge).combined(with: .opacity), removal: .opacity)
    }

    @ViewBuilder private var content: some View {
        switch flow.phase {
        case .start: StartSheet()
        case .search(let slot, _): SearchSheet(slot: slot)
        case .options: OptionsSheet()
        case .routeSelection: RouteSheet()
        case .tripDetails(let index): TripDetailsSheet(index: index)
        case .navigation, .arrival:
            NavigationSheet()
        }
    }
}

struct MiddleDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(474, context.maxDetentValue * 0.6)
    }
}
