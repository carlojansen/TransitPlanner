# Recherche Meilenstein 3: SwiftUI-Interface und Navigations-State-Machine

Stand 24.10.2026. Ziel: iOS 26.0, Swift 6 (Strict Concurrency), SwiftUI, Observation. Grundlage: SPEZIFIKATION 3 und 4.2,
AGENT.md Teil B, API.md, STATUS.md und die öffentlichen APIs von `TransitCore`.
Kennzeichnung: **[Doku]** = in Apple-Doku/WWDC-Transkript nachgelesen, **[Erfahrung]** = gängige Praxis bzw. Foren/Blogs,
**[unsicher]** = im Prototyp prüfen, bevor darauf gebaut wird.

## 0. Befunde vorab (Entscheidungen für Carlo)

1. **Materialien widersprechen iOS 26.** AGENT.md 4.1 und SPEZIFIKATION 1.2 verlangen `.regularMaterial` für das Sheet und
   `.ultraThinMaterial` für schwebende Buttons. Unter iOS 26 bekommen Sheets mit Teilhöhe automatisch Liquid Glass; Apple rät
   ausdrücklich, `presentationBackground` zu entfernen. Schwebende Buttons sollten `.buttonStyle(.glass)` bzw. `glassEffect`
   nutzen. Vorschlag: AGENT.md 4.1 auf „System-Glass (automatisch), Materialien nur in der Inhaltsebene“ ändern. Der 0.5-pt-Innenrand
   entfällt auf Glass. **Entschieden (Carlo, 24.10.): umgesetzt in AGENT.md 4.1.**
2. **Spring-Werte uneinheitlich:** SPEZIFIKATION 3.2 `bounce: 0.12`, AGENT.md 4.3 `bounce: 0.1`. Vorschlag: eine Konstante
   `Motion.sheet = .spring(duration: 0.35, bounce: 0.12)` und `Motion.micro = .snappy(duration: 0.25)`. **Entschieden (Carlo, 24.10.): stattdessen
   `Motion.standard`/`micro`/`momentum` nach Apple-Werten, siehe AGENT.md 4.3.**
3. **`matchedGeometryEffect` funktioniert nicht über die Sheet-Grenze** (Sheet und Haupt-View sind getrennte Präsentations-Hierarchien)
   **[Erfahrung]**. Das Morphing „Leg-Bar aus der Hero Card ins Guidance Banner oben“ (SPEZIFIKATION 3.2.1) geht so nicht direkt.
   Vorschlag in Abschnitt 6.
4. **Fakes für Previews/UI-Tests:** `TransitAPIClient` nimmt einen eigenen `HTTPTransport` nur über einen `internal`-Initializer
   (bewusst, Review M2). Die App kann deshalb keinen Fake-Client bauen. Vorschlag: in der App schmale Protokolle
   (`StopSearching`, `RoutePlanning`) über `SearchService`/`HybridRouteCalculator` legen und dort faken, statt den Transport öffentlich
   zu machen (Abschnitt 10).
5. **Figma „2 Suche“** zeigt Haltestellen und Adressen parallel mit Debounce 250 ms. Das verletzt den Pflichtschalter
   (API.md, STATUS M2) und die Untergrenze von 300 ms. Der Screen muss auf Segmented Control mit genau einem Modus und 300 ms
   (oder Return) umgebaut werden.

---

## 1. Apple-Maps-Layout: persistente Map und Bottom Sheet

**Empfehlung:** `Map` als Wurzel-View, darauf ein dauerhaft präsentiertes System-Sheet mit drei Detents. Keine eigene
Sheet-Implementierung: das System-Sheet bringt Glass, Grabber, VoiceOver-Resize und Keyboard-Handling mit.

**APIs:** `sheet(isPresented:)`, `presentationDetents(_:selection:)`, `PresentationDetent.height(_:)`, `.fraction(_:)`, `.large`,
`presentationBackgroundInteraction(.enabled(upThrough:))`, `interactiveDismissDisabled()`, `presentationDragIndicator(.visible)`,
`presentationContentInteraction(.scrolls)`, `onGeometryChange(for:of:action:)`, `safeAreaPadding(_:_:)`.

```swift
@State private var detent: PresentationDetent = .height(140)
@State private var sheetHeight: CGFloat = 140

Map(position: $flow.camera) { /* Inhalte, Abschnitt 3 */ }
    .safeAreaPadding(.bottom, min(sheetHeight, containerHeight * 0.5))
    .sheet(isPresented: .constant(true)) {
        SheetRoot()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
            .presentationDetents([.height(140), .fraction(0.5), .large], selection: $detent)
            .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5)))
            .presentationContentInteraction(.scrolls)
            .interactiveDismissDisabled()
            .sensoryFeedback(.selection, trigger: detent)
    }
```

