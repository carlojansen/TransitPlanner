# Status

| Meilenstein | Inhalt | Stand |
|---|---|---|
| 1 | Node.js-Backend (Express 5, MOTIS 2 / Transitous, /api/locations, /api/routes, /api/refresh) | fertig, auf dem Server live (24.10.), **von Carlo freigegeben (24.10.)**; Audit-Fixes (be2abc8) deployt und geprüft (25.10.) |
| 2 | Swift Core-Engine & SwiftData, Netzwerk-/Security-Layer (TLS 1.3, ephemeral, SPKI-Pinning) | umgesetzt (24.10.), Review-Befunde (NACHBESSERN) behoben, Tests grün, von Carlo freigegeben und committet (24.10.); Backup-Pin eingetragen, Release-Gate grün |
| 3 | SwiftUI-Interface & Animationen, Navigations-State-Machine | offen |
| 4 | Erinnerungen, WidgetKit, ActivityKit | offen |
| 5 | Statistik-Dashboard (Swift Charts) | offen |

## Datenquelle: Wechsel von der DB zu Transitous (24.10.2026)
Der erste Live-Test gegen die DB-Navigator-API (`db-vendo-client`) scheiterte mit `OPS_BLOCKED`: Seit Mitte
Oktober 2026 blockt der Bot-Schutz (Akamai) der DB Anfragen anhand des TLS-Fingerabdrucks, unabhängig von IP
und User-Agent. Der verbreitete Workaround (Browser-Fingerabdruck vortäuschen) umgeht eine bewusst gesetzte
Zugangssperre und wird hier nicht verwendet. Entscheidung von Carlo: **Transitous** (öffentliche MOTIS-Instanz).

Abweichungen von SPEZIFIKATION 7 durch den Wechsel:
- **Keine Auslastung** (`loadFactor` immer `null`) und **keine Wagenreihung**.
- **Stop-IDs** sind opake MOTIS-IDs (z. B. `de-DELFI_de:05111:18235`), keine EVA-Nummern.
- **Gewinne:** Polylines für alle Verbindungen in einer Anfrage (kein Nachladen), Linienfarben, Fußwege mit
  Geometrie, Echtzeit-Flag pro Abschnitt, offene Daten ohne rechtliche Grauzone.

## Entscheidungen in Meilenstein 1
- **Offizieller MOTIS-Client** (`@motis-project/motis-client`), exakt gepinnt auf die Version, die Transitous betreibt (2.11.1). Nicht `motis-fptf-client`: der bildet MOTIS auf das alte HAFAS-Format ab, hat keine Umkreissuche und lädt beim Start den kompletten DB-Stationsdatensatz.
- **Listen-Parameter selbst serialisieren:** Der generierte Client sendet Arrays als wiederholte Parameter, MOTIS erwartet kommagetrennt (`explode: false`). Ohne Korrektur wäre der Nahverkehrsfilter still auf ein Verkehrsmittel geschrumpft.
- **Nahverkehrsfilter ohne `RAIL`:** In MOTIS schließt `RAIL` Hochgeschwindigkeits- und Fernverkehr ein. `REGIONAL_RAIL` deckt RE/RB/IRE ab. Zusätzlich serverseitiger Filter nach Modus und Zuggattung.
- **Umkreissuche** über `/api/v6/map/stops` (Rechteck um den gerundeten Standort), lokal auf 500 m gefiltert.
- **Refresh-Platzhalter:** MOTIS antwortet bei nicht mehr rekonstruierbaren Fahrten mit 200 und einem Platzhalter-Abschnitt (cancelled, interner Fehlertext als Alert). Das Backend erkennt das und meldet `REFRESH_EXPIRED` statt eines falschen Ausfalls.
- **Drossel:** Retry nur bei transienten Netzwerkfehlern und 502/504; 429/503 pausieren alle Upstream-Anfragen global für `Retry-After`. Keine Weiterleitungen (`redirect: error`). Das globale Routen-Limit greift erst nach der Authentifizierung.
- **Datenqualität aus dem Live-Test:** Gleisangaben normalisiert ("Gl. 1" -> "1"), Zugnummer aus Liniennamen entfernt, Haltestellen aus mehreren Datensätzen zusammengefasst (DELFI-ID bevorzugt).
- **Nur Haltestellensuche im Backend:** Adressen löst die App lokal per `MKLocalSearch` auf.
- **Echter Abbruch bei Timeouts:** Die Drossel (`lib/upstreamGate.js`) löst ein `AbortSignal` aus, das bis zu `fetch` durchgereicht wird. Begrenzte Warteschlange, Mindest-Restbudget.
- **Fehlerbodies von Transitous werden verworfen**, nur der HTTP-Status wird klassifiziert (Bodies können Eingaben spiegeln).
- **Auth:** gemeinsamer Bearer-Token (in der App in der Keychain). Vor einer öffentlichen Version durch App Attest ersetzen.
- **TLS:** Node lauscht nur auf `127.0.0.1`; Caddy terminiert ausschließlich TLS 1.3 und filtert Query-Strings, IPs und Auth-Header aus dem Log.

