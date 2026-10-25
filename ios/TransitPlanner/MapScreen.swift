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

    var body: some View {
        GeometryReader { proxy in
            Map(position: $camera, scope: mapScope) {
                UserAnnotation()
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
            .mapControls { MapCompass(scope: mapScope) }
            // Optisches Zentrum folgt dem Sheet, gedeckelt bei der Haelfte (sonst springt die Karte bei .large).
            .safeAreaPadding(.bottom, min(sheetHeight, proxy.size.height * 0.5))
            // Kopf-Steuerung oben (44 pt + 16 pt Rand) + 16 pt Luft: die Route endet nie unter dem Status-Indikator.
            .safeAreaPadding(.top, 44 + 16 + 16)
            .ignoresSafeArea(edges: .bottom)
        }
        // Kopf-Steuerung ausserhalb des Karten-Polsters, damit sie oben bleibt.
        .overlay(alignment: .topTrailing) { MapButtons(scope: mapScope).padding(16) }
        .overlay(alignment: .topLeading) { StatusIndicator().padding(16) }
        .mapScope(mapScope)
        .onChange(of: flow.overlay?.id) { moveCamera() }
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

    private func moveCamera() {
        guard let overlay = flow.overlay else { return }
        let rect = overlay.rect.insetBy(dx: -overlay.rect.width * 0.15 - 300, dy: -overlay.rect.height * 0.15 - 300)
        if reduceMotion {
            camera = .rect(rect)
        } else {
            withAnimation(Motion.standard) { camera = .rect(rect) }
        }
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
        .presentationDetents(Self.detents, selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: Self.middle))
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .onChange(of: detent) {
            if detent != appDetent { userDetentChanges += 1 }
            appDetent = nil
        }
        .sensoryFeedback(.selection, trigger: userDetentChanges)
        .sensoryFeedback(.success, trigger: flow.phase) { _, new in new == .arrival }
        .onChange(of: flow.phase, initial: true) {
            let target = preferredDetent
            if target != detent {
                appDetent = target
                detent = target
            }
        }
        .sheet(isPresented: $flow.showsSettings, onDismiss: { flow.settingsOpensServer = false }) {
            SettingsSheet(opensServer: flow.settingsOpensServer)
        }
    }

    /// DESIGN.md 3: height(140) Start, Mitte (474 pt) Routenauswahl/2c, large Suche/Details; AX-Groessen immer large.
    private var preferredDetent: PresentationDetent {
        if typeSize.isAccessibilitySize, flow.phase != .start { return .large }
        switch flow.phase {
        case .start: return .height(140)
        case .search, .tripDetails: return .large
        case .options, .routeSelection, .navigation, .arrival: return Self.middle
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
        case .navigation:
            ContentUnavailableView {
                Label("Navigation folgt", systemImage: "location.north.line")
            } description: {
                Text("Die Wegführung kommt in einer späteren Etappe.")
            } actions: {
                Button("Angekommen") { flow.send(.arrived) }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                Button("Beenden") { flow.send(.back) }
            }
        case .arrival:
            ContentUnavailableView {
                Label("Angekommen", systemImage: "flag.checkered")
            } actions: {
                Button("Fertig") { flow.send(.reset) }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            }
        }
    }
}

struct MiddleDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(474, context.maxDetentValue * 0.6)
    }
}
