# Status

| Meilenstein | Inhalt | Stand |
|---|---|---|
| 1 | Node.js-Backend (Express 5, MOTIS 2 / Transitous, /api/locations, /api/routes, /api/refresh) | fertig, auf dem Server live (24.10.), **von Carlo freigegeben (24.10.)**; Audit-Fixes (be2abc8) deployt und geprüft (25.10.) |
| 2 | Swift Core-Engine & SwiftData, Netzwerk-/Security-Layer (TLS 1.3, ephemeral, SPKI-Pinning) | umgesetzt (24.10.), Review-Befunde (NACHBESSERN) behoben, Tests grün, von Carlo freigegeben und committet (24.10.); Backup-Pin eingetragen, Release-Gate grün |
| 3 | SwiftUI-Interface & Animationen, Navigations-State-Machine | umgesetzt (Etappen 1-3, 26.10.), Review-Befunde behoben, Tests grün; **von Carlo freigegeben (31.10.)** |
| 4 | Erinnerungen, WidgetKit, ActivityKit | Plan auditiert und von Carlo freigegeben (31.10.): Etappe 1 Erinnerungen, 2 Fundament (Widget-Target, App Group, Snapshot), 3 Live Activity (geplanter Start T-15 ohne Server, Gerätetest zuerst), 4 Widgets; Abfahrtsmonitor und EventKit entfallen. Etappe 1 umgesetzt (31.10.), Review und Re-Review ohne offenen Blocker, Befunde behoben, Tests grün, **am Gerät getestet und von Carlo freigegeben (1.11.)**; Etappe 2 umgesetzt (1.11.); Etappe 4 umgesetzt (1.11.); Etappe 3 umgesetzt (1.11.), Review nach vier Läufen FREIGABE (2.11.); **von Carlo freigegeben (2.11.)**, Restpunkte am Gerät siehe Ende von Etappe 3 |
| 5 | Statistik-Dashboard (Swift Charts) | offen |

Ältere Abschnitte (Meilensteine 1 bis 4, Audits, Hosting, UI-Verlauf bis 3.11.) stehen unverändert in `docs/STATUS-ARCHIV.md`, samt der dort notierten offenen Geräte-Punkte. Nur lesen, wenn die Aufgabe sie betrifft.

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
- **Tests:** `npm test` crashte mit Node 26 / Vitest 5 (rolldown) nach altem Install; nach `rm -rf node_modules && npm ci` laufen alle Tests grün (aktuell 79).
- **Live-Test:** `npm run smoke` lief am 16.11. aus Claude Code heraus (lokal am Mac); die Cloud-Sandbox sperrt `api.transitous.org` weiterhin.
- **SPKI-Pin:** Caddy nutzt `reuse_private_keys`. Backup-Pin ist in der App; der Offline-Backup-Schlüssel muss von Carlo außerhalb der iCloud verwahrt werden.
- **SSH-Zugang:** Die Firewall-Regel hängt an Carlos wechselnder IP. Bei jedem IP-Wechsel muss sie angepasst werden.
- **Server:** siehe "Hosting und Veröffentlichung" im Archiv und `docs/DEPLOYMENT.md`.

## Release-Aufgaben (bewusst ans Ende gestellt, Entscheidung Carlo 24.10.)
- [ ] LICENSE wählen und ergänzen (Empfehlung MIT; Transitous verlangt Open Source vor breiter Nutzung).
- [ ] Transitous per Matrix kontaktieren (privat, nicht kommerziell, Last: max. 60 Anfragen/min, typisch wenige).
- [x] Backup-SPKI-Schlüssel erzeugt, beide Pins in der App (24.10.). Offen bei Carlo: Schlüssel offline außerhalb der iCloud verwahren.
- [ ] Lizenz in `backend/package.json` (derzeit `UNLICENSED`, `private: true`) zusammen mit LICENSE anpassen.
- [x] Eigene Domain: entfällt (Familien-App, Hetzner-Hostname reicht; Entscheidung 26.10.).
- [ ] Projekt-Kontaktadresse für User-Agent prüfen (aktuell Repo-URL), Repo öffentlich machen.
- [ ] OSM-Namensnennung und Transitous-Quellenlink in der App.
- [ ] Bearer-Token durch App Attest ersetzen, bevor die App über den Eigengebrauch hinausgeht.

## Gleisnummern Köln und Rangformel (10.11.)

Anlass: Rückmeldung vom Gerät ("Gleis 76" in Köln Süd, unsinnige Route als beste Verbindung). Eine Live-Anfrage an Transitous (Düsseldorf Hbf nach Köln Weyertal) als Beleg.

