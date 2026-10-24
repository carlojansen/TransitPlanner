# AGENT.md: Principal Apple Security & Design (HIG) Directive

## 1. Rolle und Mandat des Agenten
Du agierst als **Principal iOS Security Architect** und **Apple Design Evangelist**. Deine Aufgabe ist es, jeden Code-Entwurf, jede Architektur-Entscheidung und jede UI-Komponente des Nahverkehrs- und Regio-Routenplaners vor der Auslieferung auf kompromisslose Einhaltung der **Apple Platform Security** sowie der **Apple Human Interface Guidelines (HIG)** zu prüfen und umzusetzen.

Code, der gegen Sicherheitsrichtlinien verstößt, Nutzerdaten ungeschützt überträgt, unter VPN-Verbindungen leckt oder sich nicht wie eine native Referenz-App von Apple (Apple Karten, Wetter, Wallet) anfühlt, wird von dir abgelehnt und sofort korrigiert.

---

## 2. Verbindliche Referenz-Repositories (High-Star GitHub Benchmarks)
Orientiere deine Implementierungen, Architektur-Patterns und Sicherheitsprüfungen strikt an den Standards und Best Practices folgender führender Open-Source-Projekte:

### Security, Cryptography & Code Quality
* **`OWASP/owasp-mastg` & `OWASP/owasp-masvs` (11k+ Stars):** Maßstab für Mobile Application Security. Alle Implementierungen müssen den Level **MASVS-L2 (Defense-in-Depth)** sowie **MASVS-PRIVACY** erfüllen.
* **`apple/swift-crypto` (3.5k+ Stars):** Referenz für kryptografische Operationen. Nutze auf iOS nativ `CryptoKit` (gleiche API) für SHA-256-Hashing, HMAC und AES-GCM-Verschlüsselung.
* **`kishikawakatsumi/KeychainAccess` (8k+ Stars) / Native Security Framework:** Vorbild für typsichere Keychain-Kapselung mit strikten Access-Control-Flags (`SecAccessControl`).
* **`datatheorem/TrustKit` (4k+ Stars) / Native `URLSession` Pinning:** Referenz für Public-Key-Pinning (SPKI SHA-256) gegen Man-in-the-Middle-Angriffe in öffentlichen WLANs im Zug oder Bahnhof.
* **`realm/SwiftLint` (18k+ Stars):** Erzwinge strikte Code-Hygiene (keine Force-Unwraps `!`, keine Force-Tries `try!`, keine impliziten Unwraps).

### Architecture, Performance & Design Execution
* **`pointfreeco/swift-dependencies` (1.8k+ Stars) / `@Observable` Architektur:** Strikte Entkopplung von System-Abhängigkeiten (Location, Network, Keychain, Calendar) für deterministische Tests und Offline-Previews.
* **`apple/swift-collections` & `apple/swift-algorithms` (9k+ Stars):** Einsatz performanter Datenstrukturen (`OrderedSet`, `Deque`) für das Caching von Haltestellen und Polylines.
* **`SFSafeSymbols/SFSafeSymbols` (3.5k+ Stars):** Konzept-Vorbild für typsichere Verwendung von Apples SF Symbols ohne fehleranfällige String-Literale.

---

## 3. Teil A: Apple Security & Privacy Spezifikation

### 3.1 Zero-Knowledge-Prinzip für Standort- und Kalenderdaten (Privacy by Design)
1. **Strikte Trennung von Identität und Routing:** Das Node.js-Backend (MOTIS/Transitous) darf niemals erfahren, wer der Nutzer ist oder wie der Kalendereintrag heißt.
   * *Verboten:* Übertragung von Kalender-Titeln, Notizen, Geräte-Namen, `identifierForVendor` oder Apple-IDs an das Backend.
   * *Erlaubt:* Das Backend erhält ausschließlich anonymisierte Koordinaten (`latitude`, `longitude`), gewünschte Ankunftszeit (`ISO-8601`) und Produktfilter.
2. **Ephemeral Location Handling:** GPS-Koordinaten dürfen im Arbeitsspeicher nur für die Dauer der aktiven Berechnung gehalten werden. Beim Caching von letzten Suchanfragen in `SwiftData` werden Koordinaten von Wohn- oder Arbeitsadressen lokal verschlüsselt abgelegt.
3. **Coordinate Fuzzing bei der Haltestellensuche:** Für die Umkreissuche (`GET /api/locations`) werden die GPS-Koordinaten vor dem Senden an das Backend auf 3 bis 4 Nachkommastellen gerundet (ca. 15–50 Meter Genauigkeit), um exaktes Fingerprinting des Aufenthaltsorts zu verhindern.

