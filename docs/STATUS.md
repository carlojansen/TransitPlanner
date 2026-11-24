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

**Ausgerollt 16.11.:** Backend auf dem Server (Servertests 93/93, `healthz` ok, 401 ohne Token, Anfrage mit Zwischenstopp Düsseldorf Hbf nach Köln Hbf über Leverkusen Mitte über den Server liefert 2 Verbindungen).

**UI-Review 16.11.:** 1 Hoch (Alternative unterwegs behielt erreichte Stopps) und 6 weitere Befunde behoben: Alternative übernimmt die gesendeten Stopps, Aufenthalt zählt bis zum Start des Fußwegs, Umstiegszahl nur mit folgendem Fahrzeug, nicht erkannte Stopps fallen unterwegs weg, Peek ab dem Stopp startet nach dem Aufenthalt, Koordinate aus Haltestellen in der Nähe, VoiceOver und Haptik. Neue Strings in `Localizable.xcstrings` (von Xcode übernommen). Tests: App 202/0, TransitCore 173/0. Gegenproben "Alternative übernimmt via nicht" und "Aufenthalt bis Abfahrt" je rot.

**Offen:** Gerätetest bei Carlo (Planen, Navigation, Alternativen unterwegs). Karte nennt die Grenze weiter "Umstieg"; "Umstieg knapp/reicht nicht" heißt am Stopp weiter "Umstieg". Stepper bei AX-Schriftgrößen ungeprüft. "Mein Standort" als Zwischenstopp wird ohne Haptik abgewiesen. Stufe B (Geschäfts-Pins, Navigationsschritt "Aufenthalt") nicht begonnen.

## Proaktive Umplanung unterwegs (Spezifikation 18.11., Plan wartet auf Freigabe)

Spezifikation: `docs/SPEZIFIKATION.md` 4.4. Kein API-Vertrag betroffen (nur bestehende Suche ab Stop-ID und Zeit). Vorhanden und wiederverwendet: `brokenConnection`, `openAlternatives` samt `PeekOrigin.nextStation`, `navMissedVehicles`, `syncActivities`, Retry-After-Sperre. Neu ist nur der automatische Auslöser, die Entscheidungsregel und die Ablehn-Erinnerung.

**Plan** (Reihenfolge verbindlich, nach jedem Schritt Tests grün, vor Schritt 4 und 6 Review):
0. **Live prüfen, bevor gebaut wird:** Suche ab Umstiegshalt mit Echtzeit-Ankunft gegen Transitous (Smoke, im macOS-Terminal). Klären: liefert MOTIS ab einer Stop-ID mit Zeit in der Zukunft sinnvolle Alternativen, und taugt `nextStation` für den Ausstiegshalt mehrere Halte voraus? Wie startet die Navigation, wenn der erste Abschnitt der Alternative beginnt, während der Nutzer noch im Fahrzeug sitzt? (Entschieden: Wechsel vormerken, siehe C.) Erlaubt MOTIS ab einer Bahnsteig-Stop-ID Umstiege auf andere Gleise, und liefert es ab einer Stop-ID Abfahrten ohne Umstiegszeit? Ergebnis in dieses Dokument.
1. **Logik in TransitCore** (`ConnectionWatch`, rein, ohne UI und Netz): Auslöser, Suchstart, Auswahl, Ablehnen mit Verschlechterungsschwelle, Verfall, Ende. Neue Bedeutung als Typ (`ReplanProposal`, `ReplanTrigger`), keine optionalen Parameter mit Standardwert. Regeln nur hier, App ruft sie auf.
2. **Tests dazu** (Abnahmeliste in 4.4), danach **Gegenproben**: je Regel entfernen, Test muss rot werden. Erst dann weiter.
3. `security-hig-reviewer` prüft Schritt 1 und 2 (RAM-only, Mitteilungstext, Limits, Deep-Link-Prüfung). Blocker beheben.
4. **Einbau in AppFlow:** Auslöser im Refresh- und Positionstakt, Suche über das bestehende `openAlternatives`-Fundament, Zustand bei `endNavigation` und `arrived` löschen. Tests mit Fake-Planner und Fake-Uhr.
5. **UI und Mitteilung:** Banner, vorbelegtes Alternativen-Blatt, lokale Mitteilung, Live-Activity-Zustand. VoiceOver, Dynamic Type, Reduce Motion, 44 pt, keine Emojis.
6. Review (Security und HIG) über den ganzen Diff, Befunde beheben, `xcodebuild test` und `npm test` grün.
7. STATUS aktualisieren, **Stopp: Gerätetest und Freigabe durch Carlo** (Fahrt mit echter Verspätung oder Simulation).

