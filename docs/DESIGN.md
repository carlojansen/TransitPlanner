# Design-Spezifikation (aus Figma, Stand 25.10.2026, freigegeben)

Quelle: Figma-Datei "TransitPlanner – Design-Plan", Frame "Screens nach Ablauf" (Zeilen A bis H). Diese Datei ist die
Bau-Vorlage für Meilenstein 3 bis 5, damit die Umsetzung ohne Figma-Zugriff auskommt. Bei Widerspruch gilt: AGENT.md (Regeln)
vor DESIGN.md (Aussehen) vor Figma (Bild). Referenzgerät: iPhone 17, 402 x 874 pt.

## 1. Farben (Asset Catalog, Any/Dark)

| Token | Hell | Dunkel | Verwendung |
|---|---|---|---|
| bg/map | #E9EDF0 | #1B1E21 | Platzhalter Karte (nur Previews) |
| surface/sheet | #F2F2F7 | #1C1C1E | Sheet-Inhalt bei .large (sonst System-Glass) |
| surface/card | #FFFFFF | #2C2C2E | Karten, Listen, ausgewähltes Segment |
| label/primary | #000000 | #FFFFFF | = .primary |
| label/secondary | #6C6C70 | #AEAEB2 | = .secondary; HC: #505053 / #C7C7CC; Quellen-Fußzeile in dieser festen Farbe |
| label/onAccent | #FFFFFF | #000000 | Text/Symbole auf Modusfarben (Dunkel: schwarz, Kontrast) |
| fill/tertiary | #E3E3E8 | #3A3A3C | Skelett, Chips aus |
| separator | #C6C6C8 | #38383A | 0,5-pt-Rand an Karten ohne Glass |
| accent/blue | #0062CC | #409CFF | Tint, Hauptknopf; HC: #004A9B / #8AC3FF |
| button/fill | #0062CC | #006FE7 | Fläche Hauptknopf (Text button/label #FFFFFF, mind. 4,5:1); HC: #0054B0 / #0054AF |
| accent/blueTint | #E0EDFF | #14304F | Info-Banner |
| status/ok | #1F7A35 | #30D158 | pünktlich, Puffer ok; HC: #175A27 / #40D565 |
| status/okTint | #E1F4E5 | #16301D | |
| status/warn | #A34A00 | #FFB340 | Verspätung, Gleiswechsel, knapper Puffer; HC: #7F3A00 / #FFB340 |
| status/warnTint | #FFEBD6 | #3D2A12 | Karten-Hinweis Warnung |
| status/alert | #D70015 | #FF6961 | Ausfall, Meldung, Puffer reicht nicht; HC: #A20010 / #FFA29D |
| status/alertTint | #FFEBEB | #401212 | Karten-Hinweis Kritisch |
| mode/tram | #B20011 | #FF645B | HC: #91000E / #FF8F89 |
| mode/sbahn | #1A642C | #27AE48 | HC: #155024 / #2DC953 |
| mode/ubahn | #0042E5 | #3B9AFF | HC: #0035B9 / #6BB3FF |
| mode/bus | #793C98 | #CE6CFF | Bus und Ersatzverkehr (SEV); HC: #613079 / #DB91FF |
| mode/regio | #8F4000 | #DA8300 | RE/RB; HC: #733300 / #FB9700 |
| mode/walk | #57575A | #97979C | Fußweg (gepunktet); HC: #454548 / #AFAFB2 |

Linien-Badges (Text label/onAccent auf Modusfarbe) erreichen mindestens 7:1, bei Hohem Kontrast (HC, Hell / Dunkel) mindestens 9:1; Hinweisfarben auf ihrer Tint-Fläche und status/ok auf surface/card mindestens 4,5:1, bei HC mindestens 7:1. Geprüft durch `ColorContrastTests` aus den Asset-Werten.

Farbe ist nie die einzige Information: Linienname, Symbol oder Text immer dazu.