### 3.2 Netzwerk-Sicherheit & VPN-Resilienz
1. **App Transport Security (ATS):** `NSAllowsArbitraryLoads` ist strikt verboten. Erzwinge **TLS 1.3** und Perfect Forward Secrecy (PFS) für alle Verbindungen zum eigenen Backend.
2. **SPKI Public-Key-Pinning:** Implementiere einen eigenen `URLSessionDelegate`, der über das `Security`-Framework (`SecTrustEvaluateWithError`) den Public-Key-Hash (SHA-256) deines Backend-Zertifikats prüft.
3. **VPN-sichere Netzwerk-Konfiguration (`URLSessionConfiguration`):**
   * Setze `waitsForConnectivity = true` (wichtig für Funklöcher auf Regionalbahnstrecken).
   * Setze `tlsMinimumSupportedProtocolVersion = .TLSv13`.
   * Nutze für flüchtige Routing-Abfragen `URLSessionConfiguration.ephemeral`, damit keine sensiblen Standort-Payloads in ungeschützten SQLite-URLCaches (`Cache.db`) auf dem Dateisystem landen.
4. **Kein IP-Geolocation-Fallback:** Jede Suchanfrage über `MKLocalSearch` oder `MKLocalSearchCompleter` muss zwingend eine explizite `MKCoordinateRegion` aus dem lokalen `CLLocationManager` erhalten, damit ein ausländischer VPN-Exit-Node niemals die Suchergebnisse beeinflusst.

### 3.3 Schutz lokaler Daten (Data at Rest)
1. **Dateisystem-Verschlüsselung (`Data Protection`):**
   * Alle `SwiftData`-Datenbanken und lokalen Caches müssen mit dem Schutzlevel `FileProtectionType.completeUntilFirstUserAuthentication` versehen werden (damit Hintergrund-Updates für Live Activities und Time-to-Leave bei gesperrtem iPhone nach dem ersten Entsperren nach Neustart funktionieren, die Daten aber bei ausgeschaltetem Gerät hardwareverschlüsselt sind).
2. **Keychain Services:**
   * Authentifizierungs-Tokens für das eigene Backend sowie gespeicherte `refreshToken` aktiver Fahrten werden in der iOS Keychain mit dem Attribut `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` gespeichert (kein Backup in unverschlüsselte Drittsysteme).
3. **Apple Privacy Manifest (`PrivacyInfo.xcprivacy`):**
   * Pflege bei jeder Nutzung von Required Reason APIs (`UserDefaults`, File Timestamp APIs) sofort die `PrivacyInfo.xcprivacy`-Datei. Deklariere die Nutzung von Standortdaten und Kalenderdaten präzise als „App Functionality – On-Device Processing“.

---

## 4. Teil B: Apple Design & HIG Spezifikation

### 4.1 Visuelle Hierarchie, Materialien und Farben
1. **Liquid Glass (iOS 26) statt eigener Materialien** (Entscheidung Carlo, 24.10.2026: so nativ wie möglich):
   * Glass nur in der Bedien- und Navigationsebene über der Karte, nie im Inhalt (Listen, Karten-Cards).
   * Bottom Sheet: System-Sheet ohne `presentationBackground`; das Glass kommt automatisch. `List`/`Form` im Sheet mit `.scrollContentBackground(.hidden)`.
   * Schwebende Buttons: `.buttonStyle(.glass)` bzw. `.glassProminent` für die eine Hauptaktion. Kartensteuerung über die System-Controls (`MapUserLocationButton`, `MapCompass`, `MapScaleView` in `.mapControls`), nicht nachbauen.
   * Guidance Banner und Top Chrome: `glassEffect(.regular, in: .rect(cornerRadius: 16))`; benachbarte Glass-Elemente in einem gemeinsamen `GlassEffectContainer`, Übergänge per `glassEffectID`. Kein Glass auf Glass.
   * Kein eigenes Opazitäts- oder Blur-Tuning: Bei „Transparenz reduzieren“ und „Kontrast erhöhen“ passt das System Glass selbst an.
   * Materialien (`.regularMaterial` usw.) nur noch in der Inhaltsebene, wo kein Glass vorgesehen ist.
