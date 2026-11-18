# Architektur- und Design-Spezifikation: Reaktiver Nahverkehrs- & Regio-Routenplaner (iOS & Node.js)

## 1. Leitbild und Systemverantwortung (iOS Lead Architecture)
Die Anwendung ist ein hochreaktiver, multimodaler Routenplaner für iOS, spezialisiert auf den öffentlichen Personennahverkehr (Straßenbahn, Bus, U-Bahn, S-Bahn) sowie den Regionalverkehr (RB, RE, IRE). Sie kombiniert die offenen Fahrplan- und Echtzeitdaten von Transitous (MOTIS 2, u. a. DELFI) mit der präzisen Fußgänger-Engine von Apple Maps (`MKDirections`) in einer strikt nach den Apple Human Interface Guidelines (HIG) gestalteten Oberfläche.

### Kernprinzipien der iOS-App:
1. **Zero-Latency & Reaktivität:** Die App reagiert verzögerungsfrei (120Hz ProMotion-Ziel). Netzwerkanfragen blockieren niemals den Main-Thread. Lokales Caching (`SwiftData`), Request-Debouncing und Optimistic UI sorgen für sofortiges visuelles Feedback.
2. **Offenes, adaptives Layout nach Apple Design-Vorlagen:** Einsatz von Liquid Glass (iOS 26) in der Bedienebene, Apple-Karten (MapKit) als Basis, dynamischer Typografie (`Dynamic Type`) und einer persistenten Karten-Arbeitsfläche mit kontextabhängigen Overlays statt starrer Bildschirmwechsel.
3. **VPN-Resilienz:** Ausschließliche Nutzung von Hardware-GPS (`CoreLocation`) für Standort und Such-Bias. Sämtliche Fahrplan-Abfragen laufen über das eigene Backend mit deutscher Server-IP.
4. **In-App-Navigation mit persönlichen Gehzeiten:** Durchgängige Wegführung (Fußweg, Fahrzeug, Umstieg) innerhalb der App. Die Gehzeit-Berechnung von Apple Maps wird anhand der realen historischen Gehgeschwindigkeit des Nutzers kalibriert.
5. **Systemweite Präsenz:** Nahtlose Integration in den Sperrbildschirm, die Dynamic Island (`ActivityKit`), den Home-Bildschirm (`WidgetKit`) sowie zeitkritische Erinnerungen (`UserNotifications` & `EventKit`).
6. **Datengetriebene Statistik (`Swift Charts`):** Automatische Auswertung von Pendelzeiten, Verspätungsmustern, Verkehrsmittel-Mix und zurückgelegten Fußwegen.

---

## 2. Reaktive iOS-Architektur & Performance-Design

### 2.1 Tech-Stack & Concurrency
* **Sprache & Runtime:** Swift 6 mit aktiviertem Strict Concurrency Checking.
* **State Management:** `@Observable`-Makro (Observation Framework) für feingranulare, performante SwiftUI-View-Updates ohne unnötige Neuzeichnungen der Karte.
* **Asynchrone Datenströme:**
  * `AsyncStream` für kontinuierliche GPS-Updates (`CLLocationUpdate.liveUpdates(.otherNavigation)`).
  * Dedizierter `Actor` (`TransitPollingActor`) für die Hintergrund-Synchronisation des `refreshToken` (adaptive Polling-Rate: alle 60 Sekunden im Normalbetrieb, alle 20 Sekunden bei nahendem Umstieg).
* **Persistenz (`SwiftData`):**
  * Speicherung von Favoriten, letzten Suchen, gecachten Haltestellen-Koordinaten (für Offline-/Sofort-Vorschläge in 0 ms), geplanten Fahrten und abgeschlossenen Routen für die Statistik.

### 2.2 Reaktivitäts-Mechanismen
* **Prädiktives Pre-Fetching:** Sobald der Nutzer die App öffnet, wird im Hintergrund bereits der aktuelle GPS-Standort bestimmt und die nächstgelegenen Haltestellen im Umkreis von 500 Metern vorgeladen.
* **Parallele Pipeline (TaskGroup):** Bei der Routensuche werden die DB-Verbindungsabfrage (Backend) und die Apple-Maps-Fußwegberechnung (`MKDirections`) über eine `withThrowingTaskGroup` parallelisiert. Die UI rendert sofort das Grundgerüst der Route (Skeleton/Polylines) und blendet die exakten Gehzeiten progressiv ein.