**Stand 18.11.:** Schritt 0 erledigt (live, `npm run smoke:replan`): Suche ab Bahnsteig-ID mit Echtzeit-Ankunft liefert Alternativen, MOTIS liefert Abfahrten ohne Umstiegszeit (Filter in `pick` nötig) und die betroffene Fahrt selbst (muss ausgeschlossen werden), Gleiswechsel am Knoten möglich, `via` hinter dem Suchstart hält den Aufenthalt ein. Schritt 1 und 2 erledigt: `ConnectionWatch`, `ReplanMemory`, `ReplanProposal` in TransitCore. Review (`security-hig-reviewer`) FREIGABE, 0 Blocker; die 5 mittleren Befunde sind behoben (mehrere betroffene Fahrzeuge, Rangfolge statt Listenreihenfolge, Weiterfahrt im selben Zug erlaubt [Carlo], Obergrenze für gescheiterte Suchen, `ReplanProposal` mit `isValid`) samt den niedrigen (Ersatzschlüssel mit Halt, Freigabe ohne Abfahrtszeit, Test "Suchzeit nie vor jetzt"). TransitCore 213/0, 30 Gegenproben alle rot. Spezifikation 4.4 nachgezogen (9484715). Zweiter Review: FREIGABE, 0 Blocker; die 2 mittleren Befunde sind behoben (Schlüssel stabil bei Gleiswechsel, Suchen nacheinander bis Antwort; `decline` auch für Suche ohne Alternative) plus Test-Gegenproben für die Weiterfahrt. Offen niedrig: `brokenConnection` liefert nur den ersten gebrochenen Anschluss (C rastet erst im Fahrzeug B ein). Der Zug, in dem man sitzt, ist bewusst nicht Teil der Funktion [Carlo]. **Schritt 4 erledigt (AppFlow):** gemeinsame `alternativesQuery`, `evaluateReplan`, `acceptReplan`/`declineReplan`, `pendingSwitch`/`startSwitch`, vereinheitlichtes Einrasten (`replanLatched`), Aufräumen in begin/end/arrival; Wechseln aus dem Blatt mit späterem Start merkt vor. Review: FREIGABE, 3 Major (Einrasten auf dem Umstiegsweg, Vorschlag nicht neu geprüft, Blatt-Wechsel) und Minor behoben, je mit rotem Test ohne Fix. TransitCore 219/0, App 223/0. Noch offen: Reviewer sah die Nachbesserung nicht (kommt mit Review in Schritt 6). **Schritt 5 umgesetzt (18.11., nicht committet, nicht reviewt):** Jetzt-Karte zeigt den Vorschlag als Hinweis "Anschluss <Linie> reicht nicht mehr" (bzw. "fällt aus") mit dem besten Vorschlag und "Übernehmen", "Behalten", "Alternativen ansehen"; nach "Übernehmen" "Wechsel auf <Linie> vorgemerkt" statt "reicht nicht"; nach Verfall 60 s "Anschluss <Linie> reicht wieder" (`AppFlow.replanNoticeSeconds`), bei anderen Enden still. Ableitung in `AppFlow.replanBanner`, Texte für Banner und Mitteilung einmal in `AppFlow.replanTexts` (Linie, dann `ReminderText.body`). Lokale Mitteilung über `ReplanNotifying` (`SystemNotifier`, Fake in `FakeNotifier`): Kategorie `replan` ohne Aktionen, `timeSensitive`, feste Kennung, Vorschlags-ID im `userInfo`; gesendet nur im Hintergrund, entfernt über `replanOffer.didSet` bei Verfall, Übernehmen, Behalten, Ankunft, Beenden. Tipp und "Alternativen ansehen" über `showProposal` (ID, Phase `.navigation`, vor Suchstart, gleiche Prüfung wie `acceptReplan`); das Blatt ist mit der Antwort und dem Suchstart vorbelegt, "Wechseln" darin merkt ab dem Suchstart vor. Die 5-Minuten-Schwelle für einen neuen Vorschlag bleibt `ConnectionWatch.worseningSeconds`. Tests: TransitCore 219/0, App 231/0 (8 neu, einer davon mit 5 Fällen); 9 Gegenproben (ID, Zeit, nur Hintergrund, Entfernen, Suchstart im Blatt, vorbelegtes Blatt, "vorgemerkt", Verfall nur bei Wiederreichen, Hinweis endet) je rot. Offen: neue Strings nicht in `Localizable.xcstrings` (Xcode übernimmt sie beim Build in der IDE), Phasen-Prüfung beim Tipp ohne eigene Gegenprobe (jedes Verlassen der Navigation verwirft den Vorschlag ohnehin), nicht am Gerät gesehen, Review in Schritt 6. **Review Schritt 5 behoben (18.11., nicht committet):** Vormerkung bindet nur Anschlüsse nach dem Ausstiegsfahrzeug; bis dorthin wird normal ausgewertet (Einrasten, Haptik, Problem "Anschluss", "fällt aus"), bricht dort etwas weg, entfallen Vorschlag und Vormerkung (`ConnectionWatch.isUndercut`), gewechselt wird nur im bzw. nach dem Ausstiegsfahrzeug (`ConnectionWatch.pendingSwitch`), "vorgemerkt" ersetzt nur "reicht nicht" danach (`Hint.brokenVehicle`). Vorschlags-ID bleibt je Vorschlag, die bisherige Alternative bleibt solange erreichbar (`pick(keeping:)`), Suchzeit je Tick nachgeführt, Textänderung still ersetzt (`.passive`). Antworten je Schlüssel gemerkt. Alternative muss am Suchstart beginnen (ID, Bahnsteig-Präfix oder 300 m). "Wechseln" im Stand `.skeleton` merkt mit Fahrplan-Gehzeiten vor; Blatt merkt die Fahrt statt der Zeile. Wechsel ohne Refresh während Rate-Limit, Retry-After des Wechsel-Refresh wird übernommen; scheitert die Prüfung: Hinweis "Wechsel auf <Linie> nicht mehr möglich", im Hintergrund Mitteilung ohne Vorschlags-ID. Sperrbildschirmtext ohne Ausstiegshalt (`ReminderText.departure`). Kategorie mit `customDismissAction` (Wischen = Behalten, gleiche ID-Prüfung) und Platzhalter für verborgene Vorschauen. Ersatzschlüssel mit Haltname (Gleiswechsel ohne Fahrt-ID). Knöpfe: 44 pt im Label, "Bewegung reduzieren" ohne Feder. Tests: TransitCore 224/0, App 242/0; neue Tests an HEAD e923751 rot bzw. per Mutation rot geprüft. Offen: Gerätetest, neue Strings in `Localizable.xcstrings` (Carlo in der IDE), Review der Nachbesserung. **Re-Review behoben (18.11., nicht committet):** Vormerkung startet nur am Suchstart (Ausstiegsfahrzeug, Weg daraus, Gleis/verpasste Abfahrt des direkt folgenden Fahrzeugs, Zielweg nur nach dem letzten Fahrzeug); ist der Schritt schon weiter, bevor die Echtzeit-Ankunft erreicht ist, wird verworfen. Nach der Ankunft startet ein weiterer Schritt wie bisher, weil er dort nur Fahrplan-Annahme ist (wörtliche Regel "immer verwerfen" macht 6 Wechsel-Tests rot, geprüft). Abgelehnte Fahrzeuge gelten auch nach dem Aussteigen (`ConnectionWatch.declined`, gleiche Regel wie `ReplanMemory.isDeclined`); Prüfung am Suchstart ab max(Ankunft, jetzt); Alternative ohne Zugangsweg an anderer Halt-ID: Luftlinie mal Gehtempo; Blatt ohne Gehzeiten rechnet Fahrplan-Gehzeit mal Gehtempo (eine Regel mit `calibrate`); verpasst mit Position rastet vor der Auswertung ein; Vorschlags-Mitteilung im Vordergrund nur still in der Liste; Hinweis blendet bei "Bewegung reduzieren" über. Tests: TransitCore 229/0, App 246/0, 12 Gegenproben rot. Offen: Vormerkung verwerfen, wenn der ursprüngliche Anschluss wieder reicht (in 4.4 nicht geregelt, Entscheidung Carlo); Review der Nachbesserung. **Zweites Re-Review behoben (18.11., nicht committet):** Nach der Ankunft prüft der Wechsel einen frischen Fix (`ConnectionWatch.awayFromStart`, höchstens `freshFix` alt): sicher weiter als 300 m vom Suchstart heißt im Ausstiegsfahrzeug warten, sonst verwerfen (Nutzer sitzt im nicht ausgefallenen ursprünglichen Anschluss); dieselbe Prüfung nach dem Refresh in `startSwitch`; ohne Fix wie bisher. Weiterfahrt im selben Zug wird gegen die Ankunft geprüft (`ReplanSearch.arrival`), alle anderen Alternativen ab max(Ankunft, jetzt). Per Position verpasste Fahrzeuge verwerfen die Vormerkung auch, wenn sie vorher behalten wurden. Tests: TransitCore 232/0, App 248/0, 4 Gegenproben rot.
Für Schritt 4 vermerkt: (a) Fahrt-Identität liegt beim Aufrufer, `ReplanMemory` und Einrasten bei `beginNavigation`, Wechsel nach "Übernehmen" und `endNavigation` zurücksetzen (Test); (b) `AppFlow` hat eine eigene Einrast-Regel (`connectionBroken`, `releaseMissedVehicles`), danach nur noch die aus `ConnectionWatch` für Karte, Live Activity und Vorschlag. Offene Entscheidung: Fällt das Fahrzeug, in dem man sitzt, unterwegs aus (Zug endet vorzeitig), löst das heute nichts aus (Standard: nicht Teil dieser Funktion).