## 2. Schrift (nur Text-Styles, Dynamic Type bis accessibility3)

| Figma-Stil | SwiftUI |
|---|---|
| iOS/Large Title, Title 2, Title 3, Headline, Body, Callout, Subheadline, Footnote, Caption 1/2 | `.largeTitle`, `.title2`, `.title3`, `.headline`, `.body`, `.callout`, `.subheadline`, `.footnote`, `.caption`, `.caption2` (Semibold-Varianten mit `.weight(.semibold)`) |
| App/Countdown (Rounded Bold 34/41) | `.largeTitle.bold()` + `.fontDesign(.rounded)` + `.monospacedDigit()` |
| App/Countdown Klein (Rounded Semibold 17/22) | `.headline` + `.fontDesign(.rounded)` + `.monospacedDigit()` |
| App/Anweisung (Rounded Bold 28/34) | `.title.bold()` + `.fontDesign(.rounded)`. **Alle Überschriften der Jetzt-Karte (4 bis 4f) und "Losgehen 12:52" (D1) einheitlich in diesem Stil, nicht größer.** |
| App/Kennzahl (Rounded Semibold 22/26) | `.title2.weight(.semibold)` + `.fontDesign(.rounded)` + `.monospacedDigit()` |

Zeiten, Minuten, Meter: immer `.monospacedDigit()` und `.contentTransition(.numericText(countsDown: true))` mit `.animation(Motion.micro, value:)`.

## 3. Maße

- Raster 4 pt: 4 / 8 / 12 / 16 / 24. Ausnahmen: 2 pt in Linien-Badges, 11 pt Innenabstand in 44-pt-Zeilen.
- Seitenrand im Sheet und für Karten: 16 pt. Karten 370 pt breit auf dem Referenzgerät, also volle Breite minus 2 x 16.
- Radien (`.rect(cornerRadius:style: .continuous)`): Badge 6, Karten-Hinweis 12, Inline-Banner 14, Karte 16, Jetzt-Karte 22, Hauptknopf Kapsel.
- Touch-Ziel mindestens 44 x 44 pt (`.contentShape(.rect)`).
- Sheet-Detents: `.height(140)` (Start), `.fraction(0.5)` (Routenauswahl, 2c), `.large` (Suche, Details, Einstellungen).
  Die Quellenangabe muss im mittleren Detent sichtbar bleiben; in Figma braucht das 474 pt Sheet-Höhe. Ist die Liste länger,
  steht die Fußzeile direkt unter der Hero Card statt am Listenende.
- Unterwegs: Danach-Sheet in allen Zuständen fest 237 pt (`.height(237)`), damit die Karte nicht springt.

## 4. Komponenten

| Komponente | Aufbau | Maße |
|---|---|---|
| Hauptknopf | in Karten und Inhalt `.buttonStyle(.borderedProminent)` mit Kapsel; `.glassProminent` nur schwebend über der Karte (AGENT 4.1.1: kein Glass im Inhalt), Titel `.headline` | 50 pt hoch, volle Breite, Zustände Aktiv / Deaktiviert (`.disabled`) |
| Karten-Button | Glass-Knopf mit SF Symbol, Stapel oben rechts in `GlassEffectContainer`: Standort, Statistik, Erinnerungen | 44 x 44, Abstand 8 |
| Listenzeile | Symbol in Modusfarbe, Titel `.body`, Untertitel `.footnote` `.secondary`, Zusatz rechts `.footnote` | 60 pt hoch, Innenabstand 12/16, Abstand 12 |
| Einstellungszeile | Titel `.body`, Wert `.secondary`, optional Chevron | 44 pt hoch (11/16) |
| Linien-Badge | Linienname `.caption2` semibold auf Modusfarbe, `label/onAccent` | Innenabstand 2/6, Radius 6 |
| Fußweg-Chip | `figure.walk` + Minuten | |
| Verspätung | "+3 Min." in status/warn auf warnTint, pulsiert einmal (PhaseAnimator), nur bei Echtzeit | |
| KPI-Kachel | Titel `.footnote`, Wert App/Kennzahl, Trend `.caption` | M5 |
| Karten-Hinweis | Text `.subheadline` semibold, Varianten Warnung (warnTint/warn) und Kritisch (alertTint/alert) | Radius 12, Innenabstand 8/12, volle Kartenbreite |
| Inline-Banner | SF Symbol + Text, oben im Sheet via `safeAreaInset(edge: .top)`; 9 Typen: Rate-Limit, Offline, Server, Warten, Token, Standort, Abgelaufen, Sicherheit, Ausgeblendet | Radius 14, Innenabstand 12 |
| Sheet-Grabber | System (`presentationDragIndicator(.visible)`) | |