---

## 3. Offenes Layout-System & Animations-Choreografie

### 3.1 Räumliches Layout-Konzept (Spatial Hierarchy)
Das Layout ist offen und zustandsgetrieben formuliert, sodass Views fließend ineinander übergehen, anstatt über klassische Navigation-Stacks geschoben zu werden:

* **Ebene 0 (Basis-Canvas):** Vollflächige `Map`-View. Das `safeAreaPadding` der Karte ist reaktiv an die aktuelle Höhe des Bottom Sheets gekoppelt. Bewegt sich das Sheet nach oben, verschiebt sich das optische Zentrum der Karte synchron in die obere Bildschirmhälfte.
* **Ebene 1 (Schwebende Kopf-Steuerung / Top Chrome):**
  * Links oben: Kompakter Status-Indikator (GPS-Genauigkeit / Aktiver Nahverkehrs-Filter).
  * Rechts oben: Schnellzugriff-Button (`chart.bar.xaxis`) für das Statistik- & Pendel-Dashboard sowie für vorgemerkte Erinnerungen (`bell.badge`).
  * Im aktiven Navigationsmodus transformiert sich diese Ebene in das **Floating Guidance Banner**.
* **Ebene 2 (Adaptives Bottom Sheet):**
  * Steuert Suche, Routenauswahl (Hero Card + Alternativen) und Fahrt-Details über drei dynamische Rastpunkte (`height(140)`, `fraction(0.50)`, `large`).

### 3.2Animations-System (Fluid Interfaces)
Alle Zustandsübergänge folgen physikalischen Feder-Kurven aus den zentralen `Motion`-Konstanten (siehe AGENT.md 4.3; Standard `.spring(response: 0.4, dampingFraction: 1.0)`):

1. **Card-to-Navigation Morphing (`matchedGeometryEffect`):**
   Tippt der Nutzer auf der „Hero Card“ auf „Start“, kollabiert die Karte nicht einfach: Die multimodale Fortschrittsleiste (Leg-Bar) löst sich aus der Card und gleitet per `matchedGeometryEffect` direkt in das untere Kompaktsheet oder das obere Guidance Banner.
2. **Live-Pulsieren & Fortschritt (`PhaseAnimator` & `KeyframeAnimator`):**
   * Echtzeit-Abweichungen (z. B. `+3 Min.` oder Gleiswechsel) pulsieren dezent über einen `PhaseAnimator`, um Aufmerksamkeit ohne aufdringliche Pop-ups zu erzeugen.
   * Während der Fahrt interpoliert ein `TimelineView` die aktuelle Position des Zuges oder der Straßenbahn fließend entlang der Polyline der Verbindung.
3. **Kamerafahrten (`MapCameraKeyframeAnimator`):**
   Beim Wechsel vom Fußweg (3D-Perspektive, Pitch 45 Grad, Heading-orientiert) in das Verkehrsmittel (2D-Draufsicht, zentriert auf den Streckenabschnitt) fährt die Kamera in einer sanften S-Kurve heraus.
4. **Haptisches Feedback (`.sensoryFeedback`):**
   * `.selection` beim Einrasten von Sheet-Detents und Durchscrollen von Haltestellen.
   * `.warning` bei erkanntem Gleiswechsel oder wenn der Puffer beim Fußweg unter 90 Sekunden fällt.
   * `.success` beim Erreichen der Einstiegs- oder Umsteigehaltestelle.

---

## 4. Kern-Module: Navigation, Gehzeit-Kalibrierung & Erinnerungen

