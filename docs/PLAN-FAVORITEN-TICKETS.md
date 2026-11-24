# Plan: Favoriten ausbauen, dann Tickets anzeigen

Stand: 24.11.2026. Entwurf zur Freigabe durch Carlo, noch kein Code.
Herkunft: `docs/STATUS.md`, "Als Nächstes (Plan, Carlo 24.11.): Favoriten, dann Tickets anzeigen."

## 1. Ausgangslage (aus dem Code, nicht geraten)

Favoriten gibt es schon in einer Grundform:

- Modell `FavoritePlace` (SwiftData, Ort AES-GCM-verschlüsselt, Feld `sortIndex`), Rollen Zuhause, Uni, Arbeit, weitere.
- Start-Sheet mit Kacheln, "Bearbeiten"/"Fertig", Entfernen per Minus, Wischen oder Kontextmenü.
- Hinzufügen nur über zwei Wege: leere Kachel belegen oder Wischen auf einer Verlaufszeile.
- Tipp auf einen Favoriten sucht sofort ab "Mein Standort", Zeit "Jetzt".

Tickets gibt es noch nicht: im Code und in den Docs kommt nichts dazu vor (kein Wallet, kein PassKit, kein Tarif).

## 2. Vorhaben

### Teil A: Favoriten (zuerst)

Die Grundform ist da. Der Ausbau schließt Lücken im Alltag. Vorschlag, klein gehalten:

| Nr. | Baustein | Nutzen |
|---|---|---|
| A1 | Favorit aus einer Suchzeile, einer Haltestelle oder dem Ziel einer Route setzen (Stern) | Heute geht es nur über Verlauf oder leere Kachel |
| A2 | Umbenennen (Label) | "Weyertal 119a" wird "Wohnung Oma" |
| A3 | Reihenfolge ändern (`sortIndex` wird schon gespeichert, aber nie verändert) | Wichtigstes nach vorn |
| A4 | Fehlerfall Haltestelle unbekannt (`NOT_FOUND`, API.md): Favorit nicht stumm scheitern lassen, sondern "Neu suchen" anbieten | Stop-IDs ändern sich nach Datenaktualisierung |
| A5 | Speicherfehler sichtbar machen statt `try?` zu verschlucken | Heute wirkt ein fehlgeschlagenes Speichern wie ein Erfolg |

Nicht dabei, bewusst: Rückweg-Knopf, Widget, Siri-Kurzbefehl, iCloud-Sync. Jedes davon ist ein eigenes Vorhaben (Familie braucht es noch nicht, Scope bleibt klein).

### Teil B: Tickets zeigen (Entscheidung Carlo, 24.11.)

Die Leute kaufen ihre Tickets woanders und zeigen sie im Fahrzeug in echt vor. Die App verkauft nichts, prüft nichts und rechnet keinen Tarif. Sie zeigt nur das Ticket schnell an.

- **Hinzufügen auf zwei Wegen:** aus der Wallet oder selbst (Foto/Screenshot, PDF, Datei).
- **Anzeigen:** ein Ticket groß und sofort, ohne Umweg. Meistens braucht man nur eins. Der Knopf erscheint nur, wenn eine Route offen ist.
- **Wechseln:** weitere Tickets liegen einen Wisch oder Tipp entfernt (Seitenpunkte oder kleine Liste), kein eigener Bildschirm.
- **Daten:** Ticketbild und Name liegen nur lokal und verschlüsselt (gleiche Verschlüsselung wie die Favoriten), nie im Backend, nie im Fallbericht, nie im Backup im Klartext.

Technische Annahme, die vor dem Bau geprüft wird:

Ergebnis der Wallet-Prüfung (24.11., Apple-Doku `PKPassLibrary.passes()`: "Your app only has access to certain passes according to its entitlements. PassKit doesn't return passes that your app can't access."): Die App kann fremde Pässe (Deutschlandticket der Bahn, Handyticket des Verbunds) **nicht** aus der Wallet lesen. Nicht am Gerät getestet, die Doku ist eindeutig. Folge: B1 geht über Foto, Bild und PDF (Fotos-Auswahl, Dateien); Fotografieren und Scannen mit der Kamera sowie ein `.pkpass`-Import (die App kann einen Pass nicht selbst darstellen) sind B3 und brauchen eigene Entscheidungen.

Stufen (jede einzeln freigebbar):