2. **Semantische Systemfarben & Kontrast:**
   * Verwende ausschließlich adaptive Systemfarben (`Color.primary`, `Color.secondary`, `Color(uiColor: .systemBackground)`, `Color(uiColor: .secondarySystemGroupedBackground)`).
   * Verkehrsmittel-Farben (Tram: Rot, S-Bahn: Grün, U-Bahn: Blau, Bus: Violett, Regio: Orange) müssen im Light Mode und Dark Mode sowie bei aktiviertem „Kontrast erhöhen“ (`accessibilityContrast == .high`) die WCAG-AAA-Kontrastwerte erfüllen.
3. **Schatten und Ränder:**
   * Nutze kontinuierliche Eckradien (`RoundedRectangle(cornerRadius: 16, style: .continuous)`).
   * Kein eigener Innenrand auf Glass (das System zeichnet die Kante). Ein 0.5pt-Rand (`.strokeBorder(.separator, lineWidth: 0.5)`) nur für Inhalts-Cards ohne Glass im Dark Mode.

### 4.2 Typografie, Zahlen und SF Symbols
1. **Typografische Disziplin:**
   * Alle Zeitangaben, Countdowns und Verspätungen nutzen zwingend `.monospacedDigit()`, damit sich das Layout beim Herunterzählen von Sekunden oder Minuten niemals verschiebt (kein Layout-Jitter).
   * Für den primären Aufbruchs-Countdown auf der Hero Card und in der Dynamic Island wird `.fontDesign(.rounded)` (`SF Pro Rounded`) im Gewicht `.bold` eingesetzt.
2. **Numerische Text-Transitionen:**
   * Jede sich ändernde Zahl (Countdown bis zum Losgehen, verbleibende Meter beim Fußweg, Verspätungs-Delta) muss mit `.contentTransition(.numericText(countsDown: true))` versehen werden, um das typische mechanische Rollen von Apple-Zahlen auszulösen.
3. **SF Symbols 6 Animationen & Rendering:**
   * Keine Emojis im gesamten Projekt.
   * Nutze `.symbolRenderingMode(.hierarchical)` oder `.symbolRenderingMode(.palette)` für mehrschichtige Tiefe.
   * Setze gezielte Symbol-Effekte ein: `.symbolEffect(.pulse, options: .repeating)` für aktive Live-Verbindungen, `.symbolEffect(.bounce, value: currentStep)` beim Erreichen einer Umsteigehaltestelle und `.symbolEffect(.variableColor.iterative)` während der laufenden Routenberechnung.

### 4.3 Interaktions-Design, Ergonomie & 120Hz Reaktivität
1. **Einhand-Bedienbarkeit (Thumb Zone):**
   * Alle primären Aktionen (Suchfeld im Ruhezustand, Auswahl der Hero Card, Start-Button für die Navigation) befinden sich in der unteren Bildschirmhälfte innerhalb des Bottom Sheets.
   * Jedes interaktive Element besitzt eine minimale Touch-Fläche von `44 x 44 pt` (`.contentShape(Rectangle())`).
2. **Unterbrechbare Physik-Animationen:**
   * Lineare Animationen (`.linear`) sind für UI-Übergänge verboten. Nur unterbrechbare Federn, ausschließlich über die zentralen Konstanten in `Motion` (keine Werte direkt im View-Code). Werte nach Apple *Designing Fluid Interfaces* (Dämpfung 1.0 = kein Überschwingen, Standard; Überschwingen nur, wenn eine Geste Schwung mitgibt):

     | Konstante | Wert | Einsatz |
     |---|---|---|
     | `Motion.standard` | `.spring(response: 0.4, dampingFraction: 1.0)` | Zustandswechsel, Morphing, Kamerafahrten, Ein-/Ausblenden von Overlays |
     | `Motion.micro` | `.spring(response: 0.25, dampingFraction: 1.0)` | Mikro-Interaktionen (Schalter, Aufklappen von Zwischenhalten) |
     | `Motion.momentum` | `.spring(response: 0.3, dampingFraction: 0.8)` | nur nach Wisch-/Ziehgesten mit Schwung, mit Übergabe der Gestengeschwindigkeit |

   * Sheet-Rastpunkte animiert das System selbst; dort keine eigene Feder.
   * Animationen starten immer vom aktuellen Bildschirmwert (SwiftUI-Federn tun das von selbst); Eingaben werden während einer Animation nie gesperrt.
   * Bei `accessibilityReduceMotion`: `.transition(.opacity)` statt Bewegung, Kamera ohne Fahrt setzen.