### 4.1 Selbstlernender Fußweg-Realitätscheck
Die Fahrplandaten liefern für Fußwege und Umstiege nur grobe Schätzwerte. Die App ersetzt diese durch ein zweistufiges Verfahren:
1. **Geometrische Berechnung via Apple Maps:** Für jeden Fußweg-Abschnitt (Start zur ersten Haltestelle, Umstieg zwischen Steigen/Gleisen, letzte Haltestelle zum Ziel) berechnet `MKDirections` (`.walking`) die reale Route und Standard-Gehzeit.
2. **Persönlicher Geschwindigkeits-Faktor (`WalkingPaceFactor`):**
   Die App misst während aktiver Fußweg-Navigation (oder optional via `HealthKit`-Gehgeschwindigkeit) das reale Tempo des Nutzers im Vergleich zur `MKDirections`-Prognose.
   * Formel: `Reale_Gehzeit = MKDirections_Zeit * Persönlicher_Faktor` (Standard: `1.0`, bei schnellen Gehern z. B. `0.85`).
   * Dadurch zeigt die Hero Card exakt die Gehzeit an, die der Nutzer tatsächlich benötigt.

### 4.2 Zustandsmaschine der In-App-Navigation (`NavigationStateMachine`)
Die aktive Navigation durchläuft automatisch folgende Zustände auf Basis von GPS-Geofences (`CLCircularRegion` um Haltestellen) und Zeitstempeln:
* `approachingFirstStop`: Aktives Fußgänger-Routing mit Kompass-Ausrichtung, Live-Distanz zum Steig und Countdown bis zur Abfahrt der Bahn.
* `waitingAtPlatform`: Nutzer befindet sich im 40-Meter-Radius der Haltestelle. Anzeige von Steig/Gleis und Live-Verspätung (Wagenreihung und Auslastung liefert Transitous nicht).
* `onBoardTransit`: Bewegung entlang der Schienen-/Bus-Polyline erkannt. Anzeige der verbleibenden Haltestellen und Überwachung des nächsten Umstiegs im Hintergrund.
* `transferRouting`: 120 Sekunden vor Ankunft am Umsteigebahnhof schaltet die Ansicht in den Detail-Zoom des Bahnhofs um und zeigt den exakten Fußweg vom Ankunftssteig zum Abfahrtsgleis der Anschlusslinie.
* `finalWalkToDestination`: Nach dem letzten Ausstieg automatisches Umschalten auf `MKDirections`-Fußgängernavigation bis zur Zieladresse.

### 4.3 Erinnerungs-Engine & Time-to-Leave Pipeline
Jede geplante oder später aus dem Kalender übernommene Route kann als aktive Erinnerung („Wann muss ich los?“) scharfgeschaltet werden:
* **Rückwärtsberechnung:** `Aufbruchszeit = Abfahrt_Bahn_1 (inkl. Echtzeit-Delay) - Kalibrierte_Gehzeit - Stationspuffer`.
* **Dynamische Verschiebung:** Prüft das Backend 30 Minuten vor Aufbruch das `refreshToken` und stellt fest, dass die Straßenbahn 5 Minuten Verspätung hat, verschiebt die App den Aufbruchs-Wecker automatisch um 5 Minuten nach hinten (oder bei Ausfall auf eine Verbindung früher).
* **Eskalationsstufen (`UserNotifications` & `EventKit`):**
  1. **T minus 15 Min.:** Start der Live Activity auf dem Sperrbildschirm; stille Vorschau der Route.
  2. **T minus 5 Min.:** Reguläre Benachrichtigung („In 5 Minuten aufbrechen zu Haltestelle X“).
  3. **T minus 0 Min. (Time-to-Leave):** Zeitkritische Mitteilung (`interruptionLevel = .timeSensitive`) mit markanter Haptik. Ein Tipp öffnet die App direkt im Zustand `approachingFirstStop`.
  4. **Optionaler Apple-Erinnerungen-Sync:** Auf Wunsch legt die App über `EventKit` automatisch eine fällige Aufgabe in der nativen Apple-Erinnerungen-App (`EKReminder`) mit Deep-Link (`mytransitapp://navigate?routeId=...`) an.

### 4.4 Proaktive Umplanung unterwegs (`ConnectionWatch`)
Reicht unterwegs ein Anschluss nach Echtzeitlage nicht mehr, schlägt die App von sich aus eine Alternative vor. Der Nutzer übernimmt oder lehnt ab; ohne Entscheidung läuft die Fahrt unverändert weiter. Es gibt keine automatische Umplanung.

