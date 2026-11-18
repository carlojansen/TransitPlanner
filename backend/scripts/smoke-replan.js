// Schritt 0 der proaktiven Umplanung (docs/SPEZIFIKATION.md 4.4): Logiktester + Live-Test.
// Teil 1 (offline, immer): Entscheidungsregeln als Prototyp mit synthetischen Fahrten, Gegenproben inklusive.
// Teil 2 (live, nur ohne --offline): beantwortet die offenen Fragen gegen Transitous. Maximal 6 Routenanfragen.
// Lokal im macOS-Terminal: cd backend && npm run smoke:replan   (nur Logik: npm run smoke:replan -- --offline)
import assert from 'node:assert/strict';

const MIN_SLACK = 120; // TransitCore TransferCheck.minimumSlackSeconds
const WORSEN = 300;    // Spezifikation: neue Suche erst bei 300 s schlechterem Puffer
const MAX_SEARCHES = 3;
const sec = (iso) => Date.parse(iso) / 1000;
const vehicles = (j) => j.legs.filter((l) => l.mode !== 'walk');

// ---- Entscheidungsregeln (Vorlage fuer ConnectionWatch in TransitCore) ----

// Puffer des Umstiegs nach Fahrzeug i unter simulierter Verspaetung (Sekunden) oder Ausfall.
export function bufferAfter(j, i, {delay = 0, cancelledNext = false} = {}) {
	const v = vehicles(j);
	const next = v[i + 1];
	if (!next) return null;
	if (cancelledNext) return -Infinity;
	const walk = j.legs.slice(j.legs.indexOf(v[i]) + 1, j.legs.indexOf(next)).reduce((s, l) => s + (l.durationSeconds ?? 0), 0);
	return sec(next.departure) - (sec(v[i].arrival) + delay) - walk;
}

// Ausloeser: nur im Fahrzeug (phase onBoard), Puffer < 0 oder Ausfall. Knapp (0..120 s) loest nichts aus.
export function trigger(j, i, sim) {
	const buffer = bufferAfter(j, i, sim);
	if (buffer === null || buffer >= 0) return null;
	const v = vehicles(j);
	return {key: `${v[i].tripId}|${v[i + 1].tripId}`, buffer, stopId: v[i].destination.id,
		searchTime: sec(v[i].arrival) + (sim?.delay ?? 0), affectedTripId: v[i + 1].tripId};
}

// Auswahl: erste Alternative ohne betroffene Fahrt, erste Abfahrt >= Suchzeit + Gehweg + MIN_SLACK.
export function pick(journeys, t, walkSeconds = 0) {
	return journeys.find((j) => {
		const first = vehicles(j)[0];
		return first && !vehicles(j).some((l) => l.tripId === t.affectedTripId)
			&& sec(first.departure) >= t.searchTime + walkSeconds + MIN_SLACK;
	}) ?? null;
}

// Speicher gegen Wiederholung: Schluessel, Verschlechterung >= 300 s, hoechstens 3 Suchen je Fahrt.
export function mayRequest(state, t) {
	if (state.searches >= MAX_SEARCHES) return false;
	const seen = state.seen.get(t.key);
	return seen === undefined || t.buffer <= seen - WORSEN;
}

// ---- Teil 1: Logiktests ----
const at = (m) => new Date(Date.UTC(2026, 10, 20, 8, 0) + m * 60_000).toISOString();
const veh = (tripId, dep, arr, destId) => ({mode: 'regional', tripId, departure: at(dep), arrival: at(arr), destination: {id: destId}, durationSeconds: (arr - dep) * 60});
const walk = (sec) => ({mode: 'walk', durationSeconds: sec});
const journey = (legs) => ({legs});
// A: 08:00-08:30 an Koeln-Deutz, Umstieg (120 s Fussweg), B: 08:40
const J = journey([veh('A', 0, 30, 'deutz:gl1'), walk(120), veh('B', 40, 60, 'ziel')]);

const checks = [];
const check = (name, fn) => { try { fn(); checks.push(['OK  ', name]); } catch (e) { checks.push(['FAIL', `${name}: ${e.message}`]); process.exitCode = 1; } };

