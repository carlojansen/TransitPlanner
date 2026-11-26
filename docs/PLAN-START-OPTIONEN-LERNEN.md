# Plan: Optionen am Start und Lernen aus Nutzungsdaten

Stand 26.11.2026, Entwurf. Nichts davon ist gebaut. Zwei getrennte Teile, jeder für sich freigebbar.

## Teil A: Zeit und Verkehrsmittel schon am Start

**Problem:** Zeit, Verkehrsmittel und Stufenfrei erscheinen nur in `PlanSheet`, und nur ohne Feldfokus (`if !focused`). Vom Start führt "Wohin?" in den Plan mit Tastatur (alles ausgeblendet), ein Tipp auf Favorit oder Haltestelle sucht sofort. Die Optionen erreicht man nur über Ergebnisse und Zurück.

**Lösung:** Eine Chip-Zeile im Start-Kopf unter "Wohin?": Zeit-Chip ("Jetzt") und Verkehrsmittel-Chip ("Alle"). Ein Tipp öffnet die jeweilige Auswahl, ohne zu suchen. Die gewählten Werte gelten für den nächsten Tipp auf Favorit oder Haltestelle. Abweichende Werte stehen im Chip ("Abfahrt 17:30", "Nur S-Bahn").

**Nebenbedingung:** `choose(...)` im Start setzt heute `customTime = nil` und `isArrivalTime = false` zurück. Das muss entfallen, sonst werden die Chip-Werte beim Tipp überschrieben. Nach einer Suche soll "Jetzt" wieder gelten (Entscheidung nötig, siehe unten).

### Schritte
0. Auswirkungsprüfung mit `code-reviewer` (nur lesen): `choose`, `set`, `modePills`, `timeRow`, Snapshot, Widgets, Previews, UI-Tests.
1. `timeRow` und `modePills` aus `PlanSheet` in eigene Views ziehen (eine Quelle für Start und Plan).
2. Chip-Zeile in `StartSheet`, Auswahl als kleines Sheet oder Menü.
3. `choose` im Start behält Zeit und Modi.
4. Tests (unten), `docs/STATUS.md`, Freigabe durch Carlo.

### Tests, die Problemstellen sichtbar machen
Bisher läuft nur dein Handy als Prüfer. Diese Tests decken die Zustände ab:
- **Zustandsmatrix (`AppFlowTests`):** Für jede Phase und jedes Ereignis steht fest, ob Zeit und Modi erhalten bleiben. Eine Tabelle als Test, nicht Einzelfälle. Fängt genau die Art Fehler, die du gefunden hast (Option nur nach Umweg erreichbar).
- **Erreichbarkeit:** Test, dass vom Start höchstens ein Tipp bis zur Zeit- und Modus-Auswahl nötig ist (UI-Test in `PlanFlowUITests`).
- **Wert bleibt:** Modus "Nur S-Bahn" am Start wählen, Favorit tippen, Anfrage enthält nur S-Bahn (Fake-Client prüft die Produktfilter).
- **Rücksprung:** Ergebnisse, Zurück, Start zeigt dieselben Modi, die Zeit steht wieder auf "Jetzt" (Entscheidung 1).
- **Dynamic Type AX3 und Dark Mode:** Preview und Screenshot-Test für die neue Zeile, weil sie im kleinen Detent (140 pt) nicht abgeschnitten werden darf.
- **Abstand Überschrift zu Pillen:** Layout-Test oder Screenshot-Vergleich, damit der Fehler von heute nicht zurückkommt.

### Auflagen aus der Auswirkungsprüfung (26.11., verbindlich)
1. **Zeit-Regel (entschieden):** Zeit springt beim Weg zurück zum Start (`.back`/`.reset` in den Start, Ankunft, Zurück) auf "Jetzt". Modi bleiben. Zusätzlich verwirft eine zentrale Stelle eine abgelaufene Zeit (`customTime < flow.now`). Der Chip zeigt das Datum, wenn die Zeit nicht heute liegt (`timeLabel` aus `PlanSheets.swift` übernehmen).
2. `choose` im Start setzt die Zeit nicht mehr zurück, Test `startTileSearchesFromCurrentLocationNow` bewusst umschreiben, nicht löschen. `ReminderFlowTests` bleiben grün (`openPendingReminder` setzt weiter zurück).
3. Zustandsmatrix über die Methoden (`choose`, `nextConnection`, `openPendingReminder`, `searchLater`, `send(.back/.reset/.editEndpoint/.editOptions)`), nicht über `next()`: Zeit, Ankunft und Modi vorher und nachher.
4. Test "Wert bleibt": S-Bahn wählen, Favorit tippen, `FakeRoutePlanner.recordedRequests.last` hat `modes == [.suburban]` plus Zeit.
5. Platz: Start-Kopf braucht schon ~116 pt, der kleinste Detent hat 140 pt. Chips in die Suchzeile oder bei `.peek` ausblenden, bei AX-Größen untereinander. Preview mit fester Höhe 140 pt.
6. Nur `timeRow` und `modePills` herausziehen (`StepFreeToggle` ist schon gemeinsam). `flow.now` statt `Date()`. Bezeichner `timeMode`, `timePicker`, `modePill.<raw>` unverändert, neu: `timeChip`, `modeChip`. VoiceOver "Zeit: Jetzt", 44 pt Tippfläche.
7. Erinnerungen: `modeFilter` bleibt der aktuelle Filter (Verhalten dokumentieren, nicht ändern).
8. `PreviewFlow` um `time` und `modes` erweitern. DESIGN.md und STATUS.md anpassen. Danach `xcodegen generate`.