**Grundsätze**
1. **Suche ab dem Ort, an dem der Nutzer sein wird.** Er sitzt noch im Fahrzeug und ist nicht am Umstieg. Gesucht wird ab dem Ausstiegshalt des Abschnitts vor dem betroffenen Anschluss (Stop-ID), nicht ab dem Standort. Zeit = prognostizierte Ankunft dort (Echtzeit). Der Anschluss muss mindestens `TransferCheck.minimumSlackSeconds` nach der Ankunft abfahren.
2. **Lokal.** Auswertung auf dem Gerät aus Refresh-Stand, Position und Gehtempo. Kein Push-Server, keine neue Backend-Route, keine Änderung an `docs/API.md`. Das Backend sieht nur, was jede Suche schickt: Stop-ID, Zeit, Modi, Barrierefreiheit, Zwischenstopps.
3. **Nur bei Folgen.** Verspätung oder außerplanmäßiger Halt ohne gefährdeten Anschluss (z. B. Direktfahrt Düsseldorf nach Köln-Deutz) erzeugt keinen Vorschlag, nur die aktualisierte Ankunft in App und Live Activity.
4. **Die Route endet am Ziel.** Sie bleibt aktiv bis `arrived` (Zielradius 25 m) oder bis der Nutzer beendet. Danach keine Vorschläge, aller Zustand gelöscht.

**Auslöser** (genau eine Auswertung am Ende jedes Navigations-Ticks, also nach Refresh und Position; solange der Nutzer noch im Fahrzeug sitzt und ein späteres Fahrzeug folgt: Zustand `onBoardTransit` oder `transferRouting` vor der Ankunft)
- `connectionBroken(vehicle)`: `NavigationEngine.brokenConnection` liefert das Fahrzeug (Puffer <= 0).
- `tripCancelled(vehicle)`: ein folgendes Fahrzeug fällt aus (`cancelled`). Fällt das Fahrzeug aus, auf das man am Gleis wartet, gilt der bestehende Hinweis "fällt aus" mit "Nächste Verbindung", kein Vorschlag.
- Ein knapper Anschluss (`tight`) löst keinen Vorschlag aus, es bleibt beim bestehenden Hinweis (Anzeige, Haptik).
- Die verpasste Abfahrt am Steig (`missedDeparture`) bleibt der bestehende Ablauf "Nächste Verbindung" ab Standort. Kein zweiter Vorschlag dafür.

**Vorschlag (`ReplanProposal`)**
- Enthält Auslöser, betroffenes Fahrzeug, Suchstart (Stop-ID + Zeit) und die gefundenen Alternativen. Anfrage: Ziel wie die laufende Fahrt, `modes`, `accessibility` und die noch offenen `via` wie bei `openAlternatives`.
- Vorgeschlagen wird unter den erreichbaren Alternativen die beste nach der bestehenden Rangfolge (`CalibratedJourney.rank`), nicht die erste der Liste. Erreichbar: enthält kein betroffenes Fahrzeug, hat keinen verpassten Umstieg und die erste Abfahrt liegt frühestens bei Suchzeit + Gehweg + `minimumSlackSeconds`. **Ausnahme Weiterfahrt im selben Zug:** Beginnt die Alternative mit dem Fahrzeug, in dem der Nutzer sitzt, ohne Gehweg, genügt eine Abfahrt nach der Ankunft; weder Gehweg noch 120 s Puffer. Gibt es keine, kommt kein Vorschlag (kein schlechter Vorschlag); der Hinweis "Anschluss reicht nicht" bleibt.
- Weitere Alternativen erreicht der Nutzer über das bestehende Alternativen-Blatt, vorbelegt mit dem Suchstart.