**Bestandteile und Einbau (Entwurf 18.11., vor Review):**

A. `TransitCore/ConnectionWatch.swift` (neu, rein, Sendable, ohne UI/Netz/Uhr; `now` kommt als Parameter)
- `ReplanTrigger`: `.connectionBroken(vehicle:)`, `.tripCancelled(vehicle:)`; `ReplanKey` (Fahrt-Schlüssel, Fahrzeug, Art); `ReplanSearch` (Auslöser, `TripEndpoint` des Ausstiegshalts, Zeit, Puffer in s).
- `ConnectionWatch.trigger(journey:step:latched:walks:now:pace:)`: nutzt `NavigationEngine.brokenConnection` und `Leg.cancelled`; nur bei `onBoardTransit` oder `transferRouting` vor der Ankunft, nie bei `waitingAtPlatform`. Das Einrasten (bisher Nebeneffekt von `AppFlow.connectionBroken` über `navMissedVehicles`) wird eine reine Funktion hier; Live Activity, Karte und Auslöser lesen dasselbe Set (Filter `>= ahead`), und `connectionBroken` kennt danach auch Ausfälle.
- `ConnectionWatch.search(for:in:now:)`: Ausstiegshalt = `destination` des Fahrzeugs vor dem betroffenen, Zeit = `arrival ?? plannedArrival`, nie vor `now`; Stop-ID, sonst Koordinate (wie `nextStation`).
- `ConnectionWatch.pick(_:for:)`: erste Alternative nach Rangfolge, ohne betroffenen Anschluss, nicht `missed`.
- Zustand als Wert: `declined: [ReplanKey: Int]` und `searched: [ReplanKey: Int]` (Puffer beim Ablehnen bzw. bei der Suche), `ReplanKey` = Fahrt und Fahrzeug ohne Art; `isSuppressed(key, bufferSeconds:)` mit `worseningSeconds = 300`, höchstens 3 Suchen je Fahrt, `retryDelay = 60`; Verfall nur mit Hysterese (`minimumSlackSeconds`).
- `pick` prüft zusätzlich: erste Abfahrt frühestens Suchzeit + Gehweg + `minimumSlackSeconds` (`TransferCheck` prüft nur Umstiege innerhalb der Alternative).
- `remainingVia` ab dem Fahrzeug vor dem betroffenen, nicht ab dem Zielfahrzeug.