check('puenktlich: kein Ausloeser', () => assert.equal(trigger(J, 0, {delay: 0}), null));
check('Verspaetung ohne Folge (Puffer 480 s): kein Ausloeser', () => assert.equal(trigger(J, 0, {delay: 5 * 60}), null));
check('knapp (Puffer 60 s, > 0): kein Ausloeser, bestehender Hinweis genuegt', () => assert.equal(trigger(J, 0, {delay: 7 * 60}), null));
check('Verspaetung 9 min: Anschluss verloren -> Ausloeser mit Suchstart Ankunftshalt + Echtzeit', () => {
	const t = trigger(J, 0, {delay: 9 * 60});
	assert.ok(t); assert.equal(t.stopId, 'deutz:gl1'); assert.equal(t.searchTime, sec(at(30)) + 540); assert.equal(t.key, 'A|B');
});
check('Folgefahrzeug faellt aus: Ausloeser trotz Pünktlichkeit', () => assert.ok(trigger(J, 0, {cancelledNext: true})));
check('letztes Fahrzeug: kein Ausloeser (kein Umstieg mehr)', () => assert.equal(trigger(J, 1, {delay: 3600}), null));

const t9 = trigger(J, 0, {delay: 9 * 60}); // Suchzeit 08:39
const alt = (trip, dep) => journey([veh(trip, dep, dep + 20, 'ziel')]);
check('pick: Alternative mit betroffener Fahrt wird nie vorgeschlagen', () => assert.equal(pick([alt('B', 45)], t9), null));
check('pick: Abfahrt vor Suchzeit + 120 s wird uebersprungen', () => assert.equal(pick([alt('C', 39), alt('D', 40)], t9), null));
check('pick: erste erreichbare nach Ranking (Abfahrt 08:41 = Suchzeit + 120 s)', () => assert.equal(pick([alt('C', 39), alt('D', 41), alt('E', 50)], t9)?.legs[0].tripId, 'D'));
check('pick: Gehweg am Suchstart zaehlt (60 s) -> 08:41 reicht nicht mehr', () => assert.equal(pick([alt('D', 41), alt('E', 50)], t9, 60)?.legs[0].tripId, 'E'));

const st = {searches: 0, seen: new Map()};
check('Limit: erste Suche erlaubt', () => assert.equal(mayRequest(st, t9), true));
st.searches = 1; st.seen.set(t9.key, t9.buffer);
check('Limit: Flattern (+-60 s Puffer) loest keine zweite Suche aus', () => assert.equal(mayRequest(st, {...t9, buffer: t9.buffer - 60}), false));
check('Limit: 300 s schlechterer Puffer loest neue Suche aus', () => assert.equal(mayRequest(st, {...t9, buffer: t9.buffer - 300}), true));
check('Limit: nie mehr als 3 Suchen je Fahrt', () => assert.equal(mayRequest({searches: 3, seen: new Map()}, t9), false));
check('Gegenprobe: ohne MIN_SLACK-Regel wuerde 08:40 gewaehlt (Test haette gefangen)', () => {
	const first = alt('C', 40); assert.ok(sec(vehicles(first)[0].departure) >= t9.searchTime && sec(vehicles(first)[0].departure) < t9.searchTime + MIN_SLACK);
});

for (const [s, n] of checks) console.log(`${s}  Logik: ${n}`);
console.log(checks.some(([s]) => s === 'FAIL') ? '\nLogiktest FEHLGESCHLAGEN' : `\nLogiktest bestanden (${checks.length} Pruefungen)`);
if (process.argv.includes('--offline') || process.exitCode) process.exit();