## 5. Screens und Verhalten

### A Einstieg und Zugang (nur einmal bzw. aus den Einstellungen)

**A1 Erster Start**
- Nur beim allerersten Start. Ein Bildschirm, kein Karussell (HIG Onboarding: kurz, überspringbar).
- "Weiter" löst den System-Dialog "Beim Verwenden der App" aus (CLServiceSession). Danach A2, falls kein Schlüssel in der Keychain liegt, sonst 1 Start.
- "Ohne Standort fortfahren": App bleibt nutzbar, Adresssuche und Umkreis sind dann aus (Hinweis im Adressmodus, siehe 2b).
- Mitteilungen werden hier nicht abgefragt, erst beim Scharfschalten der ersten Erinnerung (D1).
- Symbole: location.fill, tram.fill, bell.badge (hierarchical, accent/blue).

**A2 Dein Server, Schlüssel eintragen**
- Klartext statt Fachbegriff: "Dein Server" und "Schlüssel" statt "Server-Zugang" und "API-Token". Der Screen erklärt in zwei Sätzen, warum es ihn gibt.
- Einmalig nach A1, später nur über Einstellungen > Dein Server (z. B. nach einem Schlüsselwechsel auf dem Server).
- SecureField ohne textContentType, PasteButton, Prüfung 32 bis 512 Zeichen ASCII, Keychain ThisDeviceOnly, kein Logging, kein "Anzeigen".
- Kein fest eingebauter Schlüssel (MASVS: alles in der App lässt sich auslesen). Später ersetzt App Attest den Schlüssel.

**A2 Dein Server, Gespeichert**
- Der Schlüssel erscheint nie wieder, nur der Status. "Schlüssel ersetzen" führt zurück zur Eingabe.
- "Verbindung prüfen" nur auf Knopfdruck; Ergebnis inline unter der Zeile (verbunden / UNAUTHORIZED / offline).
- "Schlüssel löschen" mit confirmationDialog (destruktive Rolle), kein Alert.

### B Planen (alles im persistenten Sheet über der Karte)

**1 Start**
- Karte ist Ebene 0, vollflächig; `safeAreaPadding` koppelt an die Sheet-Höhe.
- Oben links: Status-Indikator (GPS-Genauigkeit, aktiver Verkehrsmittel-Filter). Oben rechts: Kartenknöpfe als Stapel Standort, Statistik, Erinnerungen (44 x 44, `.buttonStyle(.glass)`, `GlassEffectContainer`, 8 pt Abstand).
- System-Sheet ohne `presentationBackground` (Liquid Glass kommt automatisch), Detents height(140) / fraction(0.5) / large, `.sensoryFeedback(.selection)` beim Einrasten.
- Rechts neben dem Suchfeld: Einstellungsknopf (G1), kein dritter schwebender Knopf.
- Daumenzone: alle primären Aktionen unten im Sheet. Pre-Fetching: Haltestellen im Umkreis 500 m beim Öffnen.
- Favoriten (Zuhause, Uni, Arbeit) lokal in SwiftData, Koordinaten verschlüsselt.