B. `TransitCore`: eigener Typ `ReplanAlert` mit Kennung `replan.<navKey>` und zufälliger Vorschlags-ID, **nicht** in `ReminderAlert.Kind` (sonst falsche Kategorie, `replaceAlerts`/`purge` löschen sie, Tipp ginge an `openReminder`). `ReplanText` (Linie, Halt, Abfahrt, Gleis; nur Halte mit `Place.kind == .stop`, nie Koordinaten-Labels).

C. `AppFlow.swift`
- Eine gemeinsame Funktion für die Anfrage der Alternativen, herausgezogen aus `openAlternatives`; Start und Zeit sind Parameter statt `nextStation` (Ziel, `modes`, `accessibility`, `via`, Aufenthalt). Beide Aufrufer nutzen sie, die Regel steht einmal.
- Zustand: `proposal: ReplanProposal?` (beobachtet, mit Antwort, Gehzeiten, `via`, Index aus der kalibrierten Antwort), `watch` und `replanTask` (`@ObservationIgnored`).
- `evaluateReplan(now:)` **nur** am Ende von `navigationUpdate`, vor `syncActivities` (kein zweiter Aufruf in `refreshNavigation`); hält an bei `blockedUntil`, `navExpired`, ohne Fahrt. Schlüssel vor dem Task-Start synchron markieren; Ergebnis prüfen (Fahrt, Schlüssel, Phase, Auslöser aktiv, Zeit vor Suchstart).
- **Wechsel vormerken (Entscheidung Carlo 18.11.):** `acceptProposal()` setzt `pendingSwitch`; Navigation und Refresh der alten Fahrt laufen weiter; bei Ankunft am Suchstart wird die Alternative mit frischem Refresh geprüft und gestartet (`beginNavigation`). Dieselbe Regel für "Wechseln" aus dem Blatt bei späterem Start (heutiger Fehler: `navStep = nil`, Puffer mit Position im Zug).
- `declineProposal()` merkt den Schlüssel und entfernt die Mitteilung.
- Aufräumen in `beginNavigation`, `endNavigation` **und im `.arrival`-Block** (`.arrival` zählt als `isGuiding`): Zustand, Task, Mitteilung.