## Meilenstein 2: Core-Engine (24.10.2026)
Nur Logik, keine UI (UI/UX pausiert bis 25.10.). Code unter `ios/`, Projekt per `cd ios && xcodegen generate`.

**Gebaut (`ios/TransitCore`, Swift Package, Swift 6, Strict Concurrency):**
- `BackendConfig`: einzige Stelle für Host und Pins. Primärer Pin `/G2ucqajVU17fdDE+oayjXlVEGDIEqe0/eo+4dK6i9Q=` (ECDSA P-256, am 24.10. gegen das Live-Zertifikat geprüft), Backup-Pin seit 24.10. eingetragen. `isPinningReleaseReady` ist erst mit zwei verschiedenen Pins `true`.
- `TransitError`: die 9 Backend-Codes mit identischen Rohwerten; ein Test liest `docs/API.md` und bricht bei Abweichung. Zusätzlich lokale Fälle mit Präfix `CLIENT_` (offline, Pinning, Dekodierung, Token fehlt, Keychain, Standort, Abbruch).
- Codable-Modelle nach API.md v0.2 (Journey, Leg, Place, Stopover, Remark, Line, Polyline, Attribution, Antworten). Unbekannte `mode`-Werte werden `.unknown` statt Dekodierfehler.
- `TransitAPIClient` (actor): Bearer aus der Keychain, fester User-Agent, Umkreis auf 3 / Routing auf 4 Nachkommastellen gerundet, Textsuche ohne Standort, `Retry-After` sperrt weitere Anfragen lokal (max. 300 s), keine Weiterleitungen.
- `PinnedSessionTransport`: `ephemeral`, TLS 1.3, `waitsForConnectivity` (mit 45-s-Obergrenze), kein URLCache, keine Cookies/Credentials; Delegate prüft Systemvertrauen + Hostname + Leaf-SPKI-SHA-256 (fail closed).
- `KeychainSecretStore`: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, Data-Protection-Keychain. Token, Schlüssel für lokale Verschlüsselung, refreshTokens geplanter Fahrten.
- `CoreLocationService` (nur CoreLocation, `CLLocationUpdate.liveUpdates`, Genauigkeit/Alter/Timeout), `SearchService` (MKLocalSearch nur mit Region aus dem GPS-Fix; ohne Fix keine Adresssuche, Haltestellen trotzdem).
- `HybridRouteCalculator`: Skelett vom Backend, danach alle eindeutigen Fußwege parallel per `withThrowingTaskGroup` über `MKDirections` (.walking, ETA) x `WalkingPaceFactor`; Fallback auf MOTIS-Dauer bei Fehler oder Weg < 25 m; Umstiegs-Puffer (`TransferCheck`), Ankunft inkl. letztem Fußweg.
- `WalkingPaceFactor`: lernend (erst Mittelwert, dann Glättung 0.2), Ausreißer und Wege < 60 s verworfen, Bereich 0.5–2.0, manueller Override.
- `DepartureScheduler`: `Aufbruch = Abfahrt (inkl. Echtzeit) - kalibrierter Zugangsweg - Stationspuffer (120 s)`, Stufen T-15/T-5/T-0, Neuplanung nach Refresh (verschieben ab 60 s, Ausfall oder unmöglicher Umstieg = `connectionLost`).
- SwiftData: `FavoritePlace`, `RecentSearch`, `PlannedTrip` (Orte/Labels/Kalender-Kennung AES-GCM-verschlüsselt, Schlüssel in der Keychain), `CachedStop`, `PaceProfile`. Store ohne iCloud, Ordner und Dateien `completeUntilFirstUserAuthentication`.
- `TripRequest`-Protokoll mit `TripTrigger` (manuell, Favorit, Kalender) und `TripRequestProvider` als Einhängepunkt für EventKit. `routesRequest()` ist die einzige Umwandlung in einen Backend-Request (nur Punkte, Zeit, Filter).
- App-Target `TransitPlanner`: nur leerer Einstiegspunkt, Standort-Begründung, `PrivacyInfo.xcprivacy` (präziser Standort, nicht verknüpft, kein Tracking, App-Funktion; keine Required-Reason-APIs).