**Gleis (Backend, `resolveTracks` in `mapper.js`):** In den DELFI-Daten für Köln ist `Place.track` eine interne Nummer (Köln Süd 76, Messe/Deutz 90), das echte Gleis steht in `Place.description` ("Bahnsteig Gleis 1"). In Düsseldorf stimmt `track` ("Gleis 15+16"). Regel: Nennt die Beschreibung genau eine Nummer, die einem numerischen `track` widerspricht, und liegt kein Echtzeit-Gleiswechsel vor, gilt die Beschreibung für Gleis und geplantes Gleis. Nur für Stop-IDs `de-DELFI_de:05315:` (Köln), weil nur dort belegt; anderswo ist "Bahnsteig 3" nicht das Gleis. Schema unverändert, `docs/API.md` ergänzt.

**Rangformel (`DurationLabel.swift`):** Jede Gehminute kostet eine Minute extra (`walkWeight`, alle Fußwege), eine ausgefallene Fahrt bekommt die 7-Tage-Strafe und steht nur vorn, wenn es keine andere gibt. Fehlt die Dauer eines Fußwegs, zählt Ankunft minus Abfahrt. Zwei Alt-Tests an die neue Gewichtung angepasst, Aussage laut Review erhalten.

Review durch `security-hig-reviewer`: **FREIGABE**, 0 Blocker, 1 MAJOR (Regel galt für alle Feeds), behoben durch die Beschränkung auf Köln und numerische Gleise; dazu Ziffernbegrenzung und Rückfall der Gehdauer. Diese Nachbesserung ist nicht erneut reviewt.

Tests: Backend 90/0 (`npm test`), TransitCore 166/0 (`swift test`). Gegenproben vor der Nachbesserung: ohne Gleis-Regel 2 Tests rot, ohne Gehzeit-Term 3, ohne Ausfall-Strafe 2. Kein xcodebuild, kein Simulator, nicht am Gerät gesehen. Das Backend ist am 10.11. ausgerollt (healthz ok, 401 ohne Token; keine Routenanfrage über den Server geprüft).

**Offen:** Echtzeit-Gleiswechsel in Köln zeigt weiter interne Nummern. Führende Nullen ("Gleis 01") nicht behandelt. Kein Test für den Rückfall der Gehdauer und für die Ankunftssuche mit Gehzeit. Weitere Regionen mit internen Nummern unbekannt. Ursache der fehlenden U75 nicht belegt (in der Live-Anfrage kamen genau 4 Verbindungen). Noch nicht begonnen: Zeile mit vielen Linien und Details-Ansicht, Auswahl nach Rang im Backend (bis 6), Hinweis bei Ausfall und Störung in der Hero Card.

## Anzeige langer Verbindungen (10.11.)

Anlass: zwei Screenshots vom Gerät (aufgeblähte Zeile bei vier Linien, Gleis am Tram-Ausstieg).

**Weitere Verbindungen (`AlternativeRow`):** Ursache per Messung belegt (`sizeThatFits`, 338 pt Breite): Der Status stand neben vier festen Badges, bekam fast keine Breite und brach zeichenweise um, 170 pt. Jetzt Zeiten und Status oben, Badges darunter im vorhandenen `FlowLayout`, rund 88 pt. Bei AX-Größen steht die Dauer unter dem Block, damit der einzeilige Status nicht über den Rand läuft.

**Fahrtdetails:** Leg-Bar der ganzen Kette im Kopf (für VoiceOver stumm). Am Ausstieg Gleis nur bei S-Bahn, Regio und Fernzug oder bei echtem Gleiswechsel (`Leg.showsArrivalPlatform`); gilt auch für die Restfahrt in der Navigation, die Umstiegskarte zeigt weiter beide Gleise. In `docs/DESIGN.md` vermerkt; Figma ist seit 10.11. nicht mehr Maßstab (Carlo), es gilt das bestehende UI der App.

Review durch `security-hig-reviewer`: **FREIGABE**, 0 Blocker, 3 MAJOR (Status-Überlauf bei AX, Gleiswechsel am Ausstieg unsichtbar, Regel in der Navigation nur halb), alle behoben; die Nachbesserung ist nicht erneut reviewt.

Tests: `xcodebuild test` ohne UI-Tests (iPhone 17): TransitCore 166/0, App 189/0, davon 4 neu (Höhe, Breite bei AX mit Ersatzverkehr, Gleis-Regel).