D. Mitteilung: `SystemNotifier.request` wählt die Kategorie je Art, beide Kategorien werden in `TransitPlannerApp` registriert; `replan` hat nur die Aktion "Ansehen". `AppDelegate.didReceive` verzweigt zuerst nach `categoryIdentifier`; `flow.showProposal(id)` wirkt nur bei passender Vorschlags-ID, Phase `.navigation` und Zeit vor Suchstart. Senden nur bei `inBackground`; Entfernen bei Verfall, Übernehmen, Ablehnen, Ankunft, Beenden. Ein Vorschlag darf auch aus `.skeleton` entstehen, falls die Kalibrierung im Hintergrund scheitert.

E. UI (`NavigationViews.swift`): Zeile mit "Übernehmen" und "Behalten", dazu "Alternativen ansehen" (öffnet das bestehende Blatt mit Suchstart); Texte in `Localizable.xcstrings`. Die Live Activity zeigt in v1 nur das bestehende `Problem.connection`, kein neuer Zustand (Spezifikation 4.4 ist angeglichen); `TripActivity.problem` muss dafür auch den Ausfall eines späteren Fahrzeugs kennen, nicht nur das Zielfahrzeug.

F. Tests: `TransitCoreTests/ConnectionWatchTests.swift` (Abnahmeliste aus 4.4), Ergänzung in `ReminderTests`, `TransitPlannerTests/ReplanFlowTests.swift` (Fake-Planner, Fake-Uhr, `FakeNotifier`), dann Gegenproben je Regel. Commits klein: Core mit Tests, Mitteilungstexte, Flow, UI.

**Offene Entscheidungen (Standard in Klammern, gilt ohne Gegenwort):** Mitteilung als `timeSensitive` (ja, wie der Aufbruch-Wecker); Schwelle für einen neuen Vorschlag nach Ablehnen (5 Minuten); nur bester Vorschlag im Banner, Rest über das Alternativen-Blatt (ja).

## Fußweg-Vorrang im Backend (18.11., Wunsch Carlo)

Regel in `routes()` (`transitService.js`): Ist das Ziel laut MOTIS (`direct`) zu Fuß in höchstens 15 min erreichbar, liefert das Backend nur ÖV-Verbindungen, die kürzer dauern als der Fußweg. Bleibt keine übrig, kommt der reine Fußweg (`walkOnly: true`). Nicht mit `via`. Keine zusätzliche Anfrage; `docs/API.md` ergänzt.

