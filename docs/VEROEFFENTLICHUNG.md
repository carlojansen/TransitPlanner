# Veröffentlichung: Open Source und App Store

Ziel (Carlo, 2.11.2026): öffentlich, kostenlos, ohne Werbung, nicht kommerziell, Open Source (MIT).
Stand der Prüfung: 2.11.2026. Apple-Richtlinien nach dem Text auf developer.apple.com/app-store/review/guidelines/.

## 1. Was wird Open Source

**Alles unter MIT** (`LICENSE`): `backend/`, `ios/`, `docs/`, `scripts/`, `.claude/agents/`, `CLAUDE.md`.
MIT passt zu den Transitous-Regeln und zum App Store (GPL wäre mit den Store-Bedingungen ein Problem).
Abhängigkeiten: iOS ohne Fremdpakete; Backend nur permissive Lizenzen (MIT, ISC, BSD, Apache-2.0), `@mapbox/polyline` ist BSD-3-Clause.

**Nicht ins Repo und nie committen:** `backend/.env` (API-Token), der Offline-Backup-Schlüssel zum Backup-Pin,
Signing-Zertifikate und Profile, Geräte-Screenshots mit echten Adressen (`docs/refs/` ist ignoriert), Serverzugang.

**Befund der Prüfung:** Keine Token, Schlüssel oder privaten Daten in Code oder Historie (67 Commits, ein Autor mit
GitHub-noreply-Adresse). Eine Historie-Bereinigung ist nicht nötig. Öffentlich sind schon jetzt: der Hetzner-Hostname
(enthält die Server-IP, `BackendConfig.production`), die beiden Pins (öffentliche Information), Team-ID in `project.yml`.
Mit eigener Domain (Punkt 2c) wird der IP-Bezug hinfällig.

Noch zu entscheiden: `docs/drawings/` (ungetrackt, Maßzeichnung) mitveröffentlichen oder löschen.

## 2. Weiche: Backend behalten (B) oder direkt zu Transitous (A)

Entscheidung hängt an der Antwort von Transitous (Matrix `#transitous:matrix.spline.de`). Bis dahin bleibt es offen.

| Punkt | B: eigenes Backend | A: App ruft Transitous direkt |
|---|---|---|
| 2a Zugang / App Attest | nötig, Server prüft | entfällt (kein Server) |
| 2b Last | eine IP, Drossel 60/min | verteilt auf Nutzer, Abstimmung bleibt |
| 2c Domain, Pins | nötig | entfällt |
| 2d Datenschutz | nötig | nötig, plus "Transitous sieht die Nutzer-IP"; Rundung der Koordinaten macht die App |

Bei A wandern etwa 600 bis 800 Zeilen aus `backend/` (Mapper, Service, Upstream-Gate) nach `TransitCore`; die
Backend-Tests liefern die Fixtures. App Attest ohne eigenen Server schützt nichts, deshalb nicht vorab bauen.
Developer-Account ist vorhanden (Stand 2.11.); TestFlight ist für Demos nutzbar.

Transitous nimmt keine "vibecodeten" Apps in die Liste. Deshalb steht die KI-Unterstützung offen im README,
dazu Tests, Review und Architektur-Doku.

## 2b. Blocker vor einer öffentlichen Version (gilt für B, Punkte b und d auch für A)

Das ist keine Aufräumarbeit, sondern Architektur. Reihenfolge nach Abhängigkeit:

**a) Zugang ohne gemeinsames Token.** Die App liest ein Bearer-Token aus der Keychain, das der Nutzer von Hand
einträgt (`enterKey`-Ablauf). Für Fremde geht das nicht, und ein fest eingebautes Token wäre extrahierbar.
Optionen: **App Attest** (bereits in STATUS und AGENT.md vorgesehen, belegt die echte App, braucht Server-Prüfung)
oder offen mit Limits pro IP (einfach, aber das Backend wird zum kostenlosen Proxy). Empfehlung: App Attest.
Das Token bleibt nur für Entwicklung und Smoke-Test.

**b) Last auf Transitous.** Alle Nutzer laufen über eine Server-IP und eine Drossel (60/min, davon 30 Routensuchen).
Ab etwa 20 gleichzeitigen Nutzern gibt es 429 für alle. Zusätzlich liegt Live-Polling (alle 30–60 s) weit über der
Abstimmungsschwelle von 720 Anfragen/24 h. Vorher: Transitous kontaktieren (Entwurf siehe Chat/STATUS), Polling
reduzieren (nur bei aktiver Fahrt, längere Takte) und prüfen, ob eine eigene MOTIS-Instanz auf dem Server reicht
(RAM-Bedarf für Deutschland-Daten ist ungeprüft; Umstellung nur über `MOTIS_BASE_URL`).