1. **B1 Hinzufügen per Foto, Bild oder PDF, Anzeigen eines Tickets**, Löschen. Kein Wallet.
2. **B2 Mehrere Tickets, Wechseln, Umbenennen** (z. B. "Deutschlandticket", "Tageskarte").
3. **B3 Wallet-Weg** (`.pkpass` importieren, sonst fotografieren oder scannen), erst nach der Prüfung oben.

Nicht dabei: Ticketkauf, Gültigkeitsprüfung, Tarif- und Preisanzeige, Kontrolle durch die App.

## 3. Umsetzung in Teilen

Zu viel für einen Durchlauf. Darum Scheiben, jede mit eigenem Test, Review und Freigabe:

| Scheibe | Inhalt | Agent |
|---|---|---|
| 1 | A5 Speicherfehler sichtbar, A4 unbekannte Haltestelle "Neu suchen" | `ios-architect` |
| 2 | A2 Umbenennen, A3 Reihenfolge | `ios-architect` |
| 3 | A1 Stern aus Suche, Haltestelle und Ziel | `ios-architect` |
| 4 | Prüfung Wallet-Zugriff (Doku und Gerät), dann B1 | `ios-architect` |
| 5 | B2, danach B3 falls die Prüfung es trägt | `ios-architect` |

Ablauf je Scheibe (nach `CLAUDE.md` und den Lehren aus dem Zwischenstopp-Feature):

0. **Auswirkungsprüfung vor dem Bau** (`code-reviewer`, nur lesen): Datenmodell, andere Nutzer der Daten, Fakes, Tests, Docs, Projektdatei. Auflagen kommen in diesen Plan, bevor Code entsteht.
1. **Test zuerst:** roter Test, dann Code. Gegenprobe: Regel entfernen, Test wird rot.
2. **Logik ins Modell:** Regeln in `TransitCore`/`PlaceStore`, nicht in Views. Jede Regel einmal.
3. **Tests laufen lassen:** `cd ios/TransitCore && swift test`, dann die App-Tests mit `xcodebuild test` und eigenem `-derivedDataPath`. Wenn `project.yml` sich ändert, vorher `cd ios && xcodegen generate`. Backend bleibt unberührt (`npm test` nur zur Sicherheit).
4. **Review:** `security-hig-reviewer` auf den Diff, Blocker beheben. Bei Scheibe 4 und 5 zusätzlich Datenschutz der Ticketdaten.
5. **Doku:** `docs/STATUS.md`, bei neuer Oberfläche `docs/DESIGN.md`.
6. **Commit** klein und thematisch, nie `git commit -a`, Tests vorher grün.
7. **Stopp** und Freigabe von Carlo abwarten, dann nächste Scheibe.

### Auflagen aus der Auswirkungsprüfung Scheibe 2 (24.11.)

1. Keine Schemaänderung, keine neuen Felder (sonst nur optional).
2. Gleicher Ort einmal über `routePoint` erkennen, im Store, im Verlauf-Filter und bei den Treffern. *Erledigt in Commit 1.*
3. Ersetzen mit `replacing:`, Platz bleibt, ein Speichern. *Erledigt in Commit 1.*
4. Verschieben ordnet nur die `sortIndex`-Werte der "Weiteren Favoriten" neu; Rollen-Kacheln bleiben.
5. Klartext-Test deckt auch das neue Label ab.
6. "Bearbeiten" erscheint auch bei nur weiteren Favoriten; jede Geste hat eine VoiceOver-Aktion; Eingabe trimmen, leer ablehnen, Länge begrenzen (60).
7. Drei Commits: Store-Regeln, Umbenennen (A2), Reihenfolge (A3); danach `DESIGN.md` Zeile 110 und `STATUS.md`.
8. Annahmen, bis Carlo anders entscheidet: Umbenennen nur für weitere Favoriten; A4 übernimmt den Namen des neuen Orts.

### Auflagen aus der Auswirkungsprüfung Scheibe 3 (24.11.)