Tests: Backend 94/0 (ein neuer Test mit drei Fällen: Fußweg 10 min mit schneller und langsamer Bahn, Fußweg 20 min unverändert). Commit `c642d29`, gepusht. Kein Review durch `security-hig-reviewer`.

**Offen:** Deployment auf den Server (Carlo macht es selbst). Die App-Seite ist nicht angepasst: sie zeigt bei `walkOnly` weiter nur den Fußweg, prüfen am Gerät. Schwelle 15 min ist als Konstante `WALK_PREFERRED_SECONDS` fest; "15" wurde als Minuten gelesen.

### Nachbesserung Fußweg-Vorrang und Umplanung (18.11., Code-Check mit drei Opus-Agents)

**Backend:** Der Vorrang vergleicht jetzt die Ankunft statt der Fahrtdauer (Wartezeit zählt mit; bei Gleichstand gewinnt der Fußweg; nur erste Seite, ohne `via`). Plan und Refresh teilen `motisParams`, der Refresh fragt Wege und Schritte nur noch mit `polylines`. `removedLongDistance` wird nach dem zweiten Versuch nicht mehr doppelt gezählt. `docs/API.md`: ein Absatz für Fußweg-Vorrang/`walkOnly`, einer für Rate-Limits. Tests Backend 101/0.

**App:** Ein reiner Fußweg gilt bei der Umplanung als erreichbar (`ConnectionWatch.isReachable`), Wechsel darauf ohne Refresh. `switchTask` endet mit der Vormerkung. Anzeige: größte Verspätung aller Fahrzeuge, gleiche Ankunftszeit im Alternativen-Blatt, "Ankunft hh:mm (+n Min.)" im Vorschlag, "ZU FUSS" ohne "direkt", VoiceOver-Plural. Tests TransitCore 232/0, App 251/0. Review `security-hig-reviewer`: Freigabe.

**Offen (klein):** "+n Min." vergleicht Fahrplan- mit Gehtempo-Ankunft; `chosen.journey.isWalkOnly` statt doppelter Regel (AppFlow ca. 1781); beim Wechsel auf Fußweg Zeiten auf jetzt verschieben; Tests für Fußweg-Vorschlagstext und Verwerfen während Refresh; Katalogschlüssel "%@%lld Minuten Fußweg" und "Etwa " löschen. Weiter offen: Vormerkung verfällt, wenn der Anschluss wieder reicht (Entscheidung Carlo), `directWalkSeconds`/`walkSeconds` für "Zu Fuß 12 Min." (API-Änderung), Meldungen mit `validUntil`/`url`, Blättern ohne 404, Smoke-Test, Deploy durch Carlo, "15" als Minuten bestätigen.

## Fall-Protokoll und "Bericht senden" (23.11., Wunsch Carlo)

**Ziel:** Tester liefern Daten für Fixes und Tests, ohne Aufwand und ohne Personenbezug. Das Backend erhält nichts (API.md, Abschnitt "Bericht").

**Umgesetzt:**
- `TransitCore/CaseLog.swift`: Ringpuffer (200 Einträge, gleiche Einträge nur einmal), Eintrag mit Zeit auf 5 Min. und Ort auf 2 Stellen gerundet, nur benannte Zahlen. Drei Auslöser als reine Regeln: `departureNearMiss` (Apple-Gehzeit gegen MOTIS, Fall U5), `replanLate` (Vorschlag über 60 s nach dem Anschlussbruch, Schwelle ist eine Annahme), `arrivalWithoutGPS` (Fahrt per Zeit beendet, Position über 25 m vom Ziel). `CaseReport` (JSON, Schema 1) und `CaseLogStore` (Datei, Dateischutz bis zur ersten Entsperrung, vom Backup ausgenommen, nicht lesbare Datei wird nicht überschrieben).
- `AppFlow`: drei Auslöser eingebunden, Ort immer ein Halt der Fahrt, nie Standort oder Adresse. `Dependencies`: `loadCaseLog`/`saveCaseLog`.
- Einstellungen: "Bericht senden" nur in TestFlight (StoreKit-Umgebung `.sandbox`, offline verborgen) und Debug; Vorschau, Teilen über `ShareLink`, Datei im temporären Ordner und beim Verlassen gelöscht.
- Agent `report-analyst` (nur lesen, Datenschutz-Check zuerst, Tabelle mit Testfall-Entwürfen); Ablage `feedback/` (in `.gitignore`).