**Tests (nach Nachbesserung):** `swift test` (macOS): 56/56 grün. `xcodebuild test` Schema `TransitPlanner` (iPhone 17, iOS 26.5, `-parallel-testing-enabled NO`): 56/56 Paket-Tests + Keychain-Test im App-Host grün, Release-Gate übersprungen. Schema `TransitPlanner-ReleaseGate`: **rot wie beabsichtigt** (Backup-Pin fehlt). Keychain-Test läuft im App-gehosteten Target, weil Paket-Tests ohne Host `-34018` bekommen. Pin-Test gegen das echte Leaf-Zertifikat (gültig bis 22.01.2027) und Bodies gegen die zod-Schemata des Backends geprüft. `xcodebuild test` blieb auf diesem Mac anfangs beim Start des Test-Runners hängen (Simulator, nicht Code); mit `-parallel-testing-enabled NO` stabil.

**Entscheidungen:**
- `targetTime` wird in UTC mit `Z` gesendet (gültiges ISO-8601 mit Offset, verrät keine Zeitzone).
- Lokale Fehler als eigene `CLIENT_*`-Fälle im selben Enum, damit "alle Fehler als TransitError" gilt, ohne Backend-Codes zu verfälschen. Vom Server gesendete `CLIENT_*`-Codes werden ignoriert.
- Pinning nur auf das Leaf (beide Pins sind Leaf-Schlüssel, Caddy `reuse_private_keys`). Unterstützt EC P-256/P-384; RSA scheitert bewusst.
- Kein NSPinnedDomains in der Info.plist: Host und Pins sollen nur an einer Stelle stehen.
- MKDirections `calculateETA` statt voller Route (die Geometrie liefert das Backend).
- Bundle-ID `de.carlojansen.transitplanner` (von Carlo bestätigt, 24.10.).

**Abweichungen von der Spezifikation:**
- "Parallele DB- und MKDirections-Abfrage": Die Fußwege hängen von den Haltestellen der Antwort ab, deshalb läuft erst das Backend, dann alle Fußwege parallel. Progressiv wie in 2.2 (erst Skelett, dann Gehzeiten).
- Widget-Target `TransitPlannerWidgets` noch nicht angelegt (Meilenstein 4). `CompletedTrip`-Statistikmodell folgt in Meilenstein 5. Live-GPS-Stream für die Navigation folgt mit der State-Machine in Meilenstein 3.
- Prädiktives Pre-Fetching (2.2) ist als API vorhanden (`nearbyStops`), der Auslöser beim App-Start kommt mit der UI.

**Grenzen / offen:**
- **Backup-Pin eingetragen (24.10.):** `0hkYwM2uh2/AMns6RP22FPaDZ2Zk/GjJVRHdz4hqvWI=`. Das Schema `TransitPlanner-ReleaseGate` ist grün. Der private Schlüssel liegt im Schlüsselbund; Offline-Kopie bei Carlo (nicht im Repo).
- Token-Eingabe in die Keychain braucht UI (Meilenstein 3); bis dahin kein Live-Test der App gegen den Server.
- MKDirections hat kein Limit paralleler Anfragen; bei Drosselung durch Apple begrenzen.
- Echte CoreLocation-/MapKit-Aufrufe sind nur über Fakes getestet (brauchen Gerät/Netz).