1. Stern nur auf Suchtreffer, Nähe-Haltestellen und das gewählte Ziel (`flow.destination?.place`), nie auf GPS ("Mein Standort" hat keinen `TripEndpoint`). Kein Stern bei Zwischenstopps und beim Festlegen einer Kachel (auch A4).
2. "Ist Favorit" einmal im Modell (`favorite(at:)`, gleicher `routePoint`), nicht in den Views. Namen über `normalizedLabel`, ohne Namen kein Stern.
3. Rollen-Favoriten: Stern gefüllt, aber ohne Wirkung; Entfernen nur über Bearbeiten an der Kachel (Annahme, bis Carlo anders sagt).
4. Speicherfehler verdrängt kein Banner, das schon steht (Restzeit, Leerzustand der Routenauswahl).
5. Stern ist ein eigenes VoiceOver-Element (Label je Zustand, `.isSelected`), eigener Identifier `favoriteStar`, 44 pt mit `.contentShape`, Haptik, Reduce Motion beachten, nicht in `EndpointRow` einbauen (sonst auch auf Favoritenzeilen).
6. Commits: (1) Modell und Tests, (2) Stern in Suche und Nähe, (3) Stern an der offenen Route (Details rechts frei; Routenauswahl hat nur Platz neben der Zeit, Platz mit dem Ticket-Knopf aus Scheibe 4 gemeinsam festlegen).
7. Am Gerät prüfen: Stern neben der Gehzeit bei AX3, Sprung der Liste nach dem Stern, stabile Koordinaten für dieselbe Adresse aus Apple Karten.

### Auflagen aus der Auswirkungsprüfung Scheibe 4 / B1 (24.11.)

1. **Speicher:** verschlüsselte Datei in `Application Support/Tickets/<uuid>.ticket` (nicht SwiftData, nicht App Group), Inhalt `LocalSealer`-Chiffrat (Schlüssel `.coordinateKey`), `.atomic`, Dateischutz `.completeFileProtectionUntilFirstUserAuthentication` (AGENT.md 3.3.1), `isExcludedFromBackup` nach jedem Schreiben. Ersetzen: erst neues schreiben, dann altes löschen. Kein Datei-Zeitstempel (`createdAt` im Chiffrat), kein Speicherplatz abfragen (PrivacyInfo).
2. **Import:** Bild per ImageIO auf längste Seite 3000 px, JPEG 0,9 (entfernt EXIF/GPS); PDF unverändert, höchstens 10 MB, mindestens eine Seite, nicht verschlüsselt; roh über 20 MB ablehnen. Nur PhotosPicker und `fileImporter` (keine Berechtigung, keine Info.plist-Änderung). Kein QuickLook, keine temporäre Datei.
3. **Fehler:** neuer `TransitError.ticketUnreadable` (`CLIENT_TICKET_UNREADABLE`); ein unlesbares Ticket (z. B. Schlüsselwechsel) wird sichtbar und lässt sich löschen, nie eine leere Ansicht. Fehler in den Einstellungen direkt anzeigen (das Banner läge unter dem Sheet).
4. **Anzeige:** `fullScreenCover`, heller Grund nur auf dem Inhalt, Helligkeit über die Szene (`UIScreen.main` ist veraltet und Warnungen sind Fehler), `isIdleTimerDisabled`, zurücksetzen beim Schließen und bei inaktiver oder Hintergrund-App; Platzhalter statt Ticket, solange die App nicht aktiv ist (App-Umschalter). Entschlüsseln nicht auf dem Main Actor. Kein Teilen, kein Kopieren.
5. **Knopf:** nur mit Ticket und nur bei offener Route (Routenauswahl, Details, Navigation, Ankunft), Regel einmal im Modell (`offersTicket`). Reihenfolge in der Leiste: Ticket, Stern, Zeit. Ohne Ticket ausgeblendet (Annahme, bis Carlo anders sagt); Hinzufügen nur in den Einstellungen.
6. **Datenschutz:** Ticket nie in Fallbericht, Snapshot, Live Activity, Widget, Log, Backend. Rohwert-Test und Backup-Ausschluss-Test.
7. **Commits:** (1) TransitCore `TicketFile`, Import-Aufbereitung, Fehlercode, Tests; (2) App-Abhängigkeiten, Fakes, AppFlow-Regeln; (3) Einstellungen (Hinzufügen, Vorschau, Löschen); (4) Anzeige mit Helligkeit, Sperre, Maskierung; (5) Knopf an der Route, UITest mit `-fakeTicket`. Danach Review mit Fokus Ticket-Datenschutz, dann Doku (STATUS, DESIGN, `docs/index.html`).
8. **Am Gerät prüfen:** Leiste der Routenauswahl bei AX3, Helligkeit nach Kontrollzentrum und App-Wechsel, Textauswahl in `PDFView`.

Teil A (Scheiben 1 bis 3) ist freigegeben. Teil B beginnt mit der Prüfung in Scheibe 4.

### Prüfung der Workflows (24.11.)

