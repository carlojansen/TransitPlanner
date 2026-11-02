# TransitPlanner

Nahverkehrs- und Regio-Routenplaner für iOS (Swift 6, SwiftUI) mit schlankem Node.js-Backend.
Kostenlos, ohne Werbung, ohne Tracking, nicht kommerziell. Lizenz: MIT.

Fahrplandaten: [Transitous](https://transitous.org/sources/) (MOTIS 2), Kartendaten: © OpenStreetMap-Mitwirkende.

```
backend/   Routing-Proxy für Transitous (Express 5, vitest). Erhält nur Koordinaten, Haltestellen, Zeiten.
ios/       App, Widgets, Live Activity; Logik in ios/TransitCore (Swift Package). Projekt per XcodeGen.
docs/      API-Vertrag, Spezifikation, Design, Sicherheits- und Veröffentlichungsplan
```

## Entwickeln
```bash
cd backend && cp .env.example .env   # USER_AGENT und API_TOKEN eintragen
npm ci && npm test                   # offline, Fake-MOTIS-Client
npm run smoke                        # Live-Test gegen Transitous
cd ../ios && xcodegen generate       # danach TransitPlanner.xcodeproj öffnen
```

## Status
Privates Studentenprojekt, noch nicht im App Store. Die Nutzung der Fahrplandaten wird mit dem
Transitous-Team abgestimmt (Regeln: https://transitous.org/). Bis dahin keine öffentliche Version.

## Wie das Projekt entsteht
Der Code entsteht mit Unterstützung von Claude Code (KI). Verantwortlich ist Carlo Jansen: Spezifikation und
Freigabe jedes Meilensteins, Tests (`npm test`, Xcode-Tests), unabhängiges Review gegen die Sicherheitsvorgaben
(`docs/AGENT.md`) und die Architektur in `docs/` sind nachvollziehbar dokumentiert.

## Mitmachen
Fehler und Ideen als GitHub-Issue. Pull Requests willkommen; Tests müssen grün sein (`cd backend && npm test`).

Hinweise zur Veröffentlichung: `docs/VEROEFFENTLICHUNG.md`.