**Fallstricke:**
- `.large` sperrt die Karte (Interaktion nur bis `fraction(0.5)` freigegeben) und das Glass wird dort opak **[Doku]**. Kein
  `presentationBackground` setzen, sonst verschwindet das Glass **[Doku]**.
- `Form`/`List` im Sheet decken das Glass ab: `.scrollContentBackground(.hidden)` **[Erfahrung]**. Nach einem Push in einem
  `NavigationStack` im Sheet wird der Hintergrund laut Forenberichten opak **[unsicher]**; Zustände im Sheet daher per
  State-Machine umschalten statt per Push.
- Weitere Sheets (Token, Quellen, Einstellungen) müssen aus dem Inhalt des persistenten Sheets präsentiert werden, nicht aus der Map,
  weil dort schon ein Sheet hängt **[Erfahrung]**. HIG: nur ein Sheet gleichzeitig aus der Hauptansicht.
- `safeAreaPadding` auf der Map: Vergrößern läuft flüssig, Verkleinern kann kurz weiß aufblitzen (offener Fehlerbericht im
  Apple-Forum) **[unsicher]**. Polster bei `fraction(0.5)` deckeln, damit die Karte bei `.large` nicht springt.
- `.constant(true)` ist hier zulässig, weil das Sheet nie geschlossen wird; Swipe-Dismiss verhindert `interactiveDismissDisabled`.
- Fokus im Suchfeld: Detent programmatisch auf `.large` setzen (wie Apple Karten), sonst verdeckt die Tastatur die Treffer.
- `sensoryFeedback(.selection, trigger: detent)` feuert auch bei programmatischen Wechseln; ggf. Closure-Variante mit Bedingung.

