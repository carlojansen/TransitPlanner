# TransitPlanner – Projektregeln für Claude Code

Reaktiver Nahverkehrs- und Regio-Routenplaner: iOS-App (Swift 6 / SwiftUI) + Node.js-Backend (MOTIS 2 über Transitous).

## Verbindliche Dokumente (immer zuerst lesen)
- `docs/SPEZIFIKATION.md` – Was gebaut wird (Funktion, Architektur, Meilensteine).
- `docs/AGENT.md` – Wie gebaut wird (Security nach OWASP MASVS-L2, Apple HIG, 7-Punkte-Checkliste).
- `docs/API.md` – Vertrag zwischen Backend und App. Änderungen hier zuerst, dann Code.
- `docs/STATUS.md` – Stand der Meilensteine und offene Entscheidungen.
- `docs/DESIGN.md` – Freigegebenes Design aus Figma (Tokens, Schrift, Maße, Komponenten, Verhalten pro Screen).

## Agenten-Workflow
Die Subagents in `.claude/agents/` haben feste Rollen:

| Agent | Rolle | Wann |
|---|---|---|
| `backend-engineer` | Node.js/Express, MOTIS/Transitous, Tests | Meilenstein 1, API-Änderungen |
| `ios-architect` | Swift 6, SwiftUI, SwiftData, MapKit, WidgetKit, ActivityKit | Meilensteine 2–5 |
| `security-hig-reviewer` | Unabhängiges Review gegen AGENT.md, schreibt keinen Code | Nach jedem Modul, vor jeder Freigabe |

Ablauf pro Meilenstein:
1. Umsetzung durch den passenden Engineer-Agent.
2. Tests laufen lassen (`cd backend && npm test`, bzw. `xcodebuild test`).
3. `security-hig-reviewer` prüft den Diff. Blocker werden behoben, bevor weitergemacht wird.
4. `docs/STATUS.md` aktualisieren.
5. **Stopp und auf Freigabe von Carlo warten** (SPEZIFIKATION Abschnitt 8). Kein Meilenstein ohne Freigabe.

## Harte Regeln
- Keine Emojis in Code, Kommentaren, UI-Strings, Notifications. Nur SF Symbols.
- Backend erhält nur: Koordinaten oder Stop-IDs, Haltestellen-Suchtexte, Zeit (ISO-8601), Produktfilter. Keine Adressen, Kalendertitel, Geräte-IDs.
- Transitous-Nutzungsregeln einhalten: User-Agent mit Kontakt, sparsame Routing-Anfragen, Quellenangabe (https://transitous.org/sources/) sichtbar in der App, nicht kommerziell, Code vor breiter Nutzung als Open Source veröffentlichen.
- Keine Force-Unwraps (`!`), kein `try!`, keine `.linear`-Animationen.
- Alle Fehler als typisiertes `TransitError`; Codes siehe `docs/API.md`.
- Commits klein und thematisch; Tests müssen vor jedem Commit grün sein.

## Befehle
```bash
cd backend && npm test           # Unit-/API-Tests (Fake-MOTIS-Client, offline)
cd backend && npm run smoke      # Live-Test gegen Transitous (braucht .env, im macOS-Terminal)
cd backend && npm run dev        # Lokaler Server mit Auto-Reload
cd ios && xcodegen generate      # Xcode-Projekt aus project.yml erzeugen (ab Meilenstein 2)
```