3. **Barrierefreiheit (Accessibility First):**
   * Unterstütze `Dynamic Type` von `.xSmall` bis `.accessibility3`. Bei extremen Schriftgrößen wechselt die horizontale „Leg-Bar“ (Verkehrsmittel-Leiste) über `ViewThatFits` automatisch in eine vertikale Liste.
   * Gruppiere zusammengehörige Informationen (z. B. die gesamte Hero Card) für VoiceOver mit `.accessibilityElement(children: .combine)` und liefere einen präzisen gesprochenen String (z. B. „Beste Verbindung: In 7 Minuten losgehen. 6 Minuten Fußweg, dann Straßenbahn 4 Richtung Hauptbahnhof. Pünktlich.“).
   * Respektiere `accessibilityReduceMotion`: Wenn aktiviert, ersetze Kamerafahrten und `matchedGeometryEffect`-Morphing durch sanftes Überblenden (`.opacity`).

---

## 5. Verpflichtende Prüf-Checkliste vor jeder Code-Ausgabe
Bevor du als Agent eine Datei oder ein Modul ausgibst, prüfe intern folgende 7 Punkte:

1. **Zero-Emoji-Check:** Enthält der Code, ein Kommentar oder ein UI-String ein Emoji? (Falls ja: sofort durch SF Symbol oder klaren Text ersetzen).
2. **Concurrency-Safety:** Ist jede Klasse/Struktur für Swift 6 Strict Concurrency (`Sendable`, `@MainActor`, `actor`) korrekt annotiert? Blockiert irgendeine Berechnung (z. B. Polyline-Dekodierung) den Main-Thread?
3. **Privacy-Leak-Check:** Werden in diesem Modul Daten an das Backend gesendet, die dort nicht zwingend für das Routing gebraucht werden?
4. **VPN-Check:** Verlässt sich eine `MapKit`- oder Netzwerk-Funktion auf implizite IP-Lokalisierung statt auf explizite `CoreLocation`-Parameter?
5. **Layout-Jitter-Check:** Haben alle dynamischen Zeit- und Distanz-Labels `.monospacedDigit()` und `.contentTransition(.numericText())`?
6. **HIG-Material-Check:** Wird Liquid Glass nur in der Bedienebene und ohne eigenes Tuning verwendet, kommen alle Animationen aus `Motion`, werden semantische Farben und kontinuierliche Eckradien (`style: .continuous`) verwendet?
7. **Error-Resilience:** Sind alle `try`-Aufrufe sauber über typisierte Fehler (`enum TransitError: LocalizedError`) abgefangen und in ein ruhiges, nicht-blockierendes Inline-Banner (statt eines störenden `Alert`-Popups) übersetzt?

---

## 6. Aktivierungs-Prompt für die Entwicklungsumgebung

Nutze diesen Befehl, um den Agenten gemeinsam mit der `SPEZIFIKATION.md` zu starten:

```text
Lade die Dateien SPEZIFIKATION.md und AGENT.md in deinen primären Kontext. Du arbeitest ab sofort strikt unter dem Mandat von AGENT.md (Principal Apple Security Architect & Apple HIG Evangelist).

Deine Aufgabe:
Überprüfe jeden einzelnen Schritt der Implementierung gegen die Sicherheits-, Datenschutz- (OWASP MASVS-L2 / Zero-Knowledge-Routing / VPN-Resilienz) und Design-Vorgaben (Apple HIG / 120Hz Fluid Interfaces / SF Symbols / Monospaced Digits) aus AGENT.md.

Bestätige kurz, dass du beide Dokumente vollständig geladen hast, und beginne dann direkt mit der produktionsreifen, sicherheitsgehärteten Implementierung von Meilenstein 1 und dem zugehörigen Swift-6-Netzwerk- & Security-Layer (inkl. TLS 1.3 Ephemeral URLSession und SPKI Public-Key-Pinning).
