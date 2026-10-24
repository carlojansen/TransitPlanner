# API-Vertrag Backend <-> App (v0.2, Meilenstein 1)

Basis-URL: `https://<deine-domain>` (TLS 1.3, SPKI-gepinnt). Alle `/api/*`-Endpunkte verlangen
`Authorization: Bearer <API_TOKEN>` (zusätzlich gelten die Tokens aus `API_TOKENS`, kommagetrennt, für Rotation) und antworten mit `Cache-Control: no-store`.

Datenquelle: MOTIS 2 über [Transitous](https://transitous.org) (offene Fahrplan- und Echtzeitdaten, u. a. DELFI).
Jede erfolgreiche `/api`-Antwort (200) enthält `attribution {text, links:[{label, url}]}` (Transitous-Quellen und OpenStreetMap); die App muss Text und Links sichtbar anzeigen (Transitous-Nutzungsregel, OSM-Lizenz).

## Zero-Knowledge-Regeln
- Die App sendet nur Koordinaten, Stop-IDs, Haltestellen-Suchtexte, Zeiten und Filter. Unbekannte Felder werden mit `400` abgelehnt.
- **Adressen verlassen das Gerät nie als Text.** Die App hat einen Pflichtschalter mit zwei Suchmodi. Im Modus „Adresse“ läuft die Suche lokal per `MKLocalSearch` (mit expliziter Region aus dem GPS-Fix), ans Backend geht dann nur die gewählte Koordinate. Ein Suchtext geht nur an `GET /api/locations?query=`, wenn der Nutzer ausdrücklich den Modus „Haltestelle“ gewählt hat. Es gibt keine automatische Erkennung, die einen Text selbst ans Backend schickt. Wer im Haltestellen-Modus eine Adresse eintippt, sendet sie bewusst als Suchtext (ohne Standort); die UI weist darauf hin.
- Haltestellen-Textsuchen gehen **ohne** Standort an Transitous; die Nähe-Sortierung passiert im Backend. Der Cache speichert nur einen Hash des Suchtexts.
- Umkreissuchen: die App rundet auf 3 Nachkommastellen (~110 m), das Backend rundet zusätzlich (Defense in Depth).
- **Routing mit Koordinaten:** Start/Ziel gehen auf 4 Nachkommastellen (~11 m) gerundet an Transitous. Das ist genau genug für den Fußweg, verrät aber die ungefähre Lage (z. B. die Straße der Wohnung). Wer das vermeiden will, wählt in der App eine Haltestelle als Start.

---

## `GET /healthz`
Ohne Auth. `200 {"status":"ok"}`

## `GET /api/locations`
| Parameter | Typ | Pflicht | Hinweis |
|---|---|---|---|
| `query` | String, 2–80 Zeichen | eins von beiden | nur Haltestellensuche |
| `lat`, `lon` | Dezimalzahl (kein Exponent/Hex) | eins von beiden | nur gemeinsam, im Bediengebiet; ohne `query` = Umkreis 500 m |

Antwort `200`:
```json
{ "places": [ { "kind": "stop", "id": "de-DELFI_de:05111:18235", "name": "Düsseldorf Hbf",
                "latitude": 51.21996, "longitude": 6.79432,
                "modes": ["tram","regional"], "area": "Düsseldorf", "distanceMeters": 180 } ],
  "attribution": { "text": "...", "links": [ { "label": "Transitous-Datenquellen", "url": "https://transitous.org/sources/" },
                                              { "label": "OpenStreetMap", "url": "https://www.openstreetmap.org/copyright" } ] } }
```
Es werden nur Haltestellen geliefert. `modes`, `area`, `distanceMeters` optional.

## `POST /api/routes`
```json
{
  "origin":      { "type": "coordinate", "latitude": 51.2201, "longitude": 6.7905 },
  "destination": { "type": "stop", "id": "de-DELFI_de:05315:11201" },
  "targetTime":  "2026-10-24T08:15:00+02:00",
  "isArrivalTime": false,
  "onlyNahverkehr": true,
  "results": 4
}
```
| Feld | Standard | Regeln |
|---|---|---|
| `origin`, `destination` | – | `{type:"stop", id}` (opake Stop-ID aus `/api/locations`, max. 160 Zeichen, ohne Komma/Leerzeichen) oder `{type:"coordinate", latitude, longitude}` im Bediengebiet (DE + Nachbarn) |
| `targetTime` | jetzt | ISO-8601 **mit Offset**, -6 h bis +60 Tage |
| `isArrivalTime` | `false` | `true` = Ankunft spätestens |
| `onlyNahverkehr` | `true` | nur Tram, U-/S-Bahn, Regionalzug, Bus, Fähre, Seil-/Schwebebahnen; Fernverkehr wird zusätzlich serverseitig herausgefiltert |
| `results` | `4` | 1–6 |
| `laterThan` / `earlierThan` | – | Paging mit `laterRef`/`earlierRef` der vorherigen Antwort. **Alle übrigen Felder unverändert mitschicken** (MOTIS-Regel). Schließen sich gegenseitig aus. |

Rate-Limit: eigenes, **globales** Limit für Routensuchen (Standard 30/min für alle Clients zusammen), weil Routing für Transitous teuer ist. Davor greift ein Limit pro IP (Standard 8/min); abgewiesene Anfragen verbrauchen das globale Limit nicht.

**Suche in der App:** Die Haltestellensuche wird entprellt (mindestens 300 ms nach der letzten Eingabe, ab 2 Zeichen, oder sofort bei Return). Bei `RATE_LIMITED` zeigt die App ein Inline-Banner statt Dialog. Es werden keine `RateLimit-*`-Header gesendet, nur `Retry-After`.

**Rate-Limits (alle `429 RATE_LIMITED` mit `Retry-After`)**: allgemein 60/min pro IP für alle `/api/*`; zusätzlich pro IP `/api/routes` 8/min, `/api/locations` 20/min, `/api/refresh` 12/min; global `/api/routes` 30/min. Konfigurierbar über `.env` (`RATE_LIMIT_*`).

Antwort `200`:
```json
{
  "journeys": [ Journey, ... ],
  "earlierRef": "cursor", "laterRef": "cursor",
  "walkOnly": false,
  "removedLongDistance": 0,
  "fetchedAt": "2026-10-24T06:01:02.000Z",
  "attribution": { ... }
}
```
Alle Verbindungen enthalten Polylines (auch Fußwege), sofern Transitous sie liefert (`hasPolylines`).

- `walkOnly: true`: Start und Ziel liegen so nah (Fußweg bis ca. 5 min), dass MOTIS gar kein ÖV-Routing rechnet. Die einzige Journey ist dann ein reiner Fußweg (`modes: []`), Paging-Referenzen sind `null`.
- `removedLongDistance`: Anzahl der Verbindungen, die der Nahverkehrsfilter nachträglich verworfen hat (Feeds, die Fernverkehr als Regionalzug/Bus kodieren). Ist sie > 0, können Alternativen fehlen; die App kann „spätere Verbindungen“ anbieten.

### Journey
```json
{
  "refreshToken": "opaque (Base64)",
  "departure": "2026-10-24T06:00:00Z",
  "arrival":   "2026-10-24T06:42:00Z",
  "durationSeconds": 2520,
  "transfers": 0,
  "modes": ["regional"],
  "cancelled": false,
  "realtime": true,
  "hasPolylines": true,
  "legs": [ Leg, ... ],
  "remarks": [ Remark, ... ]
}
```
`remarks` auf Journey-Ebene = alle Meldungen der Fahrzeug-Abschnitte, dedupliziert.

### Leg
Gemeinsame Felder: `index`, `mode`, `origin`, `destination` (Place), `departure`, `plannedDeparture`,
`departureDelaySeconds`, `arrival`, `plannedArrival`, `arrivalDelaySeconds`, `durationSeconds`,
`realtime` (Bool: Echtzeitdaten vorhanden), `cancelled`, `polyline`.

`mode`: `walk` | `tram` | `bus` | `subway` | `suburban` | `regional` | `regionalExpress` | `ferry` | `funicular` | `aerialLift` | `onDemand` | `airplane` | `other` | `national` | `nationalExpress` | `unknown`
(`onDemand`, `airplane`, `national*` kommen nur ohne Nahverkehrsfilter vor.)

Delay-Felder sind `null`, wenn keine Echtzeitdaten vorliegen (nicht `0`).

Fußweg (`mode = "walk"`): `isTransfer` (`true` für jeden Fußweg zwischen zwei Fahrzeugen), `distanceMeters`,
`durationSource: "motis-osm"` (Fußgänger-Routing auf OSM; die App ersetzt die Dauer durch `MKDirections` x `WalkingPaceFactor`).

Fahrzeug: `line {name, productName, fahrtNr, operator, color, textColor}` (Farben als `#RRGGBB` oder `null`),
`direction`, `tripId`, `departurePlatform`, `plannedDeparturePlatform`, `arrivalPlatform`, `plannedArrivalPlatform`,
`platformChanged` (Bool, löst `.warning`-Haptik aus), `loadFactor` (derzeit immer `null`, Transitous liefert keine Auslastung),
`stopovers [Stopover]`, `remarks [Remark]`.

`polyline`: `{type:"LineString", coordinates:[[lon,lat],...]}` oder `null`.

### Place
`{ "kind": "stop"|"coordinate", "id": String?, "name": String?, "latitude": Double?, "longitude": Double?, "modes": [String]? }`
Koordinaten-Endpunkte haben `id` und `name` = `null`; die App kennt den Namen lokal.

### Stopover
```json
{ "stop": Place, "arrival": "...", "plannedArrival": "...", "arrivalDelaySeconds": 60,
  "departure": "...", "plannedDeparture": "...", "departureDelaySeconds": 60,
  "platform": "9", "plannedPlatform": "10", "cancelled": false }
```

### Remark
`{ "type": "hint" | "warning", "code": String?, "summary": String?, "text": String }`
(`warning` bei Schweregrad WARNING/SEVERE der GTFS-RT-Meldung)

## `POST /api/refresh`
```json
{ "refreshToken": "opaque", "polylines": false }
```
Antwort `200 { "journey": Journey, "fetchedAt": "...", "attribution": {...} }`.
Ohne `polylines: true` sind alle `polyline`-Felder `null` (spart Datenvolumen beim Live-Polling).
Ungültiger/abgelaufener Token oder nicht mehr rekonstruierbare Fahrt: `410 REFRESH_EXPIRED`.
Ein echter Ausfall (GTFS-RT) kommt dagegen als `200` mit `cancelled: true`.

---

## Fehler
Immer `{"error": {"code": "...", "message": "...", "details": [...]?, "retryAfterSeconds": n?}}`.
`details` enthält nur Feldpfade, nie Eingabewerte; bei unbekannten Feldern den festen Text `unknown_field` statt des Feldnamens. Fehlerhafte Requests (falscher Content-Type/Charset, zu großer oder ungültiger Body) ergeben ebenfalls `INVALID_REQUEST` (400).

| Code | HTTP | Bedeutung für die App |
|---|---|---|
| `INVALID_REQUEST` | 400 | Programmierfehler in der App oder von MOTIS fachlich abgelehnt, loggen |
| `UNAUTHORIZED` | 401 | Token falsch/abgelaufen |
| `NOT_FOUND` | 404 | Ressource unbekannt; bei `/api/routes`: Stop-ID unbekannt (z. B. nach Datenaktualisierung), Favorit neu suchen |
| `NO_CONNECTIONS` | 404 | ruhiges Inline-Banner „Keine Verbindung gefunden“ |
| `REFRESH_EXPIRED` | 410 | Route neu suchen, Live Activity aktualisieren |
| `RATE_LIMITED` | 429 | `Retry-After` beachten; die App zeigt ein Inline-Banner |
| `UPSTREAM_UNAVAILABLE` | 502 | Transitous nicht erreichbar/gedrosselt/gesperrt oder Backend-Warteschlange voll, Cache zeigen, `Retry-After` beachten |
| `UPSTREAM_TIMEOUT` | 504 | wie oben |
| `INTERNAL` | 500 | generisch |

Swift-Spiegel (Meilenstein 2): `enum TransitError: String, LocalizedError, Codable` mit exakt diesen Rohwerten.