**Nachbesserung nach Security-Review (24.10.):**
- **Blocker behoben, dann verschärft (Carlo, 24.10.):** Suchmodus ist Pflicht. `SearchService.search(_:scope:)` hat keinen Standardwert; `.address` sucht nur lokal per MKLocalSearch, `.stops` nur im Backend (ohne Standort). Die frühere Adress-Heuristik entfällt, weil sie Straßen ohne Endung nicht erkannte. Die Oberfläche (Meilenstein 3) muss den Schalter „Adresse / Haltestelle“ sichtbar zeigen, mit Debounce von mindestens 300 ms oder Suche bei Return.
- Sichtbare Texte mit Umlauten über `String(localized:)` und String Catalog (`TransitCore/Resources/Localizable.xcstrings`, `TransitPlanner/InfoPlist.xcstrings`), Entwicklungssprache Deutsch.
- Pinning-Tests mit eigener Test-CA und Leaf (richtiger Pin, falscher Pin, nur CA-Pin, falscher Host, ohne Anker) und Delegate-Tests (Host-Abweichung, fehlender Trust, fremde Auth-Methode, Redirect = nil). Prüfdatum fest, Tests altern nicht.
- Niedrig-Befunde: `+`/`&`/`=` im Query werden prozentkodiert; fremde Challenge-Arten `performDefaultHandling`; Transport-Initializer nur noch `internal`; `Accept-Language: de` fest; `Retry-After` nur bei 429/502/503/504; Keychain-Schlüssel mit falscher Länge wirft `keychainFailure` statt zu überschreiben; `regionPriority = .required`; Session wird beim Freigeben des Transports mit `finishTasksAndInvalidate` beendet; `RoutesRequest.results` ist `private(set)`.
- **Release-Sperre:** `ReleaseGateTests` schlägt fehl, solange `BackendConfig.production.isPinningReleaseReady` false ist. Nur im Schema `TransitPlanner-ReleaseGate` (Release-Konfiguration) aktiv; im normalen Lauf übersprungen.

## Transitous-Nutzungsregeln (https://transitous.org/api/)
Umgesetzt: User-Agent mit Name, Version und Kontakt (beim Start erzwungen); keine Staging-/internen Endpunkte
(beim Start erzwungen); Quellenangabe für Transitous und OpenStreetMap in jeder Antwort (`attribution`) für die App;
sparsame, global begrenzte Drosselung (max. 60 Anfragen/min, davon max. 30 Routensuchen).

**Offen, VOR dem regelmäßigen Einsatz von Routing (`/plan`):**
- **Kontakt mit Transitous** im Matrix-Kanal. Die Regel lautet wörtlich: "Please contact us before using any potentially resource-intensive API endpoints (such as routing, isochrones) or doing many requests". Mitteilen: privates, nicht kommerzielles Projekt, ein Nutzer, geplante Last (Obergrenze 60 Anfragen/min, typisch wenige pro Tag; ab Meilenstein 4 Live-Polling aktiver Fahrten alle 20–60 s).
- **OSM-Namensnennung** in der App ("© OpenStreetMap-Mitwirkende" mit Link auf openstreetmap.org/copyright), zusätzlich zum Transitous-Quellenlink.

Offen, bevor die App über den Eigengebrauch hinausgeht:
- **Open Source:** Transitous verlangt, dass der Code unter einer Open-Source-Lizenz veröffentlicht ist ("light prototype testing before that is fine"). Ein privates GitHub-Repo ist für die Prototyp-Phase in Ordnung, für dauerhafte Nutzung nicht.
- **Nicht kommerziell:** keine Bezahl-App, keine Werbung.
- **Langfristig:** eigene MOTIS-Instanz auf dem Linux-Server (Datenhoheit, keine Last bei Transitous). Austausch nur über `MOTIS_BASE_URL`.

## Bekannte Grenzen
- **Nahverkehrsfilter:** Feeds mit generischem GTFS-Typ "Bahn" (route_type 2) landen in MOTIS als Regionalzug, Fernbusse (route_type 3) als Bus. Solche Fernverkehrs-Verbindungen werden erst nachträglich (Zuggattung/Betreiber) herausgefiltert und können echte Alternativen verdrängt haben. Bleibt nichts übrig, fragt das Backend genau einmal mit mehr Verbindungen nach; die Antwort meldet `removedLongDistance`.
- **Rufbusse/AST** (MOTIS-Modus ODM) sind bewusst ausgeschlossen (Voranmeldung nötig).
- **Keine Auslastung, keine Wagenreihung** (Transitous liefert das nicht).