**2 Suche (Modus Haltestelle)**
- Suchmodus ist Pflicht: Segmented Control "Adresse / Haltestelle" direkt unter der Suchleiste, nie beide Quellen parallel. Haltestelle: /api/locations ohne Standort. Debounce mindestens 300 ms oder Suche bei Return.
- 0-ms-Vorschläge aus dem SwiftData-Cache (letzte Suchen, Favoriten), bevor das Netz antwortet.
- Ergebnis-Zeilen (Listenzeile): Liniensymbol in Modusfarbe; Liste scrollt unter der Suchleiste (Scroll-Edge-Effekt).
- Laufende Suche: `.symbolEffect(.variableColor.iterative)` am Lupen-Symbol. Fehler als Inline-Banner.
- Erreicht über das Sheet (Detent large), kein neuer Screen.

**2b Suche, Modus Adresse**
- Standardmodus beim ersten Öffnen ist "Adresse" (nichts geht an das eigene Backend); die letzte Wahl merkt sich `@SceneStorage`.
- MKLocalSearch (nicht der Completer) mit Region aus dem GPS-Fix und `regionPriority = .required`; `textContentType(.fullStreetAddress)` nur in diesem Modus.
- Ohne GPS-Fix oder Berechtigung: Inline-Banner "Adresssuche braucht deinen Standort" mit "Einstellungen" und "Haltestelle suchen". Kein automatischer Moduswechsel.
- Beim Wechsel auf "Haltestelle" wird das Suchfeld geleert; ein Adresstext geht nie an das Backend.
- Tipp auf einen Ort: Ziel gesetzt, Sheet auf fraction(0.5), Routensuche startet (3a).

**2c Von/Nach und Zeit**
- Über "Jetzt" im Kopf der Routenauswahl oder Tipp auf Von/Nach. Gleiches Sheet, fraction(0.5).
- "Von" ist standardmäßig der GPS-Standort (mit Genauigkeit); Tipp öffnet die Suche für einen anderen Start. Tauschen dreht Von und Nach (Motion.micro, `.sensoryFeedback(.selection)`).
- Abfahrt/Ankunft (Segmented) + kompakter DatePicker (ISO-8601 an das Backend). Verkehrsmittel-Chips = Produktfilter; Auswahl wird als Standard in den Einstellungen gemerkt.
- Chip aus = Kontur + blasser Punkt, an = gefüllt; Name immer sichtbar. Mindestens 44 pt Höhe über `contentShape`.
- Ändern einer Option sucht nicht sofort neu; erst "Verbindungen suchen" (Hauptknopf).

**3a Routenauswahl, Laden**
- Sofort nach "Verbindungen suchen" bzw. Tipp auf ein Ziel: Sheet auf fraction(0.5), Skelett in fester Höhe (Zeilen wie die echte Liste).
- Symbol im Kopf mit `.symbolEffect(.variableColor.iterative)`; Skelett mit `.redacted(reason: .placeholder)`, kein eigenes Shimmer.
- Stufe 1: /api/routes liefert Verbindungen, Hero Card blendet per Motion.standard ein (Gehzeiten geschätzt, "ca."). Stufe 2: MKDirections-Gehzeiten kalibriert, Zahlen rollen per numericText.
- Nach ca. 3 s ohne Antwort: Zeile "Warte auf Verbindung" (waitsForConnectivity), Abbrechen möglich. Fehler als Inline-Banner.
- VoiceOver: "Verbindungen werden gesucht" als Announcement, nicht jede Skelett-Zeile vorlesen.