// ---- Teil 2: Live-Test ----
const {loadConfig} = await import('../src/config.js');
const {createMotisClient} = await import('../src/services/motisClient.js');
const {createTransitService} = await import('../src/services/transitService.js');
const {createUpstreamGate} = await import('../src/lib/upstreamGate.js');
const config = loadConfig();
const service = createTransitService({
	client: createMotisClient({baseUrl: config.MOTIS_BASE_URL, userAgent: config.USER_AGENT}),
	gate: createUpstreamGate({limit: config.UPSTREAM_LIMIT, intervalMs: config.UPSTREAM_INTERVAL_MS}),
	timeoutMs: config.UPSTREAM_TIMEOUT_MS,
});
const hhmm = (s) => new Date(s * 1000).toLocaleTimeString('de-DE', {hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Berlin'});
const out = (ok, msg) => { console.log(`${ok ? 'OK  ' : 'FAIL'}  ${msg}`); if (!ok) process.exitCode = 1; };
const info = (msg) => console.log(`      ${msg}`);
let calls = 0;
const routes = (body) => { calls += 1; return service.routes({isArrivalTime: false, onlyNahverkehr: true, ...body}); };

// Fahrten mit Umstieg suchen: (Start, Ziel) als Koordinaten, Zeit in 45 min. Hoechstens 3 Paare.
const pairs = [
	['Neuss Hbf -> Koeln Messe/Deutz', [51.2056, 6.6847], [50.9413, 6.9744]],
	['Wuppertal Hbf -> Koeln Hbf', [51.2543, 7.1498], [50.9428, 6.9587]],
	['Duesseldorf Flughafen -> Koeln Deutz', [51.2778, 6.7664], [50.9413, 6.9744]],
];
const base = Date.now() + 45 * 60_000;
let chosen = null;
for (const [label, [la, lo], [dla, dlo]] of pairs) {
	const r = await routes({origin: {type: 'coordinate', latitude: la, longitude: lo}, destination: {type: 'coordinate', latitude: dla, longitude: dlo}, targetTime: new Date(base).toISOString(), results: 5});
	const j = r.journeys.find((x) => vehicles(x).length >= 2);
	info(`${label}: ${r.journeys.length} Verbindungen, ${j ? 'mit Umstieg' : 'ohne Umstieg'}`);
	if (j) { chosen = {label, j, dest: [dla, dlo]}; break; }
}
if (!chosen) { out(false, 'keine Verbindung mit Umstieg gefunden, Paare anpassen'); process.exit(); }

const {j, dest} = chosen;
const v = vehicles(j);
console.log(`\nSzenario ${chosen.label}: ${v.map((l) => `${l.line?.name ?? l.mode} ${hhmm(sec(l.departure))}-${hhmm(sec(l.arrival))}`).join(' > ')}`);
const delay = Math.ceil((bufferAfter(j, 0) + 5 * 60) / 60) * 60; // soviel, dass der Puffer um 5 min negativ wird
const t = trigger(j, 0, {delay});
out(!!t, `simulierte Verspaetung ${Math.round(delay / 60)} min -> Ausloeser, Suchstart ${t?.stopId} um ${t ? hhmm(t.searchTime) : '-'}`);
const origin = {type: 'stop', id: t.stopId};
const destination = {type: 'coordinate', latitude: dest[0], longitude: dest[1]};

// Frage 1: Start mit Bahnsteig-ID und Echtzeit-Ankunft als Zeit
const r1 = await routes({origin, destination, targetTime: new Date(t.searchTime * 1000).toISOString(), results: 6});
out(r1.journeys.length > 0, `Start ab ${t.stopId} (Bahnsteig-/Halt-ID) liefert ${r1.journeys.length} Verbindungen`);
const firsts = r1.journeys.map((x) => vehicles(x)[0]).filter(Boolean);
const early = firsts.filter((l) => sec(l.departure) < t.searchTime + MIN_SLACK);
info(`erste Abfahrten: ${firsts.map((l) => hhmm(sec(l.departure))).join(' ')}  (Suchzeit ${hhmm(t.searchTime)}, Grenze ${hhmm(t.searchTime + MIN_SLACK)})`);
info(`Frage 3: ${early.length} von ${firsts.length} fahren frueher als Suchzeit + 120 s -> ${early.length ? 'MOTIS liefert Abfahrten ohne Umstiegszeit, pick() muss filtern (Regel bestaetigt)' : 'MOTIS haelt die Umstiegszeit selbst ein'}`);
const zeroTransfer = r1.journeys.filter((x) => x.legs[0]?.mode === 'walk' && vehicles(x).length);
info(`Frage 2: ${zeroTransfer.length} Verbindungen beginnen mit Fussweg ab Halt-ID (Wechsel auf anderes Gleis) -> ${zeroTransfer.length ? 'moeglich' : 'nicht beobachtet'}`);
const sameTrip = r1.journeys.some((x) => vehicles(x).some((l) => l.tripId === t.affectedTripId));
info(`betroffene Fahrt ${t.affectedTripId} taucht ${sameTrip ? 'auf (pick() muss sie ausschliessen)' : 'nicht auf'}`);
const chosenAlt = pick(r1.journeys, t);
out(!!chosenAlt, `pick() findet Vorschlag: ${chosenAlt ? vehicles(chosenAlt).map((l) => `${l.line?.name ?? l.mode} ${hhmm(sec(l.departure))}`).join(' > ') + ` an ${hhmm(sec(chosenAlt.arrival))}` : 'keinen'}`);
info(`Ankunft Original ohne Verspaetung ${hhmm(sec(j.arrival))}, Vorschlag ${chosenAlt ? hhmm(sec(chosenAlt.arrival)) : '-'}`);

// Frage 4: Start per Koordinate des Halts zum Vergleich
const place = v[0].destination;
const r2 = await routes({origin: {type: 'coordinate', latitude: place.latitude, longitude: place.longitude}, destination, targetTime: new Date(t.searchTime * 1000).toISOString(), results: 6});
info(`Vergleich Koordinatenstart: ${r2.journeys.length} Verbindungen, Vorschlag ${pick(r2.journeys, t, 60) ? 'gefunden' : 'keiner'} (Gehweg 60 s angenommen)`);

// Frage 5: via ab dem Fahrzeug vor dem betroffenen (nur wenn es eines gibt)
if (v.length >= 3) {
	const r3 = await routes({origin: {type: 'stop', id: v[0].destination.id}, destination, targetTime: new Date(t.searchTime * 1000).toISOString(), results: 3, via: [{id: v[1].destination.id, stayMinutes: 1}]});
	out(r3.journeys.length > 0, `via ${v[1].destination.id} ab Suchstart: ${r3.journeys.length} Verbindungen`);
} else info('via-Frage uebersprungen: Szenario hat nur einen Umstieg (zweites Szenario mit 2 Umstiegen waere noetig)');

console.log(`\n${calls} Routenanfragen verbraucht. Quellenangabe: ${(r1.attribution?.links ?? []).map((l) => l.url).join(' | ')}`);

// ---- Teil 3: Knoten und zwei Umstiege (Fragen 2 und 5) ----
const far = [
	['Wuppertal-Vohwinkel -> Koeln-Porz', [51.2318, 7.0536], [50.8895, 7.0527]],
	['Hagen Hbf -> Koeln Messe/Deutz', [51.3622, 7.4624], [50.9413, 6.9744]],
	['Krefeld Hbf -> Bonn Hbf', [51.3295, 6.5628], [50.7323, 7.0970]],
	['Mönchengladbach Hbf -> Leverkusen Mitte', [51.1966, 6.4466], [51.0346, 6.9887]],
];
console.log('\n--- Szenario mit zwei Umstiegen ---');
let big = null;
for (const [label, [la, lo], [dla, dlo]] of far) {
	const r = await routes({origin: {type: 'coordinate', latitude: la, longitude: lo}, destination: {type: 'coordinate', latitude: dla, longitude: dlo}, targetTime: new Date(base).toISOString(), results: 6});
	const jj = r.journeys.find((x) => vehicles(x).length >= 3);
	info(`${label}: ${r.journeys.length} Verbindungen, ${jj ? 'mit 2 Umstiegen' : 'hoechstens 1 Umstieg'}`);
	if (jj) { big = {label, j: jj, dest: [dla, dlo]}; break; }
}
if (!big) { out(false, 'kein Szenario mit 2 Umstiegen gefunden'); process.exit(); }
const bv = vehicles(big.j);
console.log(`Szenario ${big.label}: ${bv.map((l) => `${l.line?.name ?? l.mode} ${hhmm(sec(l.departure))}-${hhmm(sec(l.arrival))}`).join(' > ')}`);
const bd = {type: 'coordinate', latitude: big.dest[0], longitude: big.dest[1]};
const bt = trigger(big.j, 1, {delay: Math.ceil((bufferAfter(big.j, 1) + 5 * 60) / 60) * 60}); // betroffen: zweiter Umstieg
out(!!bt, `Ausloeser am zweiten Umstieg, Suchstart ${bt?.stopId} um ${bt ? hhmm(bt.searchTime) : '-'}`);
const iso = new Date(bt.searchTime * 1000).toISOString();
const r4 = await routes({origin: {type: 'stop', id: bt.stopId}, destination: bd, targetTime: iso, results: 6});
const arrPlat = bv[1].arrivalPlatform;
const otherTrack = r4.journeys.filter((x) => { const f = vehicles(x)[0]; return f && f.departurePlatform && arrPlat && f.departurePlatform !== arrPlat; });
info(`Frage 2: Ankunftsgleis ${arrPlat ?? '?'}; ${otherTrack.length} von ${r4.journeys.length} Verbindungen starten auf anderem Gleis (${otherTrack.slice(0, 3).map((x) => 'Gl. ' + vehicles(x)[0].departurePlatform).join(', ')})`);
info(`Frage 2: ${r4.journeys.filter((x) => x.legs[0]?.mode === 'walk').length} mit Fussweg am Anfang`);
out(!!pick(r4.journeys, bt), `pick() am zweiten Umstieg: ${pick(r4.journeys, bt) ? 'Vorschlag gefunden' : 'keiner'}`);
// Frage 5: Zwischenstopp des Nutzers, der HINTER dem Suchstart liegt, bleibt als via erhalten (Aufenthalt 10 min).
// Der Nutzer wollte nach der Umplanung weiter nach Bonn Hbf; sein Zwischenstopp liegt auf der Strecke hinter dem Suchstart.
bd.latitude = 50.7323; bd.longitude = 7.0970;
const r6 = await routes({origin: {type: 'stop', id: bt.stopId}, destination: bd, targetTime: iso, results: 3});
const altV = r6.journeys.flatMap(vehicles).sort((x, y) => (y.stopovers?.length ?? 0) - (x.stopovers?.length ?? 0))[0];
const ahead = (altV?.stopovers ?? []).slice(1, -1).map((s) => s.stop).filter((p) => p?.id);
const viaStop = ahead[Math.floor(ahead.length / 2)];
if (!viaStop) out(false, 'letztes Fahrzeug hat keinen Zwischenhalt fuer den via-Test');
else {
	const STAY = 10;
	const r5 = await routes({origin: {type: 'stop', id: bt.stopId}, destination: bd, targetTime: iso, results: 4, via: [{id: viaStop.id, stayMinutes: STAY}]});
	const stays = (x) => x.legs.some((l, i) => l.mode !== 'walk' && (l.destination.id ?? '').startsWith(viaStop.id.split(':').slice(0, 3).join(':'))
		&& x.legs[i + 1] && sec(x.legs[i + 1].departure) - sec(l.arrival) >= STAY * 60);
	const good = r5.journeys.filter(stays);
	out(good.length > 0, `Frage 5: via ${viaStop.name} (hinter dem Suchstart, ${STAY} min): ${good.length} von ${r5.journeys.length} Verbindungen halten den Aufenthalt ein`);
	const f = good[0] && vehicles(good[0])[0];
	if (f) out(sec(f.departure) >= bt.searchTime + MIN_SLACK, `erste Abfahrt ${hhmm(sec(f.departure))} >= Suchzeit + 120 s (${hhmm(bt.searchTime + MIN_SLACK)})`);
	// Gegenprobe: via vor dem Suchstart (Halt von Fahrzeug 0) darf nie als Rest-via benutzt werden; Test liegt in TransitCore.
}
console.log(`\n${calls} Routenanfragen insgesamt.`);