## Backend-Audit (24.10.2026)
Vollständiges Audit des Backends durch `security-hig-reviewer`: kein Blocker im Bestand, 3 mittlere und 7 niedrige Befunde. Behoben vom `backend-engineer`, Re-Review mit **FREIGABE**, 79/79 Tests grün, `npm audit` ohne Befund. Commit be2abc8.
- **Body-Parser-Fehler** (z. B. falscher Zeichensatz) liefern `400 INVALID_REQUEST` statt `500`, ohne Error-Log. Nur echte body-parser-Fehlertypen mit Status < 500.
- **Limits pro IP** nach der Authentifizierung: `/api/locations` 20/min, `/api/refresh` 12/min, `/api/routes` 8/min vor dem globalen Routenlimit (abgewiesene Anfragen zählen nicht global). Über `.env` einstellbar (`RATE_LIMIT_*_PER_MINUTE`). Hinweis: Mehrere Geräte hinter einer IP (CGNAT, WLAN) teilen sich das Limit.
- **Keine `RateLimit-*`-Header mehr** (Blocker aus dem Review): express-rate-limit schrieb einen gekürzten, ungesalzenen IP-Hash (`pk=`) in die Antwort, und Caddy loggt Antwort-Header. Jetzt `standardHeaders: false`, zusätzlich löscht der Caddy-Log-Filter die Header. `Retry-After` bleibt.
- **Token-Rotation:** `API_TOKENS` (kommagetrennt) zusätzlich zu `API_TOKEN`, timing-safe gegen alle Einträge. Tokens 32–512 Zeichen, druckbares ASCII, beim Start geprüft.
- **Fehler-`details`** enthalten nur Feldpfade; unbekannte Felder erscheinen als `unknown_field`.
- **Cache-Schlüssel** für Suchtexte und Umkreis-Koordinaten als HMAC-SHA256 mit Zufallsschlüssel pro Prozess.
- **Zugriffslog:** bei 404 `<unmatched>` statt Pfad (kein beliebiger Text im Log). Offen (niedrig): festen Routennamen statt Platzhalter loggen.
- **systemd:** `MemoryMax=512M`, `TasksMax=64`, `DevicePolicy=closed`, `KeyringMode=private`, Node mit `--max-old-space-size=384`. `PrivateUsers=true` bewusst weggelassen (Lesbarkeit der `.env` ungeprüft, geringer Mehrwert).

**Deployt (25.10.):** healthz ok, `/api/*` ohne Token 401, keine `RateLimit-*`-Header, neue systemd-Grenzen aktiv.

## Offene Punkte / Risiken
- **Tests:** `npm test` crashte mit Node 26 / Vitest 5 (rolldown) nach altem Install; nach `rm -rf node_modules && npm ci` laufen alle Tests grün (aktuell 79).
- **Live-Test:** Cloud- und Mac-Sandbox sperren `api.transitous.org`; der Smoke-Test läuft nur im macOS-Terminal.
- **SPKI-Pin:** Caddy nutzt `reuse_private_keys`. Backup-Pin ist in der App; der Offline-Backup-Schlüssel muss von Carlo außerhalb der iCloud verwahrt werden.
- **SSH-Zugang:** Die Firewall-Regel hängt an Carlos wechselnder IP. Bei jedem IP-Wechsel muss sie angepasst werden.
- **Server:** siehe Abschnitt "Hosting und Veröffentlichung".