**3 Routenauswahl**
- Parallel: /api/routes + MKDirections für alle Fußwege; Skelett sofort, exakte Gehzeiten blenden progressiv ein.
- Hero Card: Eyebrow "BESTE VERBINDUNG", Countdown "Los in 7 Min." (App/Countdown), Zeile Uhrzeiten/Dauer/Umstiege, Leg-Bar, Hinweiszeile (z. B. Gleiswechsel), Hauptknopf "Starten". Verspätung als Badge (pulsiert einmal, nur bei Echtzeit).
- Leg-Bar: Fußweg-Chip › Linien-Badge › Fußweg-Chip. Bei großer Schrift per ViewThatFits/AnyLayout vertikal.
- Gleiswechsel (platformChanged) → `.sensoryFeedback(.warning)`.
- "Starten": Leg-Bar morpht per matchedGeometryEffect innerhalb des Sheets; Elemente oben über der Karte blenden per `.move(edge: .top)` + `.opacity` ein (über die Sheet-Grenze geht matchedGeometryEffect nicht).
- Alternativen darunter als Zeilen (Uhrzeiten, Badges, Status, Dauer), 46 pt hoch.
- VoiceOver Hero Card: "Beste Verbindung: In 7 Minuten losgehen. 6 Minuten Fußweg, dann RE 5 Richtung Koblenz, 3 Minuten verspätet. Gleis 7."
- Quellenangabe Transitous + OSM sichtbar (Nutzungsregel).

**3 Routenauswahl, Dark**
- Dark-Tokens; Modusfarben in hellen Varianten. 0,5-pt-Rand (separator) nur an Inhaltskarten ohne Glass, nicht am Sheet.

**3e Routenauswahl, Ersatzverkehr**
- SEV schon bei der Auswahl sichtbar: SEV-Badge in mode/bus in der Leg-Bar und eine rote Zeile, wo der Bus abfährt.
- Gesamtzeit enthält den Bus; Alternativen ohne SEV stehen darunter, auch wenn sie etwas länger dauern.
- Erkennung im Backend (`replacement: true` am Abschnitt, API v0.3). Meldungstext aus `remarks`.
- VoiceOver: "Achtung, Ersatzverkehr: Bus statt RE 5 bis Leverkusen Mitte, Abfahrt Breslauer Platz."

**3d Fahrtdetails**
- Tipp auf Hero Card oder Alternative öffnet die Details im selben Sheet (Detent .large, Zustand der State-Machine, kein Push). Zurück: "Verbindungen" oder Sheet nach unten ziehen.
- Zeitleiste: Zeitspalte monospacedDigit, Echtzeit darunter in status/warn; Schiene in Linienfarbe für Fahrten, gepunktet (mode/walk) für Fußwege.
- Gleiswechsel: neues Gleis hervorgehoben + "statt 10"; `.sensoryFeedback(.warning)` beim Eintreffen, Puls einmalig.
- "4 Zwischenhalte" klappt per Motion.micro auf (DisclosureGroup); Fußweg-Zeilen zeigen die kalibrierte Gehzeit.
- Unten in der Daumenzone: "Erinnern" (öffnet D1) und "Starten" (Navigation). Quellenangabe unter der Zeitleiste.
- VoiceOver: jede Station ein Element ("13 Uhr 10, Köln Hauptbahnhof, Gleis 7 statt 10, 3 Minuten später, RE 5 Richtung Koblenz").

### C Unterwegs (Information zuerst)

Aufbau in allen Zuständen gleich: oben die **Jetzt-Karte** (Glass, Radius 22, 16 pt Rand, Innenabstand 16, Abstand 6):
Eyebrow (`.caption2`, Versalien) → Überschrift (App/Anweisung, einheitlich 28 pt, nicht größer) → eine Zeile Kontext
(`.subheadline` `.secondary`) → genau drei Zahlen (Beschriftung `.caption`, Wert App/Kennzahl) → optional Karten-Hinweis.
Mitte die Karte nur als Kontext. Unten das Danach-Sheet (fest 237 pt) mit den nächsten Schritten, "Beenden" als Text.
Keine Leg-Bar, keine Kartenknöpfe, kein Aktualisieren-Knopf.