**Quellen:** [WWDC25 323 Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/),
[presentationBackgroundInteraction](https://developer.apple.com/documentation/swiftui/view/presentationbackgroundinteraction(_:)),
[PresentationDetent](https://developer.apple.com/documentation/swiftui/presentationdetent),
[HIG Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets),
[Liquid-Glass-Sheets (nilcoalescing)](https://nilcoalescing.com/blog/PresentingLiquidGlassSheetsInSwiftUI),
[Forum: Map-Flackern mit safeAreaPadding](https://developer.apple.com/forums/thread/771529).

## 2. Liquid Glass in iOS 26

**Empfehlung:** Was das System liefert, nicht nachbauen. Glass nur in der Bedien- und Navigationsebene (Sheet, Top-Chrome,
Guidance Banner, Kartenbuttons), nie in Inhalten wie Verbindungszeilen.

**Automatisch (Neukompilieren mit Xcode 26):** Sheets mit Teilhöhe, Toolbars (gruppiert, schwebend), Tab Bar, Suchfeld in der
Toolbar, Scroll-Edge-Effekt unter Toolbars, Controls beim Bedienen **[Doku]**.

**APIs:** `glassEffect(_:in:)` (Standard `Glass.regular` in `Capsule`), `Glass.clear`, `.identity`, `.tint(_:)`, `.interactive()`,
`GlassEffectContainer(spacing:)`, `glassEffectID(_:in:)`, `glassEffectUnion(id:namespace:)`, `glassEffectTransition(.matchedGeometry | .materialize)`,
`buttonStyle(.glass)` / `.glassProminent`, `ToolbarSpacer`, `scrollEdgeEffectStyle(_:for:)`.

```swift
GlassEffectContainer(spacing: 12) {
    VStack(spacing: 12) {
        Button("Statistik", systemImage: "chart.bar.xaxis") { }
        Button("Erinnerungen", systemImage: "bell.badge") { }
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.glass)
}
// Guidance Banner (eigene Form):
banner.glassEffect(.regular, in: .rect(cornerRadius: 16))
```

**Fallstricke:**
- „Glass kann kein Glass sampeln“: benachbarte Glass-Elemente in einen gemeinsamen `GlassEffectContainer`, sonst inkonsistente
  Darstellung **[Doku]**. Kein Glass auf Glass (z. B. Glass-Banner im Glass-Sheet).
- `glassEffect` nach den übrigen Darstellungs-Modifiern anwenden **[Doku]**. Viele Effekte gleichzeitig kosten Leistung **[Doku]**.
- `tint` nur mit Bedeutung (z. B. Start-Button), nicht als Deko **[Doku]**. `.clear` nur über bildreichen Hintergründen; über der
  Karte `.regular` **[Doku HIG]**.
- **Kontrast/Transparenz:** Laut HIG passt das System Glass bei „Transparenz reduzieren“ und „Kontrast erhöhen“ selbst an; wie genau,
  ist nicht dokumentiert **[unsicher]**. Nicht mit eigener Opazität übersteuern. Linienfarben und Text auf Glass trotzdem mit
  beiden Einstellungen im Simulator prüfen (AGENT.md 4.1.2 verlangt AAA).
- Eigene Hintergründe/Abdunklungen hinter Toolbar-Elementen entfernen, sie stören den Scroll-Edge-Effekt **[Doku]**.

**Quellen:** [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views),
[WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/),
[HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials),
[Landmarks-Beispiel](https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass).

## 3. SwiftUI MapKit

**Empfehlung:** Kamera als `MapCameraPosition` im State-Machine-Modell; Polylines direkt aus `Leg.polyline.points`.

**APIs:** `Map(position:interactionModes:content:)`, `MapCameraPosition` (`.automatic`, `.userLocation(followsHeading:fallback:)`,
`.rect(_:)`, `.region(_:)`, `.camera(MapCamera)`, `positionedByUser`), `MapCamera(centerCoordinate:distance:heading:pitch:)`,
`MapPolyline(coordinates:contourStyle:)` + `.stroke(_:style:)`, `UserAnnotation()`, `Annotation`, `mapControls { MapUserLocationButton(); MapCompass(); MapPitchToggle() }`,
`mapStyle(.standard(pointsOfInterest: .excludingAll))`, `onMapCameraChange(frequency: .onEnd)`,
`mapCameraKeyframeAnimator(trigger:keyframes:)`.

```swift
Map(position: $flow.camera) {
    UserAnnotation()
    ForEach(journey.legs, id: \.index) { leg in
        if let line = leg.polyline {
            MapPolyline(coordinates: line.points.map(\.clLocation))
                .stroke(leg.isWalk ? .secondary : leg.lineColor,
                        style: leg.isWalk ? StrokeStyle(lineWidth: 4, lineCap: .round, dash: [1, 7])
                                          : StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        }
    }
}
// Kamerawechsel mit Feder:
withAnimation(Motion.sheet) { flow.camera = .rect(journey.boundingRect.insetBy(...)) }
// Fußweg-Navigation:
flow.camera = .userLocation(followsHeading: true, fallback: .automatic)  // Pitch über MapCamera(pitch: 45) setzen
```

**Fallstricke:**
- Sobald der Nutzer die Karte bewegt, wird die Position `positionedByUser`; Folgemodus danach nicht still zurücksetzen, sondern
  per `MapUserLocationButton` oder „Zentrieren“ **[Doku]**.
- `mapCameraKeyframeAnimator`: eine Geste bricht die Animation sofort ab **[Doku]**. Für die S-Kurve (SPEZIFIKATION 3.2.3) nur
  `SpringKeyframe`/`CubicKeyframe`, kein `LinearKeyframe` (Regel „keine .linear“). Bei Reduce Motion Kamera direkt setzen.
- `.userLocation(followsHeading: true)` gibt keinen festen Pitch vor; für 45 Grad im Fußweg selbst `MapCamera` setzen und beim
  Positions-Update nachführen **[unsicher, im Gerät testen]**.
- Linienfarben aus `line.color` sind beliebige Feed-Farben: für Kontrast (AGENT.md AAA) Fallback auf Modus-Farbe, wenn der Kontrast
  zur Karte nicht reicht; Polyline zusätzlich mit hellem/dunklem Außenstrich zeichnen.
- Viele Koordinaten pro Polyline: Umwandlung in `CLLocationCoordinate2D` einmal im Modell (nicht in `body`) und nicht auf dem
  Main Thread für große Antworten (AGENT.md Checkliste 2).
- `UserAnnotation` und Kartenstandort nutzen CoreLocation des Geräts (keine IP-Ortung); Standortberechtigung kommt vom
  bestehenden `CoreLocationService`. Für die Navigation eine `CLServiceSession` über die ganze Fahrt halten.
- Das Apple-Logo und der „Rechtliches“-Link der Karte müssen sichtbar bleiben; sie folgen dem Safe-Area-Polster **[unsicher]**.

**Quellen:** [MapCameraPosition](https://developer.apple.com/documentation/mapkit/mapcameraposition),
[MapPolyline](https://developer.apple.com/documentation/mapkit/mappolyline),
[mapCameraKeyframeAnimator](https://developer.apple.com/documentation/swiftui/view/mapcamerakeyframeanimator(trigger:keyframes:)),
[WWDC23 Meet MapKit for SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10043/).

## 4. Suche mit Pflichtschalter

**Empfehlung:** Eigenes `TextField` im Sheet-Kopf (kein `.searchable`, das braucht einen `NavigationStack` und setzt das Feld in die
Toolbar). Darunter ein Segmented `Picker` „Adresse / Haltestelle“, sichtbar, ohne Standardwert-Trick. Debounce 300 ms über
`.task(id:)`, Return sucht sofort. Für M3 beim bestehenden `MKLocalSearch` bleiben, kein `MKLocalSearchCompleter`.

```swift
struct SearchKey: Equatable { var text: String; var scope: SearchScope; var submit: Int }

Picker("Suchmodus", selection: $scope) {
    Text("Adresse").tag(SearchScope.address)
    Text("Haltestelle").tag(SearchScope.stops)
}
.pickerStyle(.segmented)

TextField(scope == .stops ? "Haltestelle suchen" : "Adresse oder Ort", text: $text)
    .textContentType(scope == .address ? .fullStreetAddress : nil)
    .submitLabel(.search)
    .onSubmit { submitCount += 1 }
    .task(id: SearchKey(text: text, scope: scope, submit: submitCount)) {
        let immediate = submitCount != lastSubmit
        if !immediate { do { try await Task.sleep(for: .milliseconds(300)) } catch { return } }
        lastSubmit = submitCount
        await flow.search(text, scope: scope)   // ignoriert TransitError.cancelled
    }
```

Im Modus „Haltestelle“ ein Hinweis unter dem Feld: „Der Suchtext geht ohne Standort an den Fahrplan-Server.“ (API.md verlangt den
Hinweis.)

**MKLocalSearchCompleter vs. MKLocalSearch:**
| | `MKLocalSearch` (heute in `MapKitLocalSearch`) | `MKLocalSearchCompleter` |
|---|---|---|
| Gesendet an Apple | Volltext pro entprellter Suche | Teiltexte während des Tippens (eigenes internes Warten) |
| Ergebnis | `MKMapItem` mit Koordinate | nur Text-Vorschläge; Koordinate braucht danach ein zweites `MKLocalSearch(request: .init(completion:))` |
| Region | `region` + `regionPriority = .required` + `resultTypes` (umgesetzt) | `region`, `regionPriority`, `resultTypes`, `addressFilter`, `pointOfInterestFilter` vorhanden **[Doku]** |
| Concurrency | `async start()` | Delegate (NSObject, nicht Sendable), Ergebnisse auf den MainActor bringen |

**Datenschutz-Bewertung:** Beide schicken Text an Apple, nie an das eigene Backend; das erfüllt die Zero-Knowledge-Regel gegenüber
dem Backend. Apple verknüpft Karten-Suchen laut eigener Angabe nicht mit der Apple-ID, sondern mit mehrmals pro Stunde wechselnden
Kennungen; ob MapKit in Dritt-Apps genau dieselben Kennungen nutzt, ist nicht dokumentiert **[unsicher]**. Der Completer schickt
mehr Fragmente (jede Tipp-Pause) und mehr Anfragen. Fazit: Completer bringt bessere Vorschläge, aber mehr Datenabfluss an Apple und
Delegate-Code unter Swift 6. Für M3 nicht nötig; bei Bedarf später mit derselben Region und `.required`.

**Fallstricke:**
- `.task(id:)` bricht die vorige Aufgabe ab, wenn sich `id` ändert oder die View verschwindet; `Task.sleep` wirft dann
  `CancellationError` (sauber beenden, kein Banner). `TransitError.cancelled` aus `SearchService` ebenfalls still ignorieren.
- Spät eintreffende Antworten nur übernehmen, wenn Text und Modus noch stimmen.
- Moduswechsel löst eine neue Suche aus (gewollt), darf aber nie den alten Text im anderen Modus heimlich an das Backend schicken,
  ohne dass der Nutzer gewechselt hat. Der Wechsel ist die ausdrückliche Handlung.
- `textContentType(.fullStreetAddress)` im Adressmodus schlägt Kontakt-Adressen vor (bleibt lokal, ok). Im Haltestellenmodus `nil`,
  damit iOS keine eigenen Adressen anbietet, die dann als Suchtext ans Backend gingen.
- Adressmodus ohne GPS-Fix liefert `locationDenied`/`locationUnavailable`: Inline-Hinweis mit Knopf „Haltestelle suchen“
  (Nutzer wechselt selbst), kein automatischer Wechsel.
- Mindestlänge 2 Zeichen prüft `SearchService` schon; Backend nimmt max. 80 Zeichen (`TextField` begrenzen).
- Standardmodus: „Adresse“ (nichts geht an das eigene Backend). Letzte Wahl darf per `@SceneStorage` gemerkt werden.

**Quellen:** [MKLocalSearchCompleter](https://developer.apple.com/documentation/mapkit/mklocalsearchcompleter),
[Sample: Interacting with nearby points of interest](https://developer.apple.com/documentation/mapkit/interacting-with-nearby-points-of-interest),
[task(id:priority:_:)](https://developer.apple.com/documentation/swiftui/view/task(id:priority:_:)),
[Apple Maps und Datenschutz](https://www.apple.com/legal/privacy/data/en/apple-maps/),
[Forum: pointOfInterestFilter überschreibt resultTypes](https://developer.apple.com/forums/thread/817112) **[Erfahrung]**.

## 5. Token-Eingabe in die Keychain

**Empfehlung:** Kleines Formular-Sheet „Server-Zugang“: `SecureField` plus `PasteButton`, Speichern schreibt über
`KeychainSecretStore().write(Data(token.utf8), for: .apiToken)`, danach Feld leeren. Das Token wird nie wieder angezeigt; die UI
zeigt nur „Token gespeichert“ mit „Ersetzen“ und „Löschen“ (Löschen mit `confirmationDialog`).

```swift
SecureField("API-Token", text: $draft)
    .textContentType(nil)
    .textInputAutocapitalization(.never)
    .autocorrectionDisabled()
    .keyboardType(.asciiCapable)
    .submitLabel(.done)
    .onSubmit(save)
PasteButton(payloadType: String.self) { items in
    if let first = items.first { draft = first.trimmingCharacters(in: .whitespacesAndNewlines) }
}
```

**Fallstricke:**
- `textContentType(.password)` meldet das Feld als Passwort: iOS bietet AutoFill an und fragt ggf. „Passwort sichern?“; dann landet
  das Token im Passwörter-Schlüsselbund (iCloud-Sync, verletzt „ThisDeviceOnly“). Deshalb `nil`. Ob iOS ein `SecureField` ohne
  Content-Type trotzdem heuristisch als Passwort behandelt, auf dem Gerät prüfen **[unsicher]**.
- `PasteButton` liest die Zwischenablage ohne „Einfügen erlauben?“-Dialog, weil der Nutzer selbst tippt **[Doku]**. Programmatisches
  `UIPasteboard.general.string` würde den Dialog auslösen. Apples Beispiel nutzt `strings[0]`, hier `first` (keine Abstürze).
- `privacySensitive()` schwärzt nur bei Redaction-Grund `.privacy` (Widgets/Sperrbildschirm) **[Doku]**; für das `SecureField` bringt
  es nichts. Nicht als Schutz verbuchen.
- Kein „Anzeigen“-Schalter (YAGNI, Schultersurfen). Swift-Strings lassen sich nicht sicher nullen; `draft` nach dem Speichern leeren
  genügt für MASVS-L2 hier.
- Eingabe prüfen: trimmen, Länge und Zeichensatz (ASCII ohne Leerzeichen), sonst Inline-Fehler. Kein Logging.
- Hinweis an den Nutzer: Token nach dem Einfügen aus der Zwischenablage der Quelle (Mac, Universal Clipboard) entfernen; die App
  löscht die Zwischenablage nicht selbst.
- „Verbindung prüfen“ optional über eine Haltestellensuche; verbraucht Rate-Limit, also nur auf Knopfdruck. `UNAUTHORIZED` direkt im
  Formular zeigen.

**Quellen:** [SecureField](https://developer.apple.com/documentation/swiftui/securefield),
[PasteButton](https://developer.apple.com/documentation/swiftui/pastebutton),
[privacySensitive(_:)](https://developer.apple.com/documentation/swiftui/view/privacysensitive(_:)),
[Forum: Strong-Password-AutoFill](https://developer.apple.com/forums/thread/716589) **[Erfahrung]**.

## 6. Navigations-State-Machine

**Empfehlung:** Ein `@Observable @MainActor final class AppFlow` mit einem Phasen-Enum und einer reinen Übergangsfunktion
(ohne SwiftUI, ohne Seiteneffekte), damit Swift Testing die Logik ohne Simulator prüft. Asynchrone Arbeit (Suche, Planung) hält das
Modell als `Task`, der bei jedem Phasenwechsel abgebrochen wird.

```swift
enum Phase: Equatable {
    case start
    case search(SearchScope)
    case routeSelection(RouteSelection)        // Skelett, dann kalibriert (HybridRouteCalculator.Stage)
    case navigation(NavigationStep)            // SPEZIFIKATION 4.2
    case arrival
}
enum NavigationStep: Equatable {
    case approachingFirstStop, waitingAtPlatform, onBoardTransit, transferRouting, finalWalkToDestination
}
enum Event { case searchTapped, cancel, endpointsChosen(ManualTripRequest), routesLoaded(...), journeySelected(Int),
             startTapped, geofence(...), arrived, failed(TransitError) }

static func next(_ phase: Phase, _ event: Event) -> Phase?   // nil = ungültiger Übergang, ignorieren

@Observable @MainActor final class AppFlow {
    private(set) var phase: Phase = .start
    var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    var banner: TransitError?
    @ObservationIgnored private var work: Task<Void, Never>?
    // Animation kommt aus der View (die kennt accessibilityReduceMotion), das Modell bleibt SwiftUI-frei testbar.
    func send(_ e: Event, animation: Animation? = nil) {
        guard let n = Self.next(phase, e) else { return }
        work?.cancel()
        withAnimation(animation) { phase = n }
    }
}
```

**Übergänge und Animation:**
- Konstanten laut AGENT.md 4.3 (`Motion.standard`, `Motion.micro`, `Motion.momentum`). Kein `.linear`, auch nicht in
  Keyframes.
- Reduce Motion: `@Environment(\.accessibilityReduceMotion)`; dann `.transition(.opacity)` statt `.move`/Morphing und Kamera ohne
  Fahrt setzen (AGENT.md 4.3.3).
- `matchedGeometryEffect` nur innerhalb derselben Hierarchie: Hero Card und kompakte Navigationsleiste liegen beide im Sheet, dort
  morpht die Leg-Bar. Das Guidance Banner oben (Map-Ebene) blendet per `.transition(.move(edge: .top).combined(with: .opacity))`
  ein **[Erfahrung]**. Alternative bei Glass-Elementen: `glassEffectID` im selben `GlassEffectContainer`.
- Zahlen: `Text(minutes, format: .number).monospacedDigit().contentTransition(.numericText(countsDown: true))` plus
  `.animation(Motion.micro, value: minutes)`. Ohne Animation rollt nichts **[Doku: „in certain environments“]**.
- Haptik: `.sensoryFeedback(.selection, trigger: detent)`, `.warning` über einen Zähler `platformChanges` bzw. Puffer < 90 s,
  `.success` bei Ankunft an Einstiegs-/Umsteigehalt. Trigger muss sich ändern; gleiche Werte lösen nichts aus.

**Fallstricke:**
- `@Observable` und `@MainActor` gemeinsam: Services (`SearchService`, `HybridRouteCalculator`, `TransitAPIClient`) sind `Sendable`
  bzw. ein Actor, Aufrufe aus dem MainActor sind unkritisch. Ergebnisse vor dem Zuweisen auf die aktuelle Phase prüfen (veraltete
  Antworten nach Abbruch).
- `HybridRouteCalculator.plan` liefert einen `AsyncThrowingStream`: im Modell mit `for try await stage in` konsumieren; Abbruch des
  Tasks beendet den Stream (`onTermination`).
- Geofences (`CLCircularRegion`) sind für Region-Monitoring gedacht; in iOS 18+ ist `CLMonitor` der Nachfolger. Für die laufende
  Navigation reicht Distanzprüfung im Live-Stream (`CLLocationUpdate.liveUpdates`) **[Erfahrung]**. Navigation-Unterzustände erst
  nach dem schmalen Testbildschirm bauen.
- Hintergrund: Navigation bei gesperrtem Gerät braucht Background-Location-Mode; das ist eine eigene Privacy-Entscheidung (M3 nur
  Vordergrund) **[Vorschlag]**.

**Quellen:** [Observation](https://developer.apple.com/documentation/observation),
[Migrating to @Observable](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro),
[numericText(countsDown:)](https://developer.apple.com/documentation/swiftui/contenttransition/numerictext(countsdown:)),
[sensoryFeedback](https://developer.apple.com/documentation/swiftui/view/sensoryfeedback(_:trigger:)),
[matchedGeometryEffect](https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect(id:in:properties:anchor:issource:)),
[CLMonitor](https://developer.apple.com/documentation/corelocation/clmonitor).

## 7. Fehler- und Leerzustände

**Empfehlung:** Ein `InlineBanner` oben im Sheet (`safeAreaInset(edge: .top)`), gespeist aus `TransitError.errorDescription`
(Texte existieren schon im String Catalog). Keine `Alert`s. Leere Ergebnisse als `ContentUnavailableView`.

| Fehler | Darstellung | Aktion |
|---|---|---|
| `rateLimited` | Banner mit Restzeit aus `TransitAPIClient.blocked?.until` (`Text(timerInterval:)` oder Minuten mit `numericText`) | Suche/Buttons bis dahin deaktiviert, kein Auto-Retry-Hämmern |
| `offline`, `upstreamUnavailable`, `upstreamTimeout` | Banner, letzte Ergebnisse bzw. `CachedStop` weiter zeigen | „Erneut versuchen“ |
| `missingToken`, `unauthorized` | Banner | „Token eintragen“ öffnet Abschnitt 5 |
| `locationDenied` | Banner im Adressmodus | „Einstellungen“ (`openURL(UIApplication.openSettingsURLString)`) |
| `noConnections` | `ContentUnavailableView("Keine Verbindung gefunden", systemImage: "tram")` | „Spätere Verbindungen“ (`laterRef`) |
| `refreshExpired`, `notFound` | Banner | „Neu suchen“ |
| `pinningFailed` | Banner, keine Details | keine Umgehung anbieten |
| `cancelled` | nichts | – |

**Fallstricke:**
- Banner bei VoiceOver ansagen: `AccessibilityNotification.Announcement(text).post()`.
- Banner nicht automatisch ausblenden, solange der Zustand gilt (Offline, Rate-Limit). Nur bei Erfolg entfernen.
- `waitsForConnectivity` (bis 45 s) wirkt wie ein Hänger: nach ca. 3 s „Warte auf Verbindung“ anzeigen **[Vorschlag]**.
  `NWPathMonitor` ist dafür nicht nötig.
- `removedLongDistance > 0`: dezenter Hinweis „Einige Verbindungen ausgeblendet“ mit „Spätere Verbindungen“.
- `ContentUnavailableView.search(text:)` für leere Suche.

**Quellen:** [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview),
[HIG Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback),
[HIG Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts),
[AccessibilityNotification.Announcement](https://developer.apple.com/documentation/accessibility/accessibilitynotification/announcement).

## 8. Quellenangabe

**Anforderung:** Transitous: „Link to https://transitous.org/sources/ in a visible place“ und die Bedingungen der Quellen einhalten;
für OSM gelten deren Attribution Guidelines. OSM: Nennung muss ohne Interaktion sichtbar sein und nahe am Ergebnis; Lizenzdetails
dürfen zusätzlich in „Über“/„Datenlizenzen“ stehen, aber nicht nur dort.

**Empfehlung (zwei Stufen):**
1. **Fußzeile unter der Verbindungsliste und den Haltestellen-Treffern** (immer sichtbar, `.footnote`, `.secondary`):
   „Fahrplandaten: Transitous · © OpenStreetMap-Mitwirkende“, beide als `Link`. Text kommt aus `attribution` der Antwort (API.md), nicht
   hart kodiert.
2. **Screen „Quellen und Lizenzen“** (aus dem Einstellungs-/Info-Sheet und per Tipp auf die Fußzeile): Transitous-Quellenliste,
   OSM-Copyright/ODbL, Hinweis auf Apple Maps (Fußwege), Link zum Quellcode, sobald öffentlich.

**Fallstricke:** Apple-Karten-Logo und „Rechtliches“ nicht verdecken (Abschnitt 3). Links mit `Link(destination:)` öffnen Safari
außerhalb der App; das ist ok und ohne Tracking. `attribution.links` aus der Antwort vor dem Anzeigen auf `https` prüfen.

**Quellen:** [Transitous API-Regeln](https://transitous.org/api/), [Transitous-Quellen](https://transitous.org/sources/),
[OSM Attribution Guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines),
[OSM Copyright](https://www.openstreetmap.org/copyright).

## 9. Accessibility

**Empfehlung:**
- Dynamic Type nur mit Text-Styles (`.body`, `.headline`, `.footnote`), keine festen Größen. Obergrenze an der Wurzel:
  `.dynamicTypeSize(...DynamicTypeSize.accessibility3)` (AGENT.md 4.3.3).
- Leg-Bar: `ViewThatFits(in: .horizontal) { HStack { legs }; VStack(alignment: .leading) { legs } }`. Alternative mit stabiler
  Identität (besser für Animationen): `let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout()) : AnyLayout(HStackLayout())`.
- Hero Card und jede Verbindungszeile: `.accessibilityElement(children: .ignore)` plus selbst gebauter `accessibilityLabel`
  (Funktion im Modell, testbar), z. B. „Beste Verbindung: In 7 Minuten losgehen. 6 Minuten Fußweg, dann Straßenbahn 4 Richtung
  Hauptbahnhof. Pünktlich.“ Start als `accessibilityAction(named: "Navigation starten")`.
- Zeiten im Label als Wörter/Formatter (`Date.FormatStyle`, `Duration.UnitsFormatStyle`), nicht „7′“ oder „+3“.
- Linienfarbe nie allein als Information: Liniennummer und SF Symbol (`tram.fill`, `bus.fill`, `train.side.front.car`) immer mit.
- Touch-Flächen min. 44 x 44 pt; `.contentShape(.rect)`.

**Fallstricke:** `ViewThatFits` misst nur die angebotene Breite; in `ScrollView(.horizontal)` passt immer alles. `.combine` liest
Kind-Texte in Layout-Reihenfolge und klingt oft holprig, daher `.ignore` + eigenes Label. Die Karte ist für VoiceOver kaum nutzbar;
jede Information muss auch im Sheet stehen. Prüfen mit Accessibility Inspector und Xcode-Previews mit `.environment(\.dynamicTypeSize, .accessibility3)`.

**Quellen:** [ViewThatFits](https://developer.apple.com/documentation/swiftui/viewthatfits),
[DynamicTypeSize](https://developer.apple.com/documentation/swiftui/dynamictypesize),
[HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
[accessibilityElement(children:)](https://developer.apple.com/documentation/swiftui/view/accessibilityelement(children:)).

## 10. Teststrategie (Xcode 26)

**Empfehlung, drei Ebenen:**
1. **Swift Testing (schnell, ohne UI):** `AppFlow.next(_:_:)` als Tabelle (`@Test(arguments:)`), Debounce-/Abbruchlogik,
   Banner-Zuordnung `TransitError -> Darstellung`, VoiceOver-Label-Builder, Farbkontrast der Modus-Farben. `@MainActor` auf Suiten,
   die `AppFlow` anfassen.
2. **Previews mit Fakes:** App-Protokolle `StopSearching`/`RoutePlanning` (Befund 0.4) mit Fake-Implementierungen und JSON aus
   `TransitCoreTests/Fixtures`; `#Preview` mit `@Previewable @State`. Previews für Light/Dark, `.accessibility3`, Reduce Motion,
   Fehlerzustände.
3. **UI-Tests (XCUITest, weiterhin XCTest):** wenige Pfade: Token speichern, Suchmodus wechseln, Verbindungsliste sichtbar,
   Quellen-Link vorhanden. Fakes per Launch-Argument (`-uiTestFakes`), Fake-Code nur unter `#if DEBUG`, damit Release nie ohne
   Pinning spricht. `accessibilityIdentifier` für Kernelemente.

**Befehl (bewährt auf diesem Mac, STATUS M2):**
```bash
xcodebuild test -project ios/TransitPlanner.xcodeproj -scheme TransitPlanner \
  -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO
```

**Fallstricke:**
- Ohne `-parallel-testing-enabled NO` hing der Test-Runner beim Start (Simulator, nicht Code) **[Erfahrung, STATUS]**. Bei weiteren
  Hängern: `xcrun simctl shutdown all && xcrun simctl erase all` und `-test-timeouts-enabled YES`.
- Standort-Dialog im Simulator vorab erlauben: `xcrun simctl privacy booted grant location de.carlojansen.transitplanner`, sonst blockiert
  der Systemdialog UI-Tests. Standort per `simctl location` oder GPX setzen.
- `SecureField` im UI-Test über `app.secureTextFields`; Hardware-Tastatur des Simulators kann Eingaben stören.
- Swift Testing kann keine UI-Automation; XCUITest bleibt XCTest **[unsicher, ob Xcode 26 das geändert hat]**.
- Keychain-Tests brauchen den App-Host (`-34018` ohne Host, STATUS M2); UI-Token-Tests daher im App-Target.
- Kein Live-Server in Tests (Rate-Limits, Transitous-Regeln).

**Quellen:** [Swift Testing](https://developer.apple.com/documentation/testing),
[Previews in Xcode](https://developer.apple.com/documentation/xcode/previewing-your-apps-interface-in-xcode),
[XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation),
[WWDC24 Meet Swift Testing](https://developer.apple.com/videos/play/wwdc2024/10179/).

---

## Vorschlag Reihenfolge für Meilenstein 3

1. **Schmaler Testbildschirm (ohne Design, nur Systemkomponenten):**
   a) Token-Sheet (Abschnitt 5) mit Keychain-Speichern, Status, Löschen.
   b) Suche mit Pflichtschalter „Adresse / Haltestelle“, Debounce 300 ms und Return (Abschnitt 4), Treffer als `List`.
   c) Start/Ziel wählen, Verbindungsliste aus `HybridRouteCalculator.plan` (erst Skelett, dann kalibrierte Gehzeiten).
   d) Fußzeile mit Quellenangabe und Screen „Quellen und Lizenzen“ (Abschnitt 8).
   e) Inline-Banner für alle `TransitError` (Abschnitt 7).
   Danach erster Live-Test gegen den Server und Security-Review. Damit ist auch der offene Punkt „Token-Eingabe braucht UI“ aus
   STATUS erledigt.
2. **`AppFlow` (State-Machine) mit Swift-Testing-Tabelle** für Start, Suche, Routenauswahl; Navigation zunächst als Platzhalter.
3. **Map-Basis:** persistente `Map`, Sheet mit drei Detents, `safeAreaPadding`-Kopplung, Polylines in Linienfarben, Kamera auf Route.
4. **Design laut Figma:** Hero Card mit Leg-Bar, Alternativen, Top-Chrome in `GlassEffectContainer`, Animationen und Haptik,
   Reduce Motion, Dynamic Type bis `accessibility3`, VoiceOver-Labels. Vorher Figma anpassen: Screen „2 Suche“ auf einen Modus pro Suche
   mit Segmented Control und 300 ms umbauen; Quellenangabe-Screen und Fehlerzustände ergänzen (fehlen laut STATUS).
5. **Navigation:** Unterzustände aus SPEZIFIKATION 4.2 mit Live-Standort, Guidance Banner, Kamera-Keyframes, Ankunft.
6. **Review und Abschluss:** `security-hig-reviewer`, `docs/STATUS.md`, Freigabe durch Carlo. Vorab entscheiden: AGENT.md 4.1
   (Glass statt Materialien) und eine Spring-Konstante (Befunde 0.1 und 0.2).