## Teil B: Aus Nutzungsdaten lernen

**Ausgangslage:** Das Fall-Protokoll bleibt auf dem Gerät. Der Nutzer teilt es von Hand (TestFlight, Debug). Das Backend erhält nichts (`docs/API.md`, Abschnitt "Bericht"). Dadurch lernen wir nur von deinem Handy. Das ist eine bewusste Regel und müsste geändert werden, deshalb braucht Teil B deine ausdrückliche Freigabe und eine Anpassung von `API.md` und `AGENT.md` zuerst.

**Grundsätze, an denen jede Stufe gemessen wird:**
1. Opt-in, aus nach Voreinstellung, in den Einstellungen erklärt und mit einem Schalter jederzeit abstellbar.
2. Nur Zahlen und Ereignisarten, nie Namen, Adressen, Ticketdaten, Favoriten, Suchtexte, Geräte-IDs.
3. Das Gerät rundet und gröbt vor dem Senden (Zeit 5 Min., Ort ~1 km, wie heute in `CaseEvent`). Ein ungerundeter Wert kann nicht entstehen.
4. Keine Kennung, auch keine zufällige, die Ereignisse einem Gerät zuordnet. Dann sind Mengen auszählbar, Personen nicht verfolgbar.
5. Jede Stufe hat einen Server-Schalter (Kill-Switch) und eine Obergrenze pro Tag.

### Stufen (jede einzeln freigeben)
| Stufe | Inhalt | Risiko | Gate |
|---|---|---|---|
| 0 (jetzt) | Lokal, Teilen von Hand | keins | Bestand |
| 1 | Familie schickt den Bericht per Teilen-Menü an Carlo, Auswertung mit `report-analyst` | sehr klein | Bestand, nur Anleitung in den Einstellungen |
| 2 | Zähler ohne Ort: Absturz, Speicherdruck, Zahl verpasster Anschlüsse, Fußweg Apple gegen MOTIS | klein | Opt-in-Schalter, Endpunkt `POST /v1/telemetry` mit Schema-Prüfung (zod), Vorschau der Daten vor dem ersten Senden |
| 3 | Fälle mit grobem Ort (Halt, ~1 km) | mittel | Datenschutzerklärung, App-Privacy-Angaben angepasst, Löschfrist (30 Tage) |
| 4 | Aggregierte Auswertung, die in die App zurückfließt (zum Beispiel Fußweg-Faktor pro Region) | mittel | Erst bei genug Daten, Familiengröße reicht dafür kaum |

**Empfehlung:** Stufe 1 sofort (nur eine Anleitung), Stufe 2 danach. Stufe 3 und 4 nur, wenn die App über die Familie hinauswächst. Das passt zu "vorerst nur Familie, klein halten".

### Tests für Teil B
- Rohwert-Test: Der gesendete Body enthält nur erlaubte Schlüssel (Allowlist), keine Strings außer Ereignisart.
- Rundungs-Test: Zeit und Ort sind auf dem Gerät gerundet, bevor sie die Netzschicht erreichen.
- Opt-out-Test: Ausgeschaltet geht keine Anfrage raus (Fake-Client zählt Aufrufe).
- Backend: Anfrage mit unbekanntem Feld wird abgelehnt, Obergrenze pro Tag greift, Kill-Switch greift.

## Teil C: Speicher (aus dem Bericht)
Spitze 924 MB, ein Absturz mit Signal 9, zwei Beendigungen wegen Speicherdruck. Erst messen (Instruments, Allocations auf dem Gerät bei einer Fahrt), dann fixen. Kein Schätzen im Code.

## Entscheidungen für Carlo
1. Soll die Zeit nach einer Suche vom Start wieder auf "Jetzt" springen oder bleiben?
2. Dürfen Teil B, Stufe 2 und `API.md` / `AGENT.md` geändert werden (Opt-in-Telemetrie ans Backend)?
3. Reihenfolge: A zuerst, dann C, dann B Stufe 1 und 2?