| Zustand | Eyebrow | Überschrift | Drei Zahlen |
|---|---|---|---|
| 4 Fußweg zum Gleis | ZU FUSS ZUM GLEIS | nächste Wegänderung ("In 80 m links") | Abfahrt, Noch, Puffer |
| 4b Am Gleis | AM GLEIS | "Gleis 7" + Linien-Badge mit Richtung | Abfahrt, Noch, Fahrt |
| 4c Im Zug | IM RE 5 RICHTUNG ... | "Aussteigen in 3 Halten" | Ankunft, Noch, Danach |
| 4d Umstieg | UMSTIEG IN ... | "Gleis 11 → Gleis 2" | Ab, Noch, Puffer |
| 4e Ersatzverkehr | ERSATZVERKEHR STATT RE 5 | "Bus vor dem Bahnhof" + SEV-Badge | Abfahrt, Noch, Fahrt |
| 4f Ankunft | ANGEKOMMEN | Zielname | Unterwegs, Zu Fuß, Verspätung |

**4 Fußweg zum Gleis**
- Puffer = Zeit, die übrig bleibt, wenn du im gelernten Tempo gehst. Grün ab 2 Min., orange unter 90 s (mit `.warning`), rot, wenn es nicht mehr reicht; dann bietet die Karte direkt die nächste Verbindung an.
- Wegbeschreibung im Bahnhof aus `steps` (API v0.3): direction inkl. stairs/elevator und fromLevel/toLevel, daraus Texte wie "Treppe hoch zu Gleis 7 (1 Ebene)". MKDirections nur außerhalb von Bahnhöfen.
- Karte: eigene Position, gepunkteter Weg, Pin "Gleis 7" an der Koordinate des Bahnsteig-Halts.
- Danach-Sheet: die nächsten drei Schritte mit Zeit. Aktualisieren automatisch (60 s, 20 s vor Umstieg).

**4b Am Gleis**
- Am Gleis zählt nur: welches Gleis, welcher Zug, wann.
- Gleis aus `departurePlatform`/`plannedDeparturePlatform`. Weichen beide ab: Hinweis "nicht Gleis 10", `.sensoryFeedback(.warning)`, Live Activity wird mitgezogen.
- Fällt der Zug aus oder kommt eine Meldung, ersetzt sie den Hinweis (Kritisch) mit Text des Betreibers und "Nächste Verbindung".
- Wagenreihung, Abschnitt und Auslastung zeigt die App nicht (liefert Transitous nicht).

**4c Im Zug**
- Wann aussteigen: die Karte zählt die Halte bis zum Ausstieg herunter; das Danach-Sheet zeigt die restlichen Halte mit Zeiten (stopovers).
- Einen Halt vorher: Haptik und Mitteilung "Nächster Halt aussteigen", auch bei gesperrtem Gerät über die Live Activity (M4).
- Verspätung ändert die Ankunft per numericText; Anschluss in Gefahr → Hinweis Kritisch mit Alternative.
- Ausstiegsseite ist nicht bekannt und wird nicht angezeigt.

**4d Umstieg**
- Zwei Gleise und der Weg dazwischen aus `steps` (Treppe/Aufzug, Ebenenwechsel als Text).
- Ohne Indoor-Daten bleibt es bei "Gleis 11 → Gleis 2, ca. 180 m"; keine erfundenen Details.
- Puffer unter 90 s: orange + `.warning`. Reicht es nicht: rot, die nächste Verbindung steht direkt in der Karte (kein Alert).

**4e Ersatzverkehr**
- SEV ist ein Bus-Abschnitt mit `replacement: true`. Bus-Badge in mode/bus, Eyebrow "Ersatzverkehr statt RE 5", wichtigster Satz: wo der Bus abfährt (nicht am Gleis).
- Meldungstext aus `remarks` (Hinweis Kritisch), gekennzeichnet als Meldung des Betreibers. Ohne Meldung nur die Fahrplandaten.
- Kurzfristiger SEV erscheint nur, wenn der Betreiber ihn in die Echtzeitdaten einspielt. Die App sagt das ehrlich, statt zu raten.

