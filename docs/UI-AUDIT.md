# UI-Audit (Stand 30.10.2026)

Grundlage: Code-Durchsicht von `PlanSheets`, `TripDetailsSheet`, `NavigationViews`, `MapScreen`, `Components` (161 Padding/Frame-Stellen).
Noch nicht geprüft: gerenderte Previews, Tap-Zählung am laufenden Simulator (AXe), Hell/Dunkel, AX3. Diese Punkte sind unten als "offen" markiert.

## 1. Margins, Paddings, Raster

| Befund | Stelle | Vorschlag |
|---|---|---|
| Seitenrand überall 16 pt | alle Sheets | Soll bleibt 16. Kein Handlungsbedarf. |
| Oberkante uneinheitlich: 20 (Start), 12 (Routen-Kopf), 8 (Planen, Details), 16 (Navigation) | `PlanSheets` 38, 734, 349; `TripDetailsSheet` 55; `NavigationViews` 201, 242 | Ein Wert für Sheet-Kopf: 16. |
| Werte neben dem 4er-Raster: 5, 6, 7, 10 | Modus-Chips (`PlanSheets` 443-452), Hint-Zeilen | 4 bzw. 8 nehmen; Chip-Innenabstand 8. |
| Sichtbare Höhe 34 pt mit 5 pt Zusatz, damit Tippfläche 44 | Chips, Jetzt-Knopf (`PlanSheets` 159-164, 448-452) | Funktioniert, aber Hack. Besser: `.frame(minHeight: 44)` mit `contentShape`, sichtbare Kapsel 32. |
| Tippfläche unter 44 pt | `compareButton` minHeight 40 (`NavigationViews` 355) | 44. |
| Zeilenhöhe 28 | `WalkStepRow`, Favoriten-Zeile (nicht tippbar bzw. in Button) | Prüfen, ob Zeile tippbar ist; sonst ok. |
| Schiene/Zeitspalte fest 56 pt, 12 pt Schiene | `TripDetailsSheet` 147, 179 | Ok, bei AX bereits umgebrochen. |

## 2. Buttons: Rolle, Platz, Stil

| Button | Ist | Rolle | Soll |
|---|---|---|---|
| Verbindungen suchen | `PrimaryButton`, unten im Planen-Sheet | primär | bleibt |
| Starten | `PrimaryButton` in Hero Card, Details (unten), AX unten in Routen | primär | bleibt; Platz unten (Daumenzone) |
| Details (Hero Card) | `SecondaryButton` neben Starten | sekundär, doppelt | Entscheidung A |
| Erinnern | `SecondaryButton` unten in Details | sekundär | bleibt |
| Zurück (Routen) | eigenes Chevron-Symbol im Kopf | Navigation | Entscheidung B |
| Verbindungen (Details) | Text-Button mit Chevron im Kopf | Navigation | Entscheidung B |
| Einstellungen | Zahnrad 44x44, oben rechts | sekundär | bleibt, nur im Start/Planen |
| Tauschen | Pfeil-Symbol 44x44 | sekundär | bleibt |
| Jetzt (Zeit) | Kapsel plus x-Symbol | sekundär | bleibt |
| Beenden (Navigation) | Text-Button | destruktiv | `role: .destructive` und Bestätigung prüfen (offen) |
| Nächste Verbindung / Alternativen | Zeilen-Button in Jetzt-Karte | sekundär | bleibt |
| Entfernen (Favorit/Zuletzt) | Kontextmenü `.destructive` | destruktiv | ok; Swipe-Aktion zusätzlich prüfen |

## 3. Lange Wegbeschreibungen

Schon vorhanden und gut: Zwischenhalte als `DisclosureGroup` (zu), Wegbeschreibung pro Fußweg als Button "Wegbeschreibung (n)" (zu), Schritte gruppiert/verdichtet.

Lücken:
- Route mit 4 Fahrzeugen und 3 Umstiegen ist als Ganzes lang (siehe Preview "Bonn → Flughafen"): jede Etappe zeigt Abfahrt, Linie, Ankunft, dazu Umstiegszeilen. Der Überblick geht verloren.
- Kurze Umstiege (unter 2 Min., gleiche Haltestelle) brauchen keine eigene Zeile mit Wegbeschreibung.
- Meldungen des Betreibers stehen unterhalb der Zeitleiste und werden bei langer Route nicht gesehen.

Vorschlag (Stufen der Offenlegung):
1. Liste: Zeit, Dauer, Umstiege, Linien (schon so).
2. Details: pro Etappe eine Zeile "Linie, Richtung, von-bis, Gleis". Umstieg als eine Zeile "Umstieg 4 Min. (Gleis 2 → 5)".
3. Tippen auf Etappe: Zwischenhalte. Tippen auf Umstieg: Wegbeschreibung. Beides standardmäßig zu (Rest ist es schon).
4. Störungen/Gleiswechsel als Hinweis direkt über der betroffenen Etappe plus Kurzhinweis oben in der Detailansicht.

## 4. Eigenbau statt Standard (HIG)

- Sheet-Köpfe sind eigene `safeAreaInset`-Leisten (Routen, Details). HIG: Navigationsleiste im Sheet mit `NavigationStack` und `toolbar` (Zurück, Titel, Aktion). Gewinn: Zurück-Geste, Dynamic Type, Voice Over ohne Handarbeit. Risiko: Detent-Verhalten im Karten-Sheet prüfen.
- Karten (`ContentCard`) statt `List` mit `insetGrouped`: gewollt aus Figma. Entscheidung C.
- Ladezustand mit `.redacted`: ok.
- Hero Card: ganze Karte tippbar plus zwei Knöpfe. Ein Ziel pro Aktion wäre einfacher.

## 5. Entscheidungen (Carlo, 31.10.: A ja, B ja, C bleibt)

- A: Hero Card: "Details"-Knopf entfernen (Karte ist tippbar, VoiceOver-Hinweis vorhanden) oder behalten?
- B: Kopf der Routen- und Detailansicht auf `NavigationStack` mit Toolbar umstellen?
- C: Karten-Optik (weiße Karten, eigene Trenner) behalten oder auf `List` `insetGrouped` umstellen?

## 6. Messung am Simulator (iPhone 18 Pro, frischer Build)

- Start-Sheet: Einstellungen-Knopf misst 42x42 pt, Suchfeld "Wohin?" 42 pt hoch. Beides unter 44 pt, obwohl der Code 44 fordert (vermutlich Rahmen im Glas-Container). Nachmessen und korrigieren.
- Geklärt: "Wohin?" öffnet die Suche; nur der AXe-Tap bewirkt auf dem Simulator nichts (XCUITest auf iOS 27 grün).
- Geklärt: 42 pt ist die Systemdarstellung der kleinen Detents (iOS 26.5 und 27); im großen Detent 44 pt mit 16 pt Rand. Kein Codefehler.
- Unterer Teil des Start-Sheets ist bei leeren Favoriten fast leer (Zuhause festlegen als einzige Zeile).

## 7. Offen im Audit

- Tap-Zählung bis Verbindung, Abfahrt, Störung am Simulator (AXe `describe-ui`, Frames).
- Visuelle Prüfung: Hell/Dunkel, AX3, kleines iPhone. `RenderPreview` braucht einmalige Freigabe (Xcode-MCP: `XcodeOpenWorkspace`); alternativ Canvas in Xcode.
- Review durch `security-hig-reviewer` auf dem Preview-Diff.