**Offen:** Nicht am Gerät gesehen. Am Gerät wirkte die Zeile höher als die gemessenen 170 pt und der Status fehlte ganz, beides ungeklärt. Bei Wechsel nur des Ausstiegsgleises meldet der Hinweis in der Ergebnisliste "Gleis 2 statt 2" (vorbestehend). Höhentests hängen an festen Pixelwerten. Weiter offen: Auswahl nach Rang im Backend, Hinweis bei Ausfall in der Hero Card.

**Nachtrag Gerät (10.11., Screenshot):** Die Zeile mit vier Linien bricht am iPhone wie geplant um. Als beste Verbindung stand aber eine ausgefallene Fahrt, darunter eine pünktliche. Erklärung aus dem Code, nicht aus den Daten belegt: Ausfall und "Umstieg reicht nicht" kosteten beide 7 Tage, dann entschied die frühere Ankunft; die Zeile zeigte für die Alternative nur "pünktlich". Geändert: Ausfall kostet doppelt (`cancelledPenalty`), die Zeile zeigt "Umstieg reicht nicht" vor "pünktlich". Nicht reviewt.

## Zwischenstopps (16.11., Idee Carlo)

Ziel: Plus neben Von/Nach, Nutzer fügt bis zu 2 Zwischenstopps hinzu (keine gespeicherten Stopps). Stufe A: Haltestelle über die bestehende Suche plus Aufenthalt in Minuten. Stufe B: Geschäfts-Pins auf der Karte (lokal per MapKit), die App wählt die Haltestelle mit der kürzesten Gehzeit, Fußwege und Aufenthalt werden lokal in die Lücke gelegt, Navigation bekommt einen Schritt "Aufenthalt".

**Live-Befund (Transitous, Düsseldorf Hbf nach Köln Hbf über Leverkusen Mitte, 20 Min.):** MOTIS hält den Aufenthalt ein (Abfahrt und Ankunftssuche), er zählt als Umstieg. Die Lücke liegt zwischen der Ankunft am Stopp und dem folgenden Umstiegsweg. Die Leg-Grenze trägt Bahnsteig-IDs (`…:21101:7:73`), sogar eine Flixbus-ID als Via wurde auf den DELFI-Bahnhof abgebildet; die App muss den Stopp deshalb über die Nähe finden, nicht über die ID. Antwortzeit 0,9 bis 2,4 s.

**Backend (Stufe A, Schritt 1):** `via: [{id, stayMinutes}]` in `docs/API.md`, Schema (max. 2, 1 bis 180 Min., keine Doppelten, nicht Start/Ziel, nur ID und Minuten) und Service (`via`/`viaMinimumStay` kommagetrennt, kein `walkOnly`-Rückfall). 3 neue Tests, Smoke-Test um eine Route mit Zwischenstopp ergänzt (live grün). Tests: Backend 93/0.

Review durch `security-hig-reviewer`: **FREIGABE**, 0 Blocker, 2 Mittel, 5 Niedrig. Mittel 1 (`parentId` mitliefern) entfällt: MOTIS liefert ihn an der Via-Grenze nicht (live geprüft), die App nutzt ID-Präfix, sonst Nähe. Mittel 2 (Rundtour ohne Verbindung) live widerlegt: Start und Ziel 350 m auseinander über Leverkusen liefert 2 Verbindungen. Niedrig: Tests für Paging und zweiten Versuch mit `via` ergänzt, Smoke-Reihenfolge korrigiert, API.md präzisiert ("nur exakte ID"); die Umstiegswertung der Via-Grenze kommt in Schritt 2. Nachbesserung nicht erneut reviewt.

**TransitCore (Schritt 2):** `ViaStop` (nur ID und Minuten gehen ans Backend, Label und Koordinate bleiben lokal, Minuten auch beim Dekodieren auf 1 bis 180 begrenzt), `via` in `RoutesRequest`, `TripRequest`, `ManualTripRequest` (optional, alte gespeicherte Fahrten bleiben lesbar). Der Request bereinigt selbst (max. 2, keine Doppelten, nicht Start/Ziel). `Journey.viaStays` findet den Aufenthalt: zuerst über die ID (exakt oder Präfix), nur ohne ID-Treffer über die Nähe unter 300 m und nie an der Grenze eines anderen Stopps; bei mehreren Treffern die längste Pause; am letzten Fahrzeug zählt der folgende Fußweg; Echtzeit mit Rückfall auf Plan. Tests gegen eine echte Transitous-Antwort (`Fixtures/routes-via.json`). Rangformel unverändert: jede Via-Verbindung zählt den Aufenthalt gleich als Umstieg, die Reihenfolge ändert sich nicht. Review: **FREIGABE**, 0 Blocker, 3 Mittel, 5 Niedrig; behoben bis auf "Verspätung frisst den Aufenthalt" (geht in die Anzeige von Schritt 3: echte Dauer statt geplanter). Tests: TransitCore 173/0, 9 Gegenproben rot. Nachbesserung nicht erneut reviewt.