**Antwort des Nutzers**
- **Übernehmen:** merkt den Wechsel vor. Die laufende Navigation (eigener Zug, Ausstiegshinweis, Refresh) bleibt unverändert, bis der Nutzer am Suchstart ankommt; dort startet die Alternative, vorher mit frischem Refresh neu geprüft (bis dahin hat sie keine Echtzeit). Die Karte zeigt "Wechsel auf <Linie> vorgemerkt" statt "reicht nicht". Die Regel gilt einmal, auch für das bestehende "Wechseln" aus dem Alternativen-Blatt, wenn der Start eine spätere Station ist. Die `via` werden ab dem Fahrzeug vor dem betroffenen berechnet, damit schon passierte Stopps nicht zurückkommen.
- **Behalten** (oder Wischen): Fahrt unverändert. Gemerkt wird das Fahrzeug, nicht die Art des Auslösers (Anschluss gefährdet oder Ausfall); es kommt nicht wieder. Ein neuer Vorschlag kommt nur, wenn sich der Puffer um mindestens 5 Minuten gegenüber dem Ablehnen verschlechtert oder ein anderes Fahrzeug betroffen ist. Sind mehrere Fahrzeuge betroffen, werden sie nacheinander behandelt, das früheste zuerst; abgelehnte werden übersprungen.
- **Keine Antwort:** der Vorschlag bleibt, bis die Suchstart-Zeit erreicht ist. Er verfällt mit kurzem Hinweis erst, wenn der Anschluss wieder reicht und der Puffer mindestens `TransferCheck.minimumSlackSeconds` beträgt (Hysterese gegen Flattern). Die gefundene Antwort bleibt im RAM; löst der Auslöser erneut aus, wird sie ohne neue Suche gezeigt, solange ihre erste Abfahrt erreichbar ist.

**Kommunikation** (beide Wege lokal)
- Vordergrund: Banner "Anschluss <Linie> reicht nicht mehr" mit Aktion "Alternativen ansehen"; Haptik `.warning` einmal je Anschluss (bestehend).
- Hintergrund: lokale Mitteilung in eigener Kategorie (nicht die der Erinnerungen, keine Aktionen "Starten" oder "Später erinnern") plus das bestehende Live-Activity-Problem "Anschluss", das auch bei Ausfall eines späteren Fahrzeugs gesetzt wird. Kein eigener Live-Activity-Zustand. Text ohne Emojis, nur Linie, Halt, Abfahrt und Gleis eines Halts aus den Fahrplandaten. Tippen öffnet das Blatt, gewechselt wird nie ohne Bestätigung. Voraussetzung ist die Hintergrund-Standort-Session (Standorterlaubnis, nicht aus dem Wartezustand gestartet); ohne sie erscheint der Vorschlag beim nächsten Öffnen. Eine Mitteilung wird entfernt bei Verfall, Übernehmen, Ablehnen, Ankunft und Beenden.

**Limits:** Schlüssel = Fahrt und Fahrzeug (Ausfall geht vor Anschluss), vor dem Task-Start synchron markiert. Eine neue Suche für denselben Schlüssel nur, wenn der Puffer um mindestens 300 s schlechter ist, höchstens 3 je Fahrt. Ergebnis gilt nur, wenn Fahrt, Schlüssel, Phase `.navigation`, aktiver Auslöser und Zeit vor dem Suchstart noch stimmen. Wiederholung bei Fehler nach max(60 s, `blockedUntil`), höchstens 3 gescheiterte Suchen je Fahrt, nach Abbruch keine. Ein Vorschlag (`ReplanProposal`, mit zufälliger ID) gilt nur, solange sein Fahrzeug betroffen ist und der Suchstart nicht erreicht ist; die Suchzeit folgt der aktuellen Echtzeit-Ankunft.

**Nicht Teil dieser Funktion:** Das Fahrzeug, in dem der Nutzer gerade sitzt, kann nicht ausfallen; es fährt allenfalls nicht mehr weiter (vorzeitiges Ende). Das löst hier keinen Vorschlag aus und wird getrennt behandelt.

**Datenschutz und Sicherheit**
- Vorschlag und gemerkte Schlüssel nur im RAM, bei `endNavigation` gelöscht; nicht in SwiftData, nicht in Logs.
- Mitteilungstexte nur aus Fahrplandaten (Linie, Halt, Zeit, Gleis), nie Adresse oder Position. Sie stehen auf dem Sperrbildschirm.
- Ein Tipp auf die Mitteilung wirkt nur, wenn die zufällige Vorschlags-ID im `userInfo` dem aktuellen Vorschlag entspricht, die Phase `.navigation` ist und die Suchstart-Zeit nicht vorbei ist; nie auf eine fremde oder beendete Fahrt.

