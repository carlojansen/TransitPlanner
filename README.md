# TransitPlanner

Reaktiver Nahverkehrs- und Regio-Routenplaner für iOS mit eigenem Node.js-Backend. Fahrplandaten: [Transitous](https://transitous.org/sources/) (MOTIS 2, offene Daten).

```
TransitPlanner/
├── CLAUDE.md                 Projektregeln + Agenten-Workflow für Claude Code
├── .claude/agents/           backend-engineer, ios-architect, security-hig-reviewer
├── docs/
│   ├── SPEZIFIKATION.md      Was gebaut wird
│   ├── AGENT.md              Security- & HIG-Mandat
│   ├── API.md                Vertrag Backend <-> App
│   └── STATUS.md             Stand, Entscheidungen, Risiken
├── backend/                  Meilenstein 1 (Node 22, Express 5)
│   ├── src/                  app, routes, services, lib, middleware
│   ├── test/                 vitest + supertest, offline mit Fake-DB-Client
│   ├── scripts/smoke.js      Live-Test gegen Transitous
│   └── deploy/               Caddyfile (TLS 1.3), systemd-Unit, SPKI-Pin-Skript
├── ios/                      ab Meilenstein 2 (XcodeGen, Swift 6)
└── scripts/setup-mac.sh      installiert Tools und richtet das Backend ein
```

## Start
```bash
cd ~/Dev/TransitPlanner
./scripts/setup-mac.sh
cd backend && npm run smoke
```

## Weiterarbeiten mit Claude Code
```bash
cd ~/Dev/TransitPlanner && claude
> Meilenstein 1 ist freigegeben. Starte Meilenstein 2 mit dem ios-architect und lass danach den security-hig-reviewer prüfen.
```