**UI Stufe A (Schritt 3):** Plus neben Von/Nach öffnet die bestehende Suche mit Slot `via`; nur Haltestellen (Adressen und "Mein Standort" abgelehnt, Hinweis über der Liste), max. 2, nicht doppelt, nicht Start/Ziel, nie in Verlauf oder Favoriten. Je Stopp Zeile in der Von/Nach-Karte mit Stepper (5 bis 120 Min., Standard 15) und Entfernen. Tauschen dreht die Reihenfolge. `PlanKey` enthält `via` (Offline-Reserve zeigt keine Antwort ohne neuen Stopp). Fahrtdetails: Block "Aufenthalt <Name> · <n> Min." mit echter Dauer, Warnung "Aufenthalt nur <n> Min." bei Verspätung; Umstiegszahl ohne erkannte Aufenthalte (Hero, Zeile, Kopf, VoiceOver). "Nächste Verbindung" und Alternativen unterwegs behalten noch nicht erreichte Stopps; Erinnerungen speichern `via`. Tests: App 195/0, 6 Gegenproben rot (eine Lücke beim `PlanKey` gefunden und per Test geschlossen). **Nicht reviewt** (Carlo hat vor dem Review den Gerätetest freigegeben, 16.11.).

**Offen:** Review der UI. Gerätetest bei Carlo. Karte nennt die Grenze weiter "Umstieg"; Alternativen unterwegs zählen den Aufenthalt als Umstieg; "Umstieg knapp/reicht nicht" heißt am Stopp weiter "Umstieg". Stufe B (Geschäfts-Pins, Navigationsschritt "Aufenthalt") nicht begonnen. Ursprünglich danach Schritt 2 (TransitCore: `via` in Requests, Erkennung der Leg-Grenze, Rang) und Schritt 3 (UI Stufe A).

## Ideen (nicht geplant, nicht begonnen)

### Engel-Modus (10.11., Idee Carlo)

Abends eine Route, auf der man wenig läuft und gut warten kann, dazu eine Vertrauensperson ("Engel"), die mitbekommt, wo man ist. Engel vorher festgelegt oder spontan über Teilen.

**Route:** Schalter beim Planen, der nur die Gewichte der Rangformel ändert: Fußwege zählen stärker (letzter Weg besonders), Warten an kleinen Haltestellen kostet, an großen Bahnhöfen nicht; weniger Umstiege, kein knapper Umstieg, keine letzte Fahrt des Abends ohne Rückfall. Die Anzeige nennt den Grund ("8 Min. warten in Neuss Hbf"), nie "sicher": Studien finden keinen belegten Nutzen von Sicherheits-Apps und warnen vor falschem Sicherheitsgefühl. Beleuchtung aus OSM (`lit`) ist lückenhaft, höchstens Bonus.

**Teilen, geräteübergreifend:** Apple "Wo ist?" und Wegbegleitung gehen nur zwischen iPhones und lassen sich nicht aus der App starten; WhatsApp-Live-Standort und Google Maps gehen auf beiden Systemen, aber nur von Hand. Deshalb eigener Link über das iOS-Teilen-Menü, der im Browser jedes Handys läuft. In Stufen:
1. Ohne Server: Text mit Abfahrt, Ankunft und Linien über das Teilen-Menü.
2. Link mit Live-Stand (Karte, Ankunft, letzter Standort, Meldung bei Ausfall oder Umplanung). Standort auf dem Gerät verschlüsselt, Schlüssel nur im Link, Server löscht nach Ankunft.
3. Alarm bei Nicht-Ankunft per Push an Familienmitglieder mit App.

**Face ID:** "Nicht mehr teilen" und "Bin angekommen" nur mit Face ID. Schwäche: lässt sich erzwingen; robuster wäre ein Code mit Alarm-Variante.

**Vor Beginn zu klären:** Stufe 2 bricht die Regel, dass das Backend keinen Personenstandort bekommt; nur verschlüsselt und nach bewusster Änderung von CLAUDE.md und SPEZIFIKATION. Standort im Hintergrund nicht geprüft. Alarm für Engel ohne App bräuchte SMS (Kosten) oder Web-Push. Bei Minderjährigen: Wer darf das Teilen beenden? Bedarf laut BKA-Dunkelfeldstudie 2026: nachts im ÖPNV fühlen sich 33 % der Frauen sicher, 57 % der Männer.