- Agenten `backend-engineer`, `ios-architect`, `security-hig-reviewer`, `report-analyst` liegen in `.claude/agents/`, passend zur Tabelle in `CLAUDE.md`.
- `npm test` und `xcodegen generate` stimmen mit `backend/package.json` und `ios/project.yml` überein.
- Lücke: `CLAUDE.md` nennt nur "`xcodebuild test`" ohne Ziel und ohne `swift test` für TransitCore. Vorschlag: den Befehl dort ergänzen (kleine Änderung, nur mit Freigabe).
- Warnungen gelten als Fehler (`SWIFT_TREAT_WARNINGS_AS_ERRORS`): neuer Code muss ohne Warnung bauen.

## 4. Wo Fehler passieren können

| Risiko | Warum | Gegenmaßnahme |
|---|---|---|
| Datenschutz: Label oder Ort landet im Klartext | Neue Felder (Umbenennen) vergessen die Verschlüsselung | Label nur im versiegelten `TripEndpoint`, Test, der den Rohwert in der Datenbank prüft |
| Backend sieht Favoriten-Namen | "Zuhause" könnte in Anfrage oder Bericht rutschen | Anfragen nur mit Koordinaten oder Stop-ID (CLAUDE.md), vorhandener Test in `TripSnapshotTests` als Vorbild |
| Verlorene Favoriten durch Migration | Neue Felder am SwiftData-Modell | Neue Felder optional (wie `earlierMinutes`), Migration am Gerät mit altem Store testen |
| Doppelte Favoriten | Gleicher Ort über Stern und Kachel | `addFavorite` prüft schon auf gleichen Endpunkt; für A1 Test ergänzen |
| Rolle Zuhause doppelt belegt | Umsortieren und Belegen greifen ineinander | Rolle bleibt eindeutig, Test auf "ersetzt statt verdoppelt" |
| Veraltete Stop-ID | Datenaktualisierung bei Transitous | A4: Fehler abfangen, neu suchen anbieten |
| Stilles Scheitern beim Speichern | `try?` in `PlaceStore` | A5: Fehler als `TransitError` melden |
| Bedienung: Umsortieren per Drag kollidiert mit waagerechtem Scroll | Kacheln liegen in einem horizontalen Scroll | Umsortieren nur im Bearbeiten-Modus, am Gerät prüfen |
| Barrierefreiheit | Neue Aktionen ohne VoiceOver-Alternative | Jede Geste hat eine Accessibility-Aktion (wie "Entfernen" heute) |
| Ticketbild im Klartext oder im Bericht | Ticket enthält Name und Code, ist sensibel | Verschlüsselt speichern wie Favoriten, aus Fallbericht und Backup ausschließen, Test auf den Rohwert |
| Wallet-Zugriff geht gar nicht | `PKPassLibrary` zeigt fremde Pässe vermutlich nicht | Scheibe 4 prüft zuerst; Import per Datei oder Teilen als Ersatz |
| Ticket unlesbar beim Vorzeigen | Zu dunkel, Bild verzerrt oder gespiegelt | Aufhellen, Seitenverhältnis erhalten, am Gerät prüfen |
| Falscher Eindruck "gültig" | App zeigt nur ein Bild | Kein Gültigkeitshinweis, kein Haken, keine Prüfung |
| Bildschirm sperrt beim Vorzeigen | Kontrolle dauert | Display nicht sperren, solange das Ticket offen ist, danach zurücksetzen |
| Scope wächst | Rückweg, Widget, Sync wirken naheliegend | Liste "Nicht dabei" oben, Erweiterungen als eigenes Ticket |

## 5. Entscheidungen

Entschieden (Carlo, 24.11.):
- Teil A wie beschrieben.
- Tickets nur zeigen. Hinzufügen aus der Wallet oder selbst, meist ein Ticket, einfach wechseln. Gekauft wird woanders.
- **Wallet-Weg:** Teilen oder Datei, wenn die App fremde Pässe nicht lesen darf. Sonst bieten wir an, das Ticket zu fotografieren oder zu scannen (Kamera oder Foto, kein eigener Ticket-Leser).
- **Ticket-Knopf nur bei offener Route** (Routenauswahl, Details, Navigation). Nicht im Start und nicht in den Einstellungen. Grund: Mit offener Route spart der Knopf Schritte (Wallet suchen, Pass wählen). Ohne Route ist die Wallet selbst der kürzere Weg (Seitentaste doppelt drücken). Wir wollen nicht besser als die Wallet sein, nur näher an der Fahrt.

Offen:
1. Wo genau sitzt der Knopf in Routenauswahl, Details und Navigation? (Entwurf in Scheibe 4, mit Blick auf `docs/DESIGN.md`.)
2. Ergebnis der Wallet-Prüfung aus Scheibe 4.