**4f Ankunft**
- Innerhalb 25 m ums Ziel: `.sensoryFeedback(.success)`, Live Activity endet mit Endstand (M4).
- Zusammenfassung in drei Zahlen, zurück zur Karte über "Fertig" (ersetzt "Beenden").
- Fahrt wird lokal als CompletedTrip gespeichert; nichts geht an den Server.

### D Erinnern (Meilenstein 4)

**D1 Erinnerung einrichten**
- Oben nur das Ergebnis ("Losgehen 12:52" in App/Anweisung, "Erinnerung um 12:47") und darunter die Rechnung.
- "Früher losgehen" ist das Hauptelement: Stepper in 5-Min.-Schritten plus Schnellwahl 0/5/10/15/20. Ändern rechnet sofort neu (numericText). Wert pro Ziel gemerkt.
- "Vorwarnen" getrennt davon: Mitteilung X Min. vor dem Losgehen. Zum Losgehen selbst kommt immer die zeitkritische Mitteilung.
- "Am Gleis sein vorher" ist der globale Umstiegspuffer aus den Einstellungen, hier nur angezeigt.
- Wer zu einer festen Zeit da sein muss, plant in 2c mit "Ankunft"; die Erinnerung rechnet von dort rückwärts.
- Mitteilungs-Erlaubnis wird erst hier beim ersten Scharfschalten abgefragt.

**D2 Erinnerungen**
- Über den Kartenknopf bell.badge. Badge nur, wenn heute eine Erinnerung aktiv ist.
- Zeiten mit "ca.", solange nicht neu berechnet; heute aktive mit Echtzeit-Delta.
- Löschen per swipeActions ohne Rückfrage, mit Rückgängig im Inline-Banner für 5 s.
- Leerzustand: ContentUnavailableView "Keine Erinnerungen", Symbol bell, "Tippe in einer Verbindung auf Erinnern."

**D3 Mitteilungen**
- T−5 normale Mitteilung. T−0 `interruptionLevel = .timeSensitive` mit Haptik.
- Texte nennen immer Ziel-Haltestelle, Linie, Zeit und Gleis; Änderungen ("statt 10") ausdrücklich. Keine Emojis, kein Ausrufezeichen-Alarm.
- Tipp öffnet die App direkt in Navigation (approachingFirstStop). Aktionen: "Starten" und "Später erinnern (5 Min.)".

### E Systemweit (Meilenstein 4)
- Live Activity ab T−15 bzw. mit aktiver Navigation; Update per refreshToken-Polling (60 s / 20 s vor Umstieg). Kopf: Anweisung + Echtzeit-Status; Mitte: Leg-Bar mit Live-Punkt; Fuß: Gleis/Steig + Refresh-Knopf (AppIntent), 44 pt.
- Dynamic Island Compact: Symbol + Linie in Linienfarbe, rechts kontextabhängig ("Los in 4m" / "240m" / "Ank. 14:22"). Minimal: Minuten + Status-Ring. Expanded: Anweisung, Leg-Bar, Ziel-Gleis, Refresh.
- Widgets: accessoryRectangular (nächste 2 Abfahrten + Gehzeit), accessoryCircular (Minuten bis Aufbruch), systemSmall (beste Verbindung zum Tagesziel), systemMedium (Abfahrtsmonitor). Daten aus der App Group, kein eigener Netzabruf mit Standort.