**c) Eigene Domain.** Host, Caddyfile, Pins (Primär plus Offline-Backup) und `BackendConfig` hängen am rDNS-Namen.
Eine Domain entkoppelt von der IP. Pins danach neu erzeugen (`backend/deploy/spki-hash.sh`). Pinning mit Leaf-Pins
bedeutet: Ein Zertifikatswechsel ohne Backup-Pin sperrt alle installierten Apps bis zum Update. Bei öffentlicher
Nutzung ist das ein echtes Risiko und sollte neu bewertet werden (Pinning auf CA/Intermediate oder weglassen).

**d) Datenschutzerklärung und Support-Seite.** Angelegt als `docs/index.html` mit `docs/CNAME` (`transitplaner.de`), Stand 2.11. Noch offen: GitHub Pages aktivieren (Branch main, Ordner /docs), DNS beim Registrar, Weiterleitung `kontakt@transitplaner.de`, Impressum prüfen (Anschrift ist personenbezogen, bei rein privatem Angebot ggf. nicht nötig), Text bei Weg A anpassen (Transitous sieht dann die Nutzer-IP). Pflicht (5.1.1(i), 1.5), in App Store Connect und in der App
erreichbar. Inhalt: gerundete Koordinaten und Suchtexte gehen ans Backend, keine Konten, Log-Filter in Caddy
(IP, Query und Auth-Header werden nicht protokolliert), Speicherdauer, Weitergabe an Transitous (Dritter, 5.1.2(i)),
Kontakt. Die Seite kann im Repo liegen (GitHub Pages).

## 3. Apple-Richtlinien: Abgleich

| Regel | Stand |
|---|---|
| 5.1.1(i) Datenschutzerklärung verlinkt | offen (2d) |
| 5.1.1(ii/iii) Zweckangabe, Datensparsamkeit | erfüllt: Text erklärt gerundete Koordinate; nur "Beim Verwenden", kein "Immer" |
| 5.1.1(v) Konto | erfüllt: kein Login. Entfällt der Token-Schritt (2a), gibt es auch keine Eingabemaske mehr |
| 5.1.2 Weitergabe, Profilbildung | Transitous in der Erklärung nennen; keine Profile, kein Tracking, ATT nicht nötig |
| 5.1.5 / 2.5.4 Standort im Hintergrund | zulässig, weil nur ab der Gehphase einer vom Nutzer gestarteten Fahrt (`CLBackgroundActivitySession`); im Review-Hinweis erklären |
| 2.5.16, 4.5.4 Widget, Live Activity, Benachrichtigungen | zulässig: nur eigene Fahrten, keine Werbung, Push nicht erforderlich |
| 4.2 Mindestfunktion | erfüllt: eigene Routing- und Navigationslogik, kein Web-Wrapper |
| 2.1 Vollständigkeit, Backend live | Server muss im Review laufen; Hinweise für den Reviewer (Testablauf, Live Activity) schreiben |
| 2.3.7 Name | max. 30 Zeichen, eindeutig: "TransitPlanner" ist generisch, Kollision im Store prüfen |
| 2.3.10, 4.1, 5.2.5 Marken, Nachahmung | keine fremden Namen/Icons in Metadaten; eigenes Icon; kein Apple-Maps-Nachbau |
| 5.2.2 Drittdienste und Daten | Nachweis bereithalten: Transitous-Quellenliste (Datenlizenzen der Verkehrsbetriebe), Quellenangabe in der App vorhanden, OSM-Nennung ergänzen, falls noch offen (STATUS) |
| 3.1.1 Spenden | falls je gewünscht, nur per In-App-Kauf (Trinkgeld); sonst nichts nötig |
| 3.2.2(v) Regionen sperren | nicht sperren; Abdeckung (Deutschland, Transitous-Daten) in der Beschreibung nennen |
| Privacy Manifest, Labels | `PrivacyInfo.xcprivacy` vorhanden (präziser Standort, nicht verknüpft, kein Tracking); Store-Labels gleich ausfüllen |

Außerdem: Apple Developer Program (99 EUR/Jahr) ist für die Veröffentlichung nötig, auch bei kostenloser App.
Nicht geprüft: Developer Program License Agreement (Text liegt nicht öffentlich im Review-Dokument) und
altersgerechte Einstufung (ehrlich ausfüllen, 2.3.6).

## 4. Reihenfolge

1. Repo vorbereitet (Stand 2.11.): Verlauf ohne Geheimnisse, `LICENSE`, README mit KI-Hinweis und Status.
   Noch offen: Commit der Änderungen, `docs/drawings/` entscheiden, Repo auf GitHub öffentlich stellen
   (Carlo), dann Transitous mit den ehrlichen Zahlen kontaktieren und auf die Antwort warten.
2. Danach je nach Weiche: B = Domain, Pins, App Attest, Datenschutzseite; A = Umbau nach TransitCore,
   Datenschutzseite, Polling-Takt (mindestens 60 s) und Lastgrenzen.
3. TestFlight mit wenigen Fremden, dann Review.
