# Status

| Meilenstein | Inhalt | Stand |
|---|---|---|
| 1 | Node.js-Backend (Express 5, MOTIS 2 / Transitous, /api/locations, /api/routes, /api/refresh) | fertig, auf dem Server live (24.10.), **von Carlo freigegeben (24.10.)** |
| 2 | Swift Core-Engine & SwiftData, Netzwerk-/Security-Layer (TLS 1.3, ephemeral, SPKI-Pinning) | offen |
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

## Offene Punkte / Risiken
- **Tests:** `npm test` crashte mit Node 26 / Vitest 5 (rolldown) nach altem Install; nach `rm -rf node_modules && npm ci` laufen alle 70 Tests grün.
- **Live-Test:** Cloud- und Mac-Sandbox sperren `api.transitous.org`; der Smoke-Test läuft nur im macOS-Terminal.
- **SPKI-Pin:** Caddy nutzt `reuse_private_keys`. Zusätzlich mit `deploy/spki-hash.sh new-backup` einen Offline-Backup-Schlüssel erzeugen und beide Pins in der App hinterlegen.
- **Server:** siehe Abschnitt "Hosting und Veröffentlichung".

## Hosting und Veröffentlichung (24.10.2026)
- **Live:** Server steht (Hetzner CAX11, Falkenstein), Backend und Caddy laufen, TLS 1.3, Let's-Encrypt-Zertifikat, 70 Tests grün auf arm64, Live-Suche über Transitous erfolgreich. Details: `docs/DEPLOYMENT.md`.
- **Offen:** zweiter SPKI-Pin (Backup-Schlüssel), eigene Domain statt rDNS-Name, Transitous kontaktieren.
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
- [ ] Backup-SPKI-Schlüssel erzeugen (`deploy/spki-hash.sh new-backup`), offline verwahren, beide Pins in die App.
- [ ] Eigene Domain statt Hetzner-Hostname (Caddyfile, App-Host, neue Pins).
- [ ] Projekt-Kontaktadresse für User-Agent prüfen (aktuell Repo-URL), Repo öffentlich machen.
- [ ] OSM-Namensnennung und Transitous-Quellenlink in der App.
- [ ] Bearer-Token durch App Attest ersetzen, bevor die App über den Eigengebrauch hinausgeht.

## UI/UX
Pausiert bis zum 25.10. Figma-Datei "TransitPlanner – Design-Plan": Übersicht mit Zustandsfluss, Farb-Tokens (hell/dunkel) und Typografie vorhanden. Es fehlen Komponenten, Screens, Dynamic Island/Widgets, Statistik, Quellenangabe-Screen und Fehlerzustände.