**Prüfung:** TransitCore 243/0, App 251/0, Release-Build grün. Gegenprobe für die Near-Miss-Bedingung. `security-hig-reviewer`: erster Lauf 3 Blocker (Ort, Dateischutzklasse, Backup), behoben; zweiter Lauf 1 Blocker (veralteter App-Beleg bricht den Release-Build), behoben. Dritter Review nach den letzten Korrekturen steht aus (Carlo lässt ihn laufen).

**Offen (klein):** Protokoll wird nur beim Start geladen (Überschreiben der Historie nach Entsperren theoretisch möglich; `save` zusammenführen); Vorschau als ein Text (VoiceOver: eine Zeile je Eintrag); `arrivalWithoutGPS` ohne jede Position schreibt nichts (Darstellung klären); kein App-Test für die Einbindung in `AppFlow`; Oberfläche nicht am Gerät oder Simulator angesehen.

**Dritter Review (23.11.):** Freigabe, 0 Blocker. Umgesetzt danach: `departureNearMiss` nur bei Apple-Quelle des Zugangswegs (Fahrplan-Fallback wäre nur der Tempo-Faktor); gleiche Art, Zeit und Ort nur einmal (Zahlen des letzten Mals); Protokoll nur dort geführt, wo der Bericht angeboten wird, mit "Protokoll löschen"; kein Ausweichen in den temporären Ordner; Dateiname mit Ortstag; Test räumt auf. Bewusst offen: `PrivacyInfo` (CoarseLocation, Diagnostics) vor einer App-Store-Freigabe, Messlogik `latchedAt` ohne eigenen Test, Datei-I/O auf dem Main Actor (30 KB).

**Nachtrag 24.11. (nicht committet, nicht reviewt):** Fehler behoben: Die TestFlight-Erkennung lief nur in den Einstellungen, bis dahin verwarf das Protokoll in TestFlight jeden Fall; jetzt beim Start (`AppDelegate`). Neu: Kartenknopf "Etwas stimmt nicht" (nur TestFlight/Debug, oben rechts, auch unterwegs) schreibt `userMark` mit Phase, Schritt, Verspätung, Puffer, Ort = Einstieg des Zielfahrzeugs; Haken und Haptik als Bestätigung. MetricKit: `metrics` (täglich CPU, Speicher, Vorder-/Hintergrund, GPS, Mobilfunk, Abbrüche) und `diagnostics` (Abstürze, Hänger als Zähler, Stack über TestFlight), erst nach der TestFlight-Erkennung protokolliert. Vertrag in `docs/API.md`. Tests: TransitCore 244/0, App 252/0 (1 neu), Release-Build grün. Review (`security-hig-reviewer`): FREIGABE, 0 Blocker; MAJOR behoben (Markierungen und Diagnosen werden nie zusammengefasst, Test mit Gegenprobe rot), dazu Haptik je Tipp, "Bewegung reduzieren", Test außerhalb der Fahrt (TransitCore 245/0, App 253/0). Bewusst offen: MetricKit-Umrechnung ungetestet in `AppDelegate` (Pakete im Test nicht erzeugbar), `@ScaledMetric` für die Kartenknöpfe, `PrivacyInfo` vor App Store. Aufgeräumt (24.11.): Leer- und Fehlerzustand der Berichtsansicht als `ContentUnavailableView` (Schreibfehler zeigt nicht mehr "leer"), alle neuen Texte im Katalog, `report-analyst` kennt `userMark`, `metrics`, `diagnostics` mit Richtwerten. Offen: am Gerät ansehen (MetricKit liefert erst nach etwa einem Tag, im Debugger über "Simulate MetricKit Payloads"), Testnotizen in TestFlight, Build-Nummer erst zum Wochenende.

**Als Nächstes (Plan, Carlo 24.11.):** Favoriten, dann Tickets anzeigen. Gleis Köln später. U5-Ursache ist nicht belegt; die ersten Berichte klären sie. Ungeklärt: "Fahrten aus der Vergangenheit" (laufende Fahrt prüfen oder Verlauf-Liste).

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