**Abnahme (jeweils ein Test, der rot wird, wenn die Regel fehlt)**
Kein Vorschlag bei Verspätung ohne Anschluss; Vorschlag bei `connectionBroken` und `tripCancelled`; Suchstart = Ausstiegshalt und Echtzeit-Ankunft, nicht Standort; `via`, Modi und Barrierefreiheit bleiben erhalten; Alternative mit dem betroffenen Anschluss wird nie vorgeschlagen; Ablehnen unterdrückt denselben Auslöser, nicht eine Verschlechterung um 5 Minuten; Verfall, wenn der Anschluss wieder reicht; nach `arrived` und `endNavigation` kein Zustand mehr; höchstens eine Suche je Schlüssel; Rate-Limit-Sperre unterdrückt die Suche; nach "Übernehmen" im Zug weder `approachingFirstStop` noch Problem "Anschluss"; `via` ab dem Fahrzeug vor dem betroffenen (Test mit Stopp am ersten Umstieg); erste Abfahrt der Alternative frühestens Suchzeit + Gehweg + `minimumSlackSeconds`; Flattern des Puffers erzeugt keinen zweiten Vorschlag und kein Verfall ohne Hysterese; Doppelaufruf während einer Suche startet keine zweite; Antwort nach Ankunft oder Verfall wird verworfen; Ausfall des Fahrzeugs am Gleis erzeugt keinen Vorschlag; Weiterfahrt im selben Zug ohne Gehweg und Puffer wird vorgeschlagen; Rang statt Listenreihenfolge; mehrere Fahrzeuge nacheinander; höchstens 3 gescheiterte Suchen.

---

## 5. Widget, Lock Screen & Dynamic Island (`WidgetKit` & `ActivityKit`)

### 5.1 Live Activities & Dynamic Island (Während Vorlauf & Fahrt)
Sobald eine Fahrt in weniger als 15 Minuten startet oder die Navigation aktiv ist, läuft eine `Activity<TransitActivityAttributes>`:

* **Dynamic Island – Compact View:**
  * *Leading:* Verkehrsmittel-Icon (SF Symbol) + Liniennummer in Linienfarbe (z. B. `STR 4` oder `RE 5`).
  * *Trailing:* Kontextabhängiger Primärwert: Vor Fahrtbeginn der Geh-Countdown (`Los in 4m`), während des Fußwegs die Restdistanz (`240m`), im Fahrzeug die Ankunftszeit am Umstieg (`Ank. 14:22`).
* **Dynamic Island – Minimal View:**
  * Kompaktes Badge mit verbleibenden Minuten bis zur nächsten Aktion (Aufbruch oder Umstieg) mit farbigem Status-Ring (Grün = Pünktlich, Gelb = Verspätet, Rot = Anschluss gefährdet).
* **Dynamic Island – Expanded View & Lock Screen Banner:**
  * *Kopfzeile:* Aktuelle Anweisung (z. B. „Fußweg zu Hauptbahnhof Steig B“ oder „Fahrt in RE 5 Richtung Koblenz“) + Echtzeit-Status.
  * *Mittelteil:* Die visuelle multimodale Fortschrittsleiste (Leg-Bar) mit einem Live-Indikator-Punkt, der zeigt, in welchem Abschnitt der Reise man sich befindet.
  * *Fußzeile:* Links das Zielgleis/der Zielsteig des nächsten Schrittes; rechts ein interaktiver Button (`Button(intent: RefreshRouteIntent())`) mit `arrow.clockwise`-Symbol zum manuellen Sofort-Abgleich ohne Öffnen der App.

### 5.2 Home Screen & Lock Screen Widgets (`WidgetKit`)
Für den schnellen Blick ohne aktive Navigation:
* **Lock Screen (`accessoryRectangular`):** Zeigt die nächsten 2 Abfahrten der nächstgelegenen oder favorisierten Haltestelle inkl. benötigter Gehzeit von der aktuellen Position.
* **Lock Screen (`accessoryCircular`):** Countdown in Minuten, wann man für die nächste Pendelfahrt losgehen muss.
* **Home Screen (`systemSmall` & `systemMedium`):** „Smart Commute Card“ – zeigt je nach Tageszeit automatisch die beste Verbindung zum Arbeitsplatz/Heimatort oder den Live-Abfahrtsmonitor der aktuellen Haltestelle inkl. Ein-Klick-Start der Navigation.