## Hosting und Veröffentlichung (24.10.2026)
- **Live:** Server steht (Hetzner CAX11, Falkenstein), Backend und Caddy laufen, TLS 1.3, Let's-Encrypt-Zertifikat, 70 Tests grün auf arm64, Live-Suche über Transitous erfolgreich. Details: `docs/DEPLOYMENT.md`.
- **Offen:** eigene Domain statt rDNS-Name, Transitous kontaktieren.
- **Das Backend läuft nicht auf Carlos Rechnern**, sondern auf einem gemieteten Server in Deutschland.
- **Plan:** Einstieg mit kleinster Stufe (2 vCPU, 4 GB reichen für den Proxy), monatlich kündbar, später vergrößern. Kandidat: Hetzner Cloud (Nürnberg/Falkenstein), Resize "nur CPU und RAM". IONOS VPS L Plus nur, wenn ohne lange Bindung und Preis inkl. MwSt. nach der Aktionsphase bekannt. Strato ist keine Alternative (teurer, weniger Leistung).
- **Voraussetzungen:** Domain/Subdomain (Let's Encrypt, SPKI-Pinning), SSH nur per Key, Firewall (443 offen, 22 nur eigene IP), `.env` mit Token nur auf dem Server anlegen.
- **Ausbau:** eigene MOTIS-Instanz (ca. 16 GB RAM) nur bei Bedarf, Umstellung über `MOTIS_BASE_URL`.
- **Repository:** erst privat, öffentlich erst nach der Checkliste. Transitous erlaubt das für die Prototyp-Phase.

**Checkliste vor dem Öffentlichmachen**
- [x] `.env` ist in `.gitignore` und war nie im Verlauf.
- [x] History und Docs durchsucht (24.10.): kein Token, kein Schlüssel, keine internen IPs oder Hosts. Treffer sind nur Testwerte und die private Gmail-Adresse.
- [x] Kontaktadresse: frisches Repo (24.10.), Autor = GitHub-noreply-Adresse, User-Agent-Kontakt in `.env.example` = Repo-URL. Die private Gmail steht nirgends mehr.
- [x] Bearer-Token auf dem Server neu erzeugt (nur dort in `.env`).
- [ ] LICENSE wählen und ergänzen.
- [ ] Kontakt mit Transitous (Matrix) aufnehmen.
- [x] Spezifikation Abschnitt 7 und Meilenstein-1-Prompt von `db-vendo-client` auf Transitous aktualisiert.

## Release-Aufgaben (bewusst ans Ende gestellt, Entscheidung Carlo 24.10.)
- [ ] LICENSE wählen und ergänzen (Empfehlung MIT; Transitous verlangt Open Source vor breiter Nutzung).
- [ ] Transitous per Matrix kontaktieren (privat, nicht kommerziell, Last: max. 60 Anfragen/min, typisch wenige).
- [x] Backup-SPKI-Schlüssel erzeugt, beide Pins in der App (24.10.). Offen bei Carlo: Schlüssel offline außerhalb der iCloud verwahren.
- [ ] Lizenz in `backend/package.json` (derzeit `UNLICENSED`, `private: true`) zusammen mit LICENSE anpassen.
- [ ] Eigene Domain statt Hetzner-Hostname (Caddyfile, App-Host, neue Pins).
- [ ] Projekt-Kontaktadresse für User-Agent prüfen (aktuell Repo-URL), Repo öffentlich machen.
- [ ] OSM-Namensnennung und Transitous-Quellenlink in der App.
- [ ] Bearer-Token durch App Attest ersetzen, bevor die App über den Eigengebrauch hinausgeht.

## UI/UX
Pausiert bis zum 25.10. Figma-Datei "TransitPlanner – Design-Plan" (am 24.10. über Chrome gelesen; die Figma-MCP-Schnittstelle ist durch das Starter-Limit blockiert, Lesen über den Browser funktioniert). Vorhanden: Übersicht mit Zustandsfluss, Farb-Tokens (hell/dunkel), Typografie, Screens Start, Suche, Routenauswahl (hell/dunkel), Navigation, Sperrbildschirm/Live Activity, Dynamic Island/Widgets, Statistik, erste Komponenten.
- **Behoben (25.10.):** Screen "2 Suche" hat jetzt den Pflichtschalter "Adresse / Haltestelle" unter der Suchleiste; die parallele Orte-Liste ist entfernt, Notizen auf Debounce mindestens 300 ms oder Return aktualisiert. Figma wird über die Plugin-API in der Chrome-Konsole bearbeitet (kein MCP-Limit).
- **Vollständiger Ablauf in Figma (25.10.):** "Screens nach Ablauf" in Zeilen A bis H, jede Spalte Screen + Notizkarte mit SwiftUI-Vorgaben. Neu: A1 Erster Start, A2 Server-Zugang (Eingabe/Gespeichert), 2b Suche Adresse, 2c Von/Nach und Zeit (Abfahrt/Ankunft, Verkehrsmittel-Chips), 3a Laden (Skelett), 3d Fahrtdetails (Zeitleiste), 4b Am Steig, 4c Im Fahrzeug, 4d Umstieg, 4e Ankunft, D1 Erinnerung einrichten, D2 Erinnerungen, D3 Mitteilungen, G1 Einstellungen, G2 Quellen und Lizenzen, H1 Komponente "Inline-Banner" (9 Fehlertypen), H2 Keine Verbindung, H3 Offline, H4 Dynamic Type AX3. Zustandsfluss in der Übersicht mit Abzweigen; alte Notizen auf Liquid Glass, MKLocalSearch und Motion-Konstanten nachgezogen.
- **Überarbeitung nach Feedback Carlo (25.10.):** Unterwegs (C) neu nach "Information zuerst": Jetzt-Karte oben (nächste Handlung groß, drei Zahlen, Hinweis), Karte nur Kontext mit Gleis-Pins, unten die nächsten Schritte; Leg-Bar, Kartenknöpfe und Aktualisieren-Knopf entfernt. Neu: 4e Ersatzverkehr und 3e Routenauswahl mit SEV. D1 Erinnerung: "Früher losgehen" (Stepper + Schnellwahl) und "Vorwarnen" als Hauptelemente, Rechnung sichtbar. A2 heißt jetzt "Dein Server" und erklärt, wozu der Schlüssel dient.
- **Datenlage dafür (geprüft in motis-client 2.11.1):** Gleis = `track`/`scheduledTrack` (schon in API.md als `departurePlatform`/`plannedDeparturePlatform`). Meldungen = `alerts` (schon als `remarks`). Wegbeschreibung im Bahnhof = `steps` am Fußweg mit `relativeDirection` (inkl. `STAIRS`, `ELEVATOR`) und `fromLevel`/`toLevel` aus OSM, Qualität hängt vom OSM-Indoor-Mapping ab. SEV = Bus-Abschnitt, erkennbar an `routeType` 714 oder Linienname. Apple Karten hat keine Bahnhofs-Innenpläne; MKDirections nur außerhalb von Bahnhöfen.
- **API v0.3 umgesetzt (25.10.):** Fußweg-`steps` (max. 60, nicht im Polling), `replacement` (route_type 714 oder SEV/Ersatzverkehr/Ersatzbus im Namen), `cause`/`effect` an Meldungen; `code` nur noch als String. 83 Tests grün, Review ohne Blocker. Offen: Deploy; einmal `npm run smoke` mit echter SEV- und Bahnhofsverbindung, Ausschnitt als Fixture übernehmen (Feldnamen bisher nur aus den Client-Typen belegt); iOS-Modelle nachziehen (tolerant dekodieren).
- **Konsistenz-Durchgang Figma (25.10.):** Neue Textstile App/Anweisung (36), App/Gleis (56), App/Kennzahl (22), alle Unterwegs-Überschriften und Zahlenreihen daran gebunden; Danach-Sheet in C mit festem Detent (237 pt); Jetzt-Karte mit 16 pt Rand wie alle Karten; Komponente "Karten-Hinweis" (Warnung/Kritisch, neue Variable `status/alertTint`) ersetzt die handgebauten Hinweise; Standort-Knopf immer oben rechts im Kartenknopf-Stapel; Segmented Control einheitlich 34 pt; A1-Sheet auf 16 pt Rand. 
- **Figma final (25.10.):** Abstände im 4er-Raster (Ausnahmen: 2 pt in Badges, 11 pt Innenabstand in 44-pt-Zeilen); neue Komponenten "Hauptknopf" (Aktiv/Deaktiviert) und "Einstellungszeile" (Titel, Wert, Chevron), überall eingesetzt; App-Farben an Variablen gebunden (ungebunden nur Systemflächen wie Dynamic Island und Notizzettel); Routenauswahl-Sheet auf 474 pt, damit die Quellenangabe Transitous/OSM sichtbar bleibt (war vorher abgeschnitten); Komponenten-Frame umbricht und überlappt die Screens nicht mehr.
- **Design-Entscheidungen darin (freigegeben von Carlo am 25.10.):** Einstellungen über Knopf rechts neben dem Suchfeld (kein dritter Kartenknopf); Mitteilungs-Erlaubnis erst bei der ersten Erinnerung; Standardsuchmodus "Adresse"; Optionen in 2c suchen erst auf Knopfdruck neu; Fahrtdetails als Zustand im Sheet statt Push.
- **Vorbereitung:** Recherche für Meilenstein 3 in `docs/RESEARCH-M3.md`.
- **Einstieg Meilenstein 3:** schmaler Testbildschirm (Token-Eingabe in die Keychain, Suche mit Pflichtschalter, Verbindungsliste, Quellenangabe), damit die App gegen den Server testbar wird; danach Design laut Figma.