### F Auswertung (Meilenstein 5)
- Über den Kartenknopf chart.bar.xaxis; eigenes Sheet .large mit Schließen-Knopf.
- Bento-Grid 2 x 2 aus KPI-Kacheln; Zeitraum per Segmented Control (Woche/Monat/Jahr).
- Swift Charts: SectorMark (Verkehrsmittel-Mix, innerRadius ca. 0,62), BarMark (Ø Verspätung je Linie), AreaMark/LineMark (30 Tage). Farben = Modus-Tokens plus Beschriftung.
- Alle Daten lokal aus SwiftData.

### G Einstellungen und Quellen

**G1 Einstellungen**
- Einstieg über den Knopf rechts neben dem Suchfeld im Start-Sheet.
- Einstellungszeilen: Gehtempo (gelernter WalkingPaceFactor als Prozent, Detail mit "Zurücksetzen"), Umstiegspuffer, Verkehrsmittel (Produktfilter), Mitteilungen, Standort, Dein Server, Quellen und Lizenzen, Version.
- Standort und Mitteilungen öffnen die iOS-Einstellungen (`openSettingsURLString`).
- "Suchverlauf löschen" mit confirmationDialog; löscht nur den Verlauf, keine Favoriten.
- Inset-Grouped-Liste mit `.scrollContentBackground(.hidden)`.

**G2 Quellen und Lizenzen**
- Zweite Stufe der Quellenangabe. Erste Stufe bleibt die immer sichtbare Fußzeile unter Treffern und Verbindungen (Tipp darauf öffnet diesen Screen).
- Texte und Links aus `attribution` der API-Antwort, Links vor dem Anzeigen auf https prüfen.
- Links öffnen Safari (↗). Push im Einstellungs-Sheet (.large).

### H Zustände und Barrierefreiheit

**H1 Inline-Banner**
- Oben im Sheet (`safeAreaInset(edge: .top)`), Text aus `TransitError.errorDescription`. Nie Alerts. VoiceOver: `AccessibilityNotification.Announcement`.
- Bleibt, solange der Zustand gilt (Offline, Rate-Limit); verschwindet erst bei Erfolg. Motion.standard, bei Reduce Motion nur Überblenden.
- Rate-Limit: Restzeit aus Retry-After (`Text(timerInterval:)`), Suchen und Starten so lange deaktiviert, kein Auto-Retry.
- Zuordnung: offline/upstream* → Offline/Server; missingToken/unauthorized → Token (öffnet A2); locationDenied → Standort; refreshExpired/notFound → Abgelaufen; pinningFailed → Sicherheit (keine Details, keine Umgehung); removedLongDistance → Ausgeblendet; cancelled → nichts.
- Tint-Fläche + Symbol in status/warn, accent/blue oder status/alert; Bedeutung steht immer auch im Text.

**H2 Keine Verbindung**
- ContentUnavailableView im Routen-Sheet. Text nennt die Ursache konkret (Uhrzeit, Filter), wenn bekannt.
- Aktionen: "Spätere Verbindungen" (laterRef) und, falls Verkehrsmittel abgewählt sind, den fehlenden Filter direkt zulassen.
- Leere Suche: `ContentUnavailableView.search(text:)`.

**H3 Offline**
- Letzte Antwort bleibt sichtbar (abgeblendet), Echtzeit-Badges pausieren. Banner verschiebt den Inhalt, überdeckt ihn nicht.
- Starten bleibt möglich (Fußweg braucht kein Netz); Polling setzt aus und läuft bei Verbindung wieder an.
- Haltestellen-Vorschläge weiter aus dem SwiftData-Cache.

**H4 Dynamic Type AX3**
- Obergrenze `dynamicTypeSize(...accessibility3)` an der Wurzel. Sheet geht auf .large, Inhalt scrollt.
- Leg-Bar wechselt auf vertikal; Abkürzungen ausgeschrieben ("Fußweg" statt Symbol allein).
- Nichts wird abgeschnitten oder mit `lineLimit(1)` gekürzt.
- "Starten" bleibt in der Daumenzone: bei AX-Größen als Knopf unten (`safeAreaInset(edge: .bottom)`).