---

## 6. Statistik- & Pendel-Überblick (`Swift Charts`)

Das Statistik-Modul ist über die obere Aktionsleiste als eigenes, luftiges Sheet erreichbar. Alle absolvierten Fahrten werden automatisch lokal in `SwiftData` protokolliert und mit dem `Charts`-Framework von Apple visualisiert.

### Layout des Statistik-Dashboards (Modulares Bento-Grid):
1. **KPI-Kopfkacheln (2x2 Grid):**
   * **Pünktlichkeits-Score:** Prozentsatz aller Fahrten, die mit weniger als 3 Minuten Verspätung am Ziel ankamen.
   * **Gesammelte Verspätung:** Summe der durch die DB / den ÖPNV verursachten Mehrminuten im gewählten Zeitraum (Woche / Monat / Jahr).
   * **Aktive Gehzeit & Distanz:** Gesamte zu Fuß zurückgelegte Kilometer und Minuten auf dem Weg zu Haltestellen und bei Umstiegen.
   * **Persönlicher Geh-Faktor:** Anzeige des gelernten Tempos (z. B. „12 % schneller als Apple-Maps-Standard“).
2. **Chart 1: Verkehrsmittel-Mix (`SectorMark` / Donut-Chart):**
   * Aufschlüsselung der Reisezeit und Distanz nach Modus: Straßenbahn, S-Bahn, Regionalzug, U-Bahn, Bus und Fußweg.
3. **Chart 2: Zuverlässigkeit nach Linien (`BarMark`):**
   * Horizontales Balkendiagramm deiner meistgenutzten Linien (z. B. `RE 5`, `STR 4`, `S 1`), das die durchschnittliche Verspätung pro Linie aufdeckt. So erkennst du sofort, welche Linie chronisch unpünktlich ist.
4. **Chart 3: Pendel-Verlauf & Fußweg-Trend (`AreaMark` & `LineMark`):**
   * Zeitlicher Verlauf der täglichen Reise- und Gehzeiten über die letzten 30 Tage.

---

## 7. Backend-Schnittstelle (Node.js + MOTIS 2 / Transitous)

Das Backend kapselt alle Fahrplan-Abfragen auf einem gemieteten Server in Deutschland (VPN-Schutz) und liefert schlankes JSON an die Swift-App. Der verbindliche Vertrag steht in `docs/API.md`; die Datenquelle wurde am 24.10.2026 von der DB-Navigator-API auf Transitous umgestellt (Begründung in `docs/STATUS.md`).

* **`GET /api/locations`** (`query` oder `lat`/`lon`)
  * Haltestellensuche und Umkreissuche (500 m) über MOTIS. Stop-IDs sind opake MOTIS-IDs. Adressen löst die App lokal per `MKLocalSearch` auf.
* **`POST /api/routes`**
  * Parameter: `origin`, `destination` (Stop-ID oder Koordinate), `targetTime`, `isArrivalTime`, `onlyNahverkehr` (Standard: `true`, schließt Fernverkehr aus), `results`, Paging.
  * Liefert Polylines für alle Verbindungen, Linienfarben, Fußwege mit Geometrie, Echtzeit-Flag pro Abschnitt und Quellenangabe (`attribution`).
  * Keine Auslastung und keine Wagenreihung (Transitous liefert das nicht).
* **`POST /api/refresh`**
  * Parameter: `refreshToken`, optional `polylines`.
  * Gibt die aktualisierte Verbindung mit Zeiten, Verspätungen, Gleisänderungen, Ausfällen und Störungsmeldungen zurück (Live Activity, Erinnerungs-Service). Nicht mehr rekonstruierbare Fahrten: `410 REFRESH_EXPIRED`.

---

## 8. Master-Prompt für die KI-gestützte Implementierung

Kopiere den folgenden Prompt in deine Entwicklungsumgebung (z. B. Xcode AI, Cursor oder Claude Code), um das System strukturiert zu generieren:

```text
Du bist Lead iOS Architect (Swift 6, SwiftUI, MapKit, CoreLocation, WidgetKit, ActivityKit, SwiftData, Swift Charts) und Senior Node.js Backend-Entwickler. Implementiere die in dieser Datei spezifizierte Anwendung („Reaktiver Nahverkehrs- & Regio-Routenplaner“) modular, hochperformant und strikt nach den Apple Human Interface Guidelines (HIG).

Zwingende Architektur- und Design-Regeln:
1. Keine Emojis: Verwende im gesamten Quellcode, in der Benutzeroberfläche, in Benachrichtigungen und Kommentaren keinerlei Emojis. Nutze ausschließlich native Apple SF Symbols (z. B. "figure.walk", "tram.fill", "train.side.front.car", "bell.badge.fill", "chart.bar.xaxis").
2. Reaktivität & Swift 6: Nutze das @Observable-Makro für den gesamten UI-State, Swift 6 Strict Concurrency (async/await, Actor für Netzwerk/Polling, TaskGroup für parallele DB- und MKDirections-Abfragen) und SwiftData für lokales Caching sowie Statistik-Persistenz.
3. VPN-Sicherheit: Verwende auf iOS-Seite niemals IP-basierte Standortdienste. Binde MKLocalSearch und MKLocalSearchCompleter immer an eine explizite MKCoordinateRegion auf Basis der aktuellen Hardware-GPS-Koordinaten von CoreLocation.
4. Hybride Gehzeit & Kalibrierung: Überschreibe die pauschalen Fußweg-Schätzungen aus den Fahrplandaten immer durch echte MKDirections (.walking) Berechnungen (Start -> Erste Haltestelle, Umstiege, Letzte Haltestelle -> Ziel) und multipliziere diese mit einem konfigurierbaren/lernenden persönlichen Gehgeschwindigkeits-Faktor (WalkingPaceFactor).
5. Offenes Layout & Animationen: Baue eine persistente MapKit-Basisansicht mit reaktivem safeAreaPadding und einem dreistufigen Bottom Sheet. Implementiere flüssige Übergänge mit matchedGeometryEffect (Hero Card -> Aktive Navigation), PhaseAnimator (Live-Delay-Badges) und sensoryFeedback für Haptik.
6. System-Integration: Implementiere ActivityKit (Live Activity für Lock Screen und Dynamic Island inkl. interaktivem Refresh-AppIntent), WidgetKit (Lock Screen und Home Screen Widgets), zeitkritische Erinnerungen (UserNotifications .timeSensitive / EventKit) sowie das Statistik-Dashboard mit Swift Charts.
7. Zukunftssicherheit (Kalender-Hook): Halte das TripRequest-Modell protokollarisch offen, sodass später automatische Kalender-Trigger ohne Umbau der Routing- und Erinnerungs-Engine eingehängt werden können.

Vorgehensweise in 5 Meilensteinen (warte nach jedem Meilenstein auf meine Freigabe):
- Meilenstein 1: Node.js Backend mit Express und MOTIS 2 / Transitous (Nahverkehrs-Filter, Polylines, /api/locations, /api/routes, /api/refresh).
- Meilenstein 2: Swift Core-Engine & SwiftData (Modelle, VPN-sicherer Location- & SearchService, paralleler HybridRouteCalculator mit MKDirections + WalkingPaceFactor, Backward-Scheduling für Time-to-Leave).
- Meilenstein 3: Reaktives SwiftUI-Interface & Animationen (Persistente Map mit dynamischer Kamera, adaptives Bottom Sheet, Hero Card mit multimodaler Leg-Bar, In-App-Navigations-State-Machine mit Floating Guidance Banner).
- Meilenstein 4: Erinnerungen, WidgetKit & ActivityKit (Time-to-Leave Notification-Service, Dynamic Island Compact/Minimal/Expanded Views, Lock Screen Live Activity & Widgets mit AppIntents).
- Meilenstein 5: Statistik-Dashboard mit Swift Charts (SwiftData-Logging abgeschlossener Fahrten, Bento-Grid KPIs, Donut-Chart für Verkehrsmittel-Mix, Balkendiagramm für Linien-Verspätungen).

Starte jetzt mit der vollständigen Ausarbeitung von Meilenstein 1 und dem Projekt-Setup.
