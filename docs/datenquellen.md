# Datenquellen: Aufzüge, Fahrtreppen, Störungen

Stand: 3.11.2026. Kriterium von Carlo: nur relevante Stationen, nur einbauen, wenn Abdeckung und Pflege lückenlos sind.
Schwelle laut Prüfregel: unter 90 % Abdeckung gilt "nicht nutzen". "Unklar" heißt: nicht belegt, keine Vermutung.

## Bestand im Projekt

- MOTIS liefert Meldungen als `alerts` (in der API als `remarks`) und Wegschritte mit `elevator`/`stairs`.
- Das Feld `wheelchairAccessible` der Fahrzeuge ist unzuverlässig (STATUS.md, 31.10.).
- Es gibt keinen Status einzelner Aufzüge oder Fahrtreppen. Die Abdeckung der `alerts` in Transitous ist nicht gemessen.

## Entscheidungstabelle

| Quelle | Kennzahl(en) | Abdeckung | Stand | Update | Zugriff | Lizenz | Kommerziell | Empfehlung |
|---|---|---|---|---|---|---|---|---|
| KVB Open Data, Aufzüge und Aufzugstörungen | Liste (65 Aufzüge) und aktuell gestörte Aufzüge mit Zeitstempel | KVB-Haltestellen (Stadtbahn/U-Bahn). Gemessen: 65 Aufzüge, u. a. Bf Deutz/Messe 3, Dom/Hbf 4, Hansaring 2. Keine Aufzüge an Zülpicher Platz und Uni (nicht belegt, ob dort keine existieren) | 3.11.2026 16:20 (Zeitstempel einer Störung) | etwa alle 15 Min. laut Seite | JSON/CSV/XML ohne Key, `https://data.webservice-kvb.koeln/service/opendata/aufzugsstoerung/json` | DL-DE Zero 2.0 laut NRW-Portal ([Datensatz](https://ckan.open.nrw.de/dataset/aufzuge-kvb-koln-k), [Lizenz](https://www.govdata.de/dl-de/zero-2-0)); die [KVB-Seite](https://www.kvb.koeln/service/open_data.html) nennt keine Lizenz | Lizenz ja; KVB-Marken nur mit Zustimmung | Bedingt: nur als Hinweis bei Störung, siehe unten |
| KVB Open Data, Fahrtreppen und Fahrtreppenstörungen | 264 Fahrtreppen, 30 gerade gestört (3.11.) | Lücke laut KVB: Appellhofplatz, Reichenspergerplatz, Bf Deutz/Messe können bei Störung nicht angezeigt werden | wie oben | wie oben | wie oben, Pfad `fahrtreppenstoerung` | wie oben | wie oben | Nicht nutzen für Deutz. Für den Rest nur mit Hinweis "Stand unvollständig" |
| DB FaSta (DB InfraGO) | Aufzüge und Fahrtreppen an Bahnhöfen der DB InfraGO, Status | Bahnhöfe der DB InfraGO (Köln Hbf, Köln Messe/Deutz). Anteil für unsere Stationen nicht gemessen | unklar | unklar, Seite nennt keinen Rhythmus | REST, Anmeldung auf dem [DB API Marketplace](https://developers.deutschebahn.com/db-api-marketplace/apis/product/fasta), Plan Free4All, 60 Aufrufe/s | CC BY 4.0, Nennung der DB AG nötig | ja (CC BY) | Wahrscheinlich ja, erst nach Stichprobe mit Key |
| Transitous/MOTIS `alerts` | Meldungen je Fahrt und Haltestelle | unklar. Dokumentation nennt SIRI-SX, GTFS-RT-Alerts sind unbelegt ([Transitous-Doku](https://transitous.org/doc/)) | unklar | Polling minütlich | schon angebunden | siehe Transitous | nicht kommerziell | Weiter nutzen. Abdeckung für Köln und NRW messen, bevor wir mehr versprechen |
| DELFI/Mobilithek SIRI-SX | bundesweite Störungsmeldungen | unklar | unklar | unklar | Registrierung auf Mobilithek, Freischaltung durch DELFI | unklar | unklar | Nicht jetzt. Transitous soll das Material ohnehin verarbeiten |
| VRS, VRR, Verbünde außerhalb Köln | Aufzüge, Störungen | unklar | unklar | unklar | nicht geprüft | unklar | unklar | Nicht prüfen, bis ein Bedarf in der Familie besteht |

## Nutzen (Top 3)

1. **KVB-Aufzugstörungen**: Offen, ohne Key, im 15-Minuten-Takt. Sie passen zu "Stufenfrei reisen" und nutzen die Koordinaten und die Kennung, die wir mit den Wegschritten abgleichen können.
2. **DB FaSta für Hbf und Messe/Deutz**: Dort fahren die meisten Umstiege. Die KVB-Daten decken diese DB-Bahnsteige nicht ab.
3. **Hinweis bei Störung auf der Route**: Nur Meldungen für Stationen auf der gewählten Verbindung, nicht für alle.

## Lücken

- Fahrtreppen an Deutz/Messe liefert die KVB laut eigener Angabe nicht. Das ist eine belegte Lücke, "lückenlos" ist damit für Fahrtreppen nicht erreicht.
- Die Störungsdateien enthalten nur das, was gerade gestört ist. Kein Eintrag heißt nicht "funktioniert". Die App darf nie "Aufzug in Betrieb" anzeigen, nur "Störung gemeldet".
- Widerspruch auf der NRW-Seite: Anzeige "zuletzt aktualisiert 3.11.2026", Metadatenfeld `modified` 27.11.2025. Wie verlässlich die Pflege ist, bleibt unklar.
- Die KVB behält sich vor, Daten und Auslieferung ohne Nennung von Gründen zu ändern, und gibt keine Gewähr. Eine Zusage für Pflege gibt es nicht.
- Keine Quelle für Aufzüge in Bussen oder an Haltestellen anderer Verbünde, die wir bisher nicht geprüft haben.

## Nächster Schritt

1. API-Key für FaSta anfordern (Marketplace, kostenlos), Stichprobe für Köln Hbf und Köln Messe/Deutz: Anteil der Aufzüge mit Status, Zeitstempel, Aktualität.
2. `alerts` aus Transitous für Köln über einige Tage sammeln und zählen, wie oft Aufzug- oder Fahrtreppenmeldungen vorkommen.
3. Entscheidung von Carlo: Einbau nur als "Störung gemeldet" auf der gewählten Route, nie als positive Aussage. Backend holt die Listen gedrosselt (alle 15 Min.), die App sendet nichts Neues. API.md zuerst anpassen.
