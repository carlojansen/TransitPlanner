import {describe, it, expect, beforeEach} from 'vitest';
import request from 'supertest';
import {createApp} from '../src/app.js';
import {loadConfig} from '../src/config.js';
import {createTransitService, NAHVERKEHR_MODES} from '../src/services/transitService.js';
import {createUpstreamGate} from '../src/lib/upstreamGate.js';
import {createFakeClient, itinerary, leg, walk, placeDusHbf} from './fixtures.js';

const TOKEN = 'test-token-0123456789-abcdefghijklmnop';
const UA = 'TransitPlanner/0.1.0 (dev@example.invalid)';
const config = loadConfig({
	NODE_ENV: 'test', USER_AGENT: UA, API_TOKEN: TOKEN,
	RATE_LIMIT_PER_MINUTE: '1000', LOG_LEVEL: 'silent',
});

let client;
let app;
const auth = {Authorization: `Bearer ${TOKEN}`};

function build(overrides, cfg = config, logger) {
	client = createFakeClient(overrides);
	const gate = createUpstreamGate({limit: 1000, intervalMs: 1000, maxQueue: 50, minRemainingMs: 0});
	const service = createTransitService({client, gate, timeoutMs: 200});
	app = createApp({config: cfg, service, logger});
}

beforeEach(() => build());

const httpError = (status) => Object.assign(new Error(`MOTIS HTTP ${status}`), {name: 'UpstreamHttpError', response: {status}});

describe('Konfiguration', () => {
	it('erzwingt einen User-Agent mit Name, Version und Kontakt (Transitous-Regel)', () => {
		expect(() => loadConfig({USER_AGENT: 'transitplanner', API_TOKEN: TOKEN})).toThrow(/USER_AGENT/);
		expect(() => loadConfig({USER_AGENT: 'TransitPlanner/0.1.0', API_TOKEN: TOKEN})).toThrow(/USER_AGENT/);
		expect(loadConfig({USER_AGENT: 'TransitPlanner/0.1.0 (https://example.org)', API_TOKEN: TOKEN}).USER_AGENT).toBeTruthy();
	});

	it('verbietet Staging- und interne Transitous-Endpunkte sowie http', () => {
		expect(() => loadConfig({USER_AGENT: UA, API_TOKEN: TOKEN, MOTIS_BASE_URL: 'https://staging.api.transitous.org'})).toThrow(/MOTIS_BASE_URL/);
		expect(() => loadConfig({USER_AGENT: UA, API_TOKEN: TOKEN, MOTIS_BASE_URL: 'https://europe.motis-project.de'})).toThrow(/MOTIS_BASE_URL/);
		expect(() => loadConfig({USER_AGENT: UA, API_TOKEN: TOKEN, MOTIS_BASE_URL: 'http://api.transitous.org'})).toThrow(/MOTIS_BASE_URL/);
		expect(loadConfig({USER_AGENT: UA, API_TOKEN: TOKEN}).MOTIS_BASE_URL).toBe('https://api.transitous.org');
	});

	it('lehnt kurze Tokens ab', () => {
		expect(() => loadConfig({USER_AGENT: UA, API_TOKEN: 'short'})).toThrow(/API_TOKEN/);
	});
});

describe('Sicherheit', () => {
	it('healthz ist ohne Auth erreichbar', async () => {
		await request(app).get('/healthz').expect(200, {status: 'ok'});
	});

	it('akzeptiert das Bearer-Schema case-insensitiv', async () => {
		await request(app).get('/api/locations?query=Koeln').set('Authorization', `bearer ${TOKEN}`).expect(200);
	});

	it('verlangt Bearer-Token', async () => {
		const r = await request(app).get('/api/locations?query=Köln').expect(401);
		expect(r.body.error.code).toBe('UNAUTHORIZED');
		await request(app).get('/api/locations?query=Köln').set('Authorization', 'Bearer falsch').expect(401);
	});

	it('Unbekannte ohne Token koennen das globale Routen-Limit nicht leeren', async () => {
		for (let i = 0; i < 35; i++) await request(app).post('/api/routes').set('X-Forwarded-For', `10.9.0.${i}`).send({}).expect(401);
		await request(app).post('/api/routes').set(auth).send({origin: {type: 'stop', id: 'de-DELFI_de:05111:18235'}, destination: {type: 'stop', id: 'de-DELFI_de:05315:11201'}}).expect(200);
	});

	it('setzt no-store auch auf Auth-Fehlern', async () => {
		const r = await request(app).post('/api/routes').send({}).expect(401);
		expect(r.headers['cache-control']).toBe('no-store');
	});

	it('setzt no-store und keine x-powered-by', async () => {
		const r = await request(app).get('/api/locations?query=Köln').set(auth).expect(200);
		expect(r.headers['cache-control']).toBe('no-store');
		expect(r.headers['x-powered-by']).toBeUndefined();
	});

	it('lehnt unbekannte Felder ab (keine Identitaets-/Kalenderdaten)', async () => {
		const r = await request(app).post('/api/routes').set(auth).send({
			origin: {type: 'stop', id: 'de-DELFI_de:05111:18235'}, destination: {type: 'stop', id: 'de-DELFI_de:05315:11201'},
			calendarTitle: 'Arzttermin',
		}).expect(400);
		expect(r.body.error.code).toBe('INVALID_REQUEST');
		expect(JSON.stringify(r.body)).not.toContain('Arzttermin');
	});

	it('lehnt Namen an Koordinatenpunkten ab', async () => {
		await request(app).post('/api/routes').set(auth).send({
			origin: {type: 'coordinate', latitude: 51.22, longitude: 6.79, name: 'Musterstr. 1'},
			destination: {type: 'stop', id: 'de-DELFI_de:05315:11201'},
		}).expect(400);
	});

	it('Body-Parser-Fehler (falsches Charset, kaputtes JSON) sind INVALID_REQUEST statt INTERNAL', async () => {
		const r = await request(app).post('/api/refresh').set(auth).set('Content-Type', 'application/json; charset=latin1')
			.send('{"refreshToken":"x"}').expect(400);
		expect(r.body.error.code).toBe('INVALID_REQUEST');
		await request(app).post('/api/refresh').set(auth).set('Content-Type', 'application/json').send('{kaputt').expect(400);
	});

	it('unbekannte Felder erscheinen nicht mit Namen in details', async () => {
		const r = await request(app).post('/api/refresh').set(auth).send({refreshToken: 'abc', geheimesFeld: 1}).expect(400);
		expect(JSON.stringify(r.body)).not.toContain('geheimesFeld');
		expect(r.body.error.details).toContain('unknown_field');
	});

	it('Limit pro IP fuer Routen greift vor dem globalen Zaehler (8/min)', async () => {
		const body = {origin: {type: 'stop', id: 'de-DELFI_de:05111:18235'}, destination: {type: 'stop', id: 'de-DELFI_de:05315:11201'}};
		for (let i = 0; i < 8; i++) await request(app).post('/api/routes').set(auth).set('X-Forwarded-For', '10.1.0.1').send(body).expect(200);
		for (let i = 0; i < 5; i++) {
			const r = await request(app).post('/api/routes').set(auth).set('X-Forwarded-For', '10.1.0.1').send(body).expect(429);
			expect(r.body.error.code).toBe('RATE_LIMITED');
			expect(r.headers['retry-after']).toBe('60');
		}
		// Globaler Zaehler (30) hat nur 8 verbraucht: 22 weitere von anderen IPs gehen durch.
		for (let i = 0; i < 22; i++) await request(app).post('/api/routes').set(auth).set('X-Forwarded-For', `10.2.0.${Math.floor(i / 7)}`).send(body).expect(200);
	});

	it('Limits pro IP fuer locations (20/min) und refresh (12/min)', async () => {
		for (let i = 0; i < 20; i++) await request(app).get('/api/locations?query=Koeln').set(auth).set('X-Forwarded-For', '10.3.0.1').expect(200);
		await request(app).get('/api/locations?query=Koeln').set(auth).set('X-Forwarded-For', '10.3.0.1').expect(429);
		await request(app).get('/api/locations?query=Koeln').set(auth).set('X-Forwarded-For', '10.3.0.2').expect(200);
		for (let i = 0; i < 12; i++) await request(app).post('/api/refresh').set(auth).set('X-Forwarded-For', '10.3.0.3').send({}).expect(400);
		await request(app).post('/api/refresh').set(auth).set('X-Forwarded-For', '10.3.0.3').send({}).expect(429);
	});

	it('akzeptiert Tokens aus API_TOKENS zusaetzlich zu API_TOKEN', async () => {
		const second = 'second-token-0123456789-abcdefghijklmnop';
		const cfg = loadConfig({NODE_ENV: 'test', USER_AGENT: UA, API_TOKEN: TOKEN, API_TOKENS: ` ${second} `, RATE_LIMIT_PER_MINUTE: '1000', LOG_LEVEL: 'silent'});
		build(undefined, cfg);
		await request(app).get('/api/locations?query=Koeln').set('Authorization', `Bearer ${second}`).expect(200);
		await request(app).get('/api/locations?query=Koeln').set(auth).expect(200);
		await request(app).get('/api/locations?query=Koeln').set('Authorization', 'Bearer nope').expect(401);
		expect(() => loadConfig({USER_AGENT: UA, API_TOKEN: TOKEN, API_TOKENS: 'kurz'})).toThrow(/API_TOKENS/);
	});

	it('sendet keine RateLimit-Header, aber Retry-After bei 429', async () => {
		const ok = await request(app).get('/api/locations?query=Koeln').set(auth).expect(200);
		expect(Object.keys(ok.headers).filter((h) => /^ratelimit/i.test(h))).toEqual([]);
		for (let i = 0; i < 20; i++) await request(app).get('/api/locations?query=Koeln').set(auth);
		const r = await request(app).get('/api/locations?query=Koeln').set(auth).expect(429);
		expect(Object.keys(r.headers).filter((h) => /^ratelimit/i.test(h))).toEqual([]);
		expect(r.headers['retry-after']).toBe('60');
	});

	it('Zugriffslog nennt bei 404 keinen Pfad', async () => {
		const lines = [];
		build(undefined, config, {info: (o) => lines.push(o), warn() {}, error() {}});
		await request(app).get('/api/geheim-pfad').set(auth).expect(404);
		expect(lines.at(-1).path).toBe('<unmatched>');
		expect(JSON.stringify(lines)).not.toContain('geheim');
	});

	it('Nicht-Body-Parser-Fehler bleiben INTERNAL', async () => {
		build({async plan() { throw new TypeError('x'); }});
		await request(app).post('/api/routes').set(auth).send({origin: {type: 'stop', id: 'a'}, destination: {type: 'stop', id: 'b'}}).expect(500);
	});

	it('lehnt Tokens mit Leerzeichen oder ueber 512 Zeichen ab', () => {
		expect(() => loadConfig({USER_AGENT: UA, API_TOKEN: `${TOKEN} x`})).toThrow(/API_TOKEN/);
		expect(() => loadConfig({USER_AGENT: UA, API_TOKEN: 'a'.repeat(513)})).toThrow(/API_TOKEN/);
		expect(() => loadConfig({USER_AGENT: UA, API_TOKEN: TOKEN, API_TOKENS: `${TOKEN}, ${'b'.repeat(513)}`})).toThrow(/API_TOKENS/);
	});

	it('begrenzt die Body-Groesse', async () => {
		await request(app).post('/api/refresh').set(auth).set('Content-Type', 'application/json')
			.send(JSON.stringify({refreshToken: 'x'.repeat(20_000)})).expect(400);
	});

	it('liefert bei unbekannten Routen ein typisiertes 404', async () => {
		const r = await request(app).get('/nope').expect(404);
		expect(r.body.error.code).toBe('NOT_FOUND');
	});
});

describe('GET /api/locations', () => {
	it('Textsuche: nur Haltestellen, ohne Koordinaten an Transitous, lokal nach Naehe sortiert', async () => {
		const r = await request(app).get('/api/locations').query({query: 'Hbf', lat: 51.2210, lon: 6.7932}).set(auth).expect(200);
		const [, q] = client.calls.find((c) => c[0] === 'geocode');
		expect(q.text).toBe('Hbf');
		expect(q.type).toBe('STOP');
		expect(q.place).toBeUndefined();
		expect(JSON.stringify(q)).not.toMatch(/51\.|6\.79/);
		expect(r.body.places[0]).toMatchObject({kind: 'stop', id: 'de-DELFI_de:05111:18235', name: 'Düsseldorf Hbf', area: 'Düsseldorf'});
		expect(r.body.places[0].distanceMeters).toBeLessThan(r.body.places[1].distanceMeters);
		expect(r.body.attribution.links.map((l) => l.url)).toEqual(['https://transitous.org/sources/', 'https://www.openstreetmap.org/copyright']);
	});

	it('verwirft Adressen und Orte, auch wenn Transitous sie liefert', async () => {
		build({async geocode() { return [{type: 'ADDRESS', id: 'a', name: 'Musterstr. 1', lat: 51.2, lon: 6.8}, {type: 'PLACE', id: 'p', name: 'Park', lat: 51.2, lon: 6.8}, {type: 'STOP', id: 's', name: 'Köln Hbf', lat: 50.9, lon: 6.9}]; }});
		const r = await request(app).get('/api/locations?query=Musterstr').set(auth).expect(200);
		expect(r.body.places.map((p) => p.name)).toEqual(['Köln Hbf']);
	});

	it('Umkreissuche: gerundete Koordinaten, Rechteck um 500 m, lokal gefiltert', async () => {
		const r = await request(app).get('/api/locations').query({lat: 51.221987, lon: 6.793251}).set(auth).expect(200);
		const [, q] = client.calls.find((c) => c[0] === 'stops');
		const [minLat, minLon] = q.min.split(',').map(Number);
		const [maxLat, maxLon] = q.max.split(',').map(Number);
		expect((minLat + maxLat) / 2).toBeCloseTo(51.222, 5); // Mittelpunkt = auf 3 Stellen gerundet
		expect((minLon + maxLon) / 2).toBeCloseTo(6.793, 5);
		expect((maxLat - minLat) * 111_320).toBeCloseTo(1000, -1);
		expect(r.body.places.map((p) => p.name)).toEqual(['Düsseldorf Hbf']);
		expect(r.body.places[0].distanceMeters).toBeLessThanOrEqual(500);
	});

	it('cached Textsuchen', async () => {
		await request(app).get('/api/locations?query=Koeln').set(auth).expect(200);
		await request(app).get('/api/locations?query=koeln').set(auth).expect(200);
		expect(client.calls.filter((c) => c[0] === 'geocode')).toHaveLength(1);
	});

	it('lehnt leere, hexadezimale und auslaendische Koordinaten ab', async () => {
		await request(app).get('/api/locations?lat=&lon=').set(auth).expect(400);
		await request(app).get('/api/locations?lat=0x10&lon=6.7').set(auth).expect(400);
		await request(app).get('/api/locations?lat=1e1&lon=6.7').set(auth).expect(400);
		await request(app).get('/api/locations?lat=40.7&lon=-74.0').set(auth).expect(400);
		expect(client.calls.filter((c) => c[0] === 'stops')).toHaveLength(0);
	});

	it('verlangt query oder lat/lon', async () => {
		await request(app).get('/api/locations').set(auth).expect(400);
		await request(app).get('/api/locations?lat=51').set(auth).expect(400);
	});
});

describe('POST /api/routes', () => {
	const body = {origin: {type: 'coordinate', latitude: 51.220123, longitude: 6.790456}, destination: {type: 'stop', id: 'de-DELFI_de:05315:11201'}};

	it('baut die MOTIS-Anfrage korrekt: Koordinate ohne Namen, Stop-ID, Nahverkehrsfilter kommagetrennt', async () => {
		await request(app).post('/api/routes').set(auth).send(body).expect(200);
		const [, q] = client.calls.find((c) => c[0] === 'plan');
		expect(q.fromPlace).toBe('51.2201,6.7905'); // 4 Nachkommastellen (~11 m)
		expect(q.toPlace).toBe('de-DELFI_de:05315:11201');
		expect(q.arriveBy).toBe(false);
		expect(q.numItineraries).toBe(4);
		expect(typeof q.transitModes).toBe('string');
		expect(q.transitModes.split(',')).toEqual(NAHVERKEHR_MODES);
		expect(q.transitModes).not.toMatch(/(^|,)(RAIL|HIGHSPEED_RAIL|LONG_DISTANCE|NIGHT_RAIL|COACH)(,|$)/);
		expect(q.time).toBeUndefined();
	});

	it('ohne Nahverkehrsfilter keine Modus-Einschraenkung', async () => {
		await request(app).post('/api/routes').set(auth).send({...body, onlyNahverkehr: false}).expect(200);
		const [, q] = client.calls.find((c) => c[0] === 'plan');
		expect(q.transitModes).toBeUndefined();
	});

	it('mappt Verbindungen inkl. Polylines, Verspaetung, Gleiswechsel, Linienfarbe, Meldungen', async () => {
		const r = await request(app).post('/api/routes').set(auth).send(body).expect(200);
		const [hero, alt] = r.body.journeys;
		expect(hero.refreshToken).toBe('aXRpbi0x');
		expect(alt.refreshToken).toBe('aXRpbi0y');
		expect(hero.hasPolylines).toBe(true);
		expect(alt.hasPolylines).toBe(true); // MOTIS liefert Geometrie fuer alle Verbindungen
		const ride = hero.legs[1];
		expect(ride.polyline.type).toBe('LineString');
		expect(ride.polyline.coordinates).toHaveLength(3); // Duplikat entfernt
		expect(ride.polyline.coordinates[0]).toEqual([6.79432, 51.21996]); // [lon, lat]
		expect(ride).toMatchObject({
			mode: 'regional', platformChanged: true, departureDelaySeconds: 180, arrivalDelaySeconds: 120, realtime: true,
			departurePlatform: '9', plannedDeparturePlatform: '10', direction: 'Koblenz Hbf', loadFactor: null,
			line: {name: 'RE 5', productName: 'RE', fahrtNr: '10123', operator: 'National Express', color: '#E2001A', textColor: '#FFFFFF'},
		});
		expect(ride.stopovers[0]).toMatchObject({platform: '2', arrivalDelaySeconds: 120, departureDelaySeconds: 120});
		expect(ride.remarks[0]).toMatchObject({type: 'warning', summary: 'Gleiswechsel'});
		expect(hero.legs[0]).toMatchObject({mode: 'walk', isTransfer: false, distanceMeters: 420, durationSource: 'motis-osm', departureDelaySeconds: null});
		expect(hero.legs[0].origin).toMatchObject({kind: 'coordinate', id: null, name: null});
		expect(hero).toMatchObject({transfers: 0, durationSeconds: 42 * 60, modes: ['regional'], realtime: true});
		expect(r.body).toMatchObject({earlierRef: 'prev', laterRef: 'next'});
	});

	it('Ankunftszeit-Modus und Zielzeit', async () => {
		const t = new Date(Date.now() + 3600_000).toISOString();
		await request(app).post('/api/routes').set(auth).send({...body, targetTime: t, isArrivalTime: true}).expect(200);
		const [, q] = client.calls.find((c) => c[0] === 'plan');
		expect(q.arriveBy).toBe(true);
		expect(q.time).toBe(t);
	});

	it('Paging: Cursor plus unveraenderte Ursprungsparameter', async () => {
		const t = new Date(Date.now() + 3600_000).toISOString();
		await request(app).post('/api/routes').set(auth).send({...body, targetTime: t, laterThan: 'next'}).expect(200);
		const [, q] = client.calls.find((c) => c[0] === 'plan');
		expect(q.pageCursor).toBe('next');
		expect(q.time).toBe(t);
		await request(app).post('/api/routes').set(auth).send({...body, laterThan: 'a', earlierThan: 'b'}).expect(400);
	});

	it('begrenzt auf results', async () => {
		build({async plan() { return {itineraries: [1, 2, 3, 4, 5].map((i) => itinerary({id: `id${i}`}))}; }});
		const r = await request(app).post('/api/routes').set(auth).send({...body, results: 3}).expect(200);
		expect(r.body.journeys).toHaveLength(3);
	});

	it('markiert Fusswege zwischen zwei Fahrzeugen als Umstieg', async () => {
		const ride1 = leg();
		const transfer = walk({from: ride1.to, to: ride1.to, start: ride1.endTime, end: '2026-10-24T06:46:00Z', distance: 120});
		const ride2 = leg({mode: 'TRAM', displayName: 'STR 4', start: '2026-10-24T06:50:00Z', end: '2026-10-24T07:00:00Z', schedStart: '2026-10-24T06:50:00Z', schedEnd: '2026-10-24T07:00:00Z'});
		build({async plan() { return {itineraries: [itinerary({legs: [walk(), ride1, transfer, ride2]})]}; }});
		const r = await request(app).post('/api/routes').set(auth).send(body).expect(200);
		const legs = r.body.journeys[0].legs;
		expect(legs[0].isTransfer).toBe(false);
		expect(legs[2]).toMatchObject({mode: 'walk', isTransfer: true});
		expect(r.body.journeys[0]).toMatchObject({transfers: 1, modes: ['regional', 'tram']});
		// Doppelte Meldungen werden auf Journey-Ebene zusammengefasst
		expect(r.body.journeys[0].remarks).toHaveLength(1);
	});

	it('verwirft Fernverkehr defensiv: Modus, Zuggattung bei REGIONAL_RAIL (GTFS route_type 2), Fernbus-Betreiber bei BUS', async () => {
		build({
			async plan() {
				return {itineraries: [
					itinerary({id: 'ice', legs: [leg({mode: 'HIGHSPEED_RAIL', displayName: 'ICE 123'})]}),
					itinerary({id: 'ic-als-regio', legs: [leg({mode: 'REGIONAL_RAIL', displayName: 'IC 2045 (2045)', extra: {routeShortName: 'IC 2045', category: {id: 'IC', name: 'Intercity', shortName: 'IC'}}})]}),
					itinerary({id: 'flixbus', legs: [leg({mode: 'BUS', displayName: 'N123', extra: {routeShortName: 'N123', agencyName: 'FlixBus', category: undefined}})]}),
					itinerary({id: 'regio'}),
				]};
			},
		});
		const r = await request(app).post('/api/routes').set(auth).send(body).expect(200);
		expect(r.body.journeys.map((j) => j.refreshToken)).toEqual(['regio']);
		expect(r.body.removedLongDistance).toBe(3);
	});

	it('fragt genau einmal mit mehr Verbindungen nach, wenn der Filter alles verworfen hat', async () => {
		let n = 0;
		build({
			async plan(q) {
				n++;
				client.calls.push(['plan', q]);
				return n === 1
					? {itineraries: [itinerary({id: 'ic', legs: [leg({mode: 'REGIONAL_RAIL', extra: {routeShortName: 'IC 2045'}})]})]}
					: {itineraries: [itinerary({id: 'ic'}), itinerary({id: 'regio'})].map((it, i) => (i === 0 ? {...it, legs: [leg({mode: 'REGIONAL_RAIL', extra: {routeShortName: 'IC 2045'}})]} : it))};
			},
		});
		const r = await request(app).post('/api/routes').set(auth).send(body).expect(200);
		expect(n).toBe(2);
		expect(client.calls[1][1].numItineraries).toBe(12);
		expect(r.body.journeys.map((j) => j.refreshToken)).toEqual(['regio']);
	});

	it('kurze Distanz: MOTIS liefert nur einen direkten Fussweg, der wird ausgeliefert', async () => {
		build({async plan() { return {itineraries: [], direct: [itinerary({id: 'walk', legs: [walk()]})]}; }});
		const r = await request(app).post('/api/routes').set(auth).send(body).expect(200);
		expect(r.body.walkOnly).toBe(true);
		expect(r.body.journeys[0].modes).toEqual([]);
		expect(r.body.laterRef).toBeNull();
	});

	it('unerwartete Antwortform (z. B. HTML mit 200) ist UPSTREAM_UNAVAILABLE, nicht NO_CONNECTIONS', async () => {
		build({async plan() { return '<html>'; }});
		await request(app).post('/api/routes').set(auth).send(body).expect(502);
		build({async plan() { return {}; }});
		await request(app).post('/api/routes').set(auth).send(body).expect(502);
	});

	it('NO_CONNECTIONS bei leerem Ergebnis', async () => {
		build({async plan() { return {itineraries: [], direct: []}; }});
		const r = await request(app).post('/api/routes').set(auth).send(body).expect(404);
		expect(r.body.error.code).toBe('NO_CONNECTIONS');
	});

	it('Timeout bricht die Anfrage per AbortSignal ab und liefert 504 ohne Interna', async () => {
		let receivedSignal;
		build({plan: (_q, signal) => { receivedSignal = signal; return new Promise(() => {}); }});
		const r = await request(app).post('/api/routes').set(auth).send(body).expect(504);
		expect(r.body.error.code).toBe('UPSTREAM_TIMEOUT');
		expect(receivedSignal.aborted).toBe(true);
		expect(JSON.stringify(r.body)).not.toMatch(/stack|TimeoutError/);
	});

	it('mappt Transitous-Drosselung auf 502 mit Retry-After', async () => {
		build({async plan() { throw httpError(429); }});
		const r = await request(app).post('/api/routes').set(auth).send(body).expect(502);
		expect(r.headers['retry-after']).toBe('30');
	});

	it('mappt Netzwerkfehler (natives fetch, auch Abbruch beim Body-Lesen) auf 502', async () => {
		for (const e of [
			Object.assign(new TypeError('fetch failed'), {cause: {code: 'ECONNRESET'}}),
			Object.assign(new TypeError('terminated'), {cause: {code: 'UND_ERR_SOCKET'}}),
		]) {
			build({async plan() { throw e; }});
			const r = await request(app).post('/api/routes').set(auth).send(body).expect(502);
			expect(r.body.error.code).toBe('UPSTREAM_UNAVAILABLE');
		}
	});

	it('mappt Sperren (403) und 5xx auf 502', async () => {
		for (const s of [403, 500, 503]) {
			build({async plan() { throw httpError(s); }});
			await request(app).post('/api/routes').set(auth).send(body).expect(502);
		}
	});

	it('mappt fachliche Ablehnung (400) auf 400', async () => {
		build({async plan() { throw httpError(400); }});
		await request(app).post('/api/routes').set(auth).send(body).expect(400);
	});

	it('unbekannte Stop-ID (MOTIS not_found_exception = 404) wird NOT_FOUND', async () => {
		build({async plan() { throw httpError(404); }});
		const r = await request(app).post('/api/routes').set(auth).send(body).expect(404);
		expect(r.body.error.code).toBe('NOT_FOUND');
	});

	it('uebernimmt Retry-After von Transitous bei 429', async () => {
		build({async plan() { throw Object.assign(httpError(429), {retryAfterSeconds: 45}); }});
		const r = await request(app).post('/api/routes').set(auth).send(body).expect(502);
		expect(r.headers['retry-after']).toBe('45');
	});

	it('Programmierfehler sind INTERNAL, nicht UPSTREAM', async () => {
		build({async plan() { throw new TypeError('Cannot read properties of undefined'); }});
		const r = await request(app).post('/api/routes').set(auth).send(body).expect(500);
		expect(r.body.error.code).toBe('INTERNAL');
	});

	it('hat ein eigenes, globales Rate-Limit fuer Routensuchen', async () => {
		// Standard: 60 Upstream-Anfragen/Minute -> 30 Routensuchen/Minute fuer alle Clients zusammen
		build(undefined, loadConfig({NODE_ENV: 'test', USER_AGENT: UA, API_TOKEN: TOKEN, RATE_LIMIT_PER_MINUTE: '1000', RATE_LIMIT_ROUTES_PER_MINUTE: '100', LOG_LEVEL: 'silent'}));
		for (let i = 0; i < 15; i++) await request(app).post('/api/routes').set(auth).set('X-Forwarded-For', '10.0.0.1').send(body).expect(200);
		for (let i = 0; i < 15; i++) await request(app).post('/api/routes').set(auth).set('X-Forwarded-For', '10.0.0.2').send(body).expect(200);
		const r = await request(app).post('/api/routes').set(auth).set('X-Forwarded-For', '10.0.0.3').send(body).expect(429);
		expect(r.body.error.code).toBe('RATE_LIMITED');
		expect(r.headers['cache-control']).toBe('no-store');
		await request(app).get('/api/locations?query=Koeln').set(auth).expect(200);
	});

	it('validiert Eingaben', async () => {
		await request(app).post('/api/routes').set(auth).send({origin: body.origin, destination: body.origin}).expect(400);
		await request(app).post('/api/routes').set(auth).send({...body, origin: {type: 'stop', id: '51.2,6.7'}}).expect(400); // Komma = Koordinaten-Injektion
		await request(app).post('/api/routes').set(auth).send({...body, origin: {type: 'stop', id: 'a b'}}).expect(400);
		await request(app).post('/api/routes').set(auth).send({...body, origin: {type: 'coordinate', latitude: 40.7, longitude: -74}}).expect(400);
		await request(app).post('/api/routes').set(auth).send({...body, targetTime: '2026-10-24 08:00'}).expect(400);
		await request(app).post('/api/routes').set(auth).send({...body, results: 50}).expect(400);
		await request(app).post('/api/routes').set(auth).send({origin: body.origin, destination: {...body.origin, latitude: body.origin.latitude + 0.000001}}).expect(400);
		expect(client.calls.filter((c) => c[0] === 'plan')).toHaveLength(0);
	});
});

describe('POST /api/refresh', () => {
	it('aktualisiert eine Verbindung ueber die itineraryId', async () => {
		const r = await request(app).post('/api/refresh').set(auth).send({refreshToken: 'aXRpbi0xYWJj', polylines: true}).expect(200);
		const [, q] = client.calls.find((c) => c[0] === 'refreshItinerary');
		expect(q.itineraryId).toBe('aXRpbi0xYWJj');
		expect(r.body.journey.refreshToken).toBe('aXRpbi0xYWJj');
		expect(r.body.journey.hasPolylines).toBe(true);
		expect(r.body.journey.legs[1].remarks[0]).toMatchObject({type: 'warning', summary: 'Gleiswechsel'});
	});

	it('laesst Polylines weg, wenn nicht angefordert (spart Datenvolumen)', async () => {
		const r = await request(app).post('/api/refresh').set(auth).send({refreshToken: 'aXRpbi0xYWJj'}).expect(200);
		expect(r.body.journey.legs.every((l) => l.polyline === null)).toBe(true);
	});

	it('akzeptiert Base64-Zeichen im Token', async () => {
		await request(app).post('/api/refresh').set(auth).send({refreshToken: 'ab+/cd==EFgh'}).expect(200);
	});

	it('meldet eine Sperre beim Refresh NICHT als abgelaufen', async () => {
		build({async refreshItinerary() { throw httpError(403); }});
		const r = await request(app).post('/api/refresh').set(auth).send({refreshToken: 'aXRpbi0xYWJj'}).expect(502);
		expect(r.body.error.code).toBe('UPSTREAM_UNAVAILABLE');
	});

	it('nicht mehr rekonstruierbare Fahrt (MOTIS: 200 mit Platzhalter-Abschnitt) wird REFRESH_EXPIRED, ohne internen Text', async () => {
		// Form wie motis src/itinerary_id.cc make_dummy_leg
		const dummy = {
			mode: 'REGIONAL_RAIL', displayName: 'RE5',
			from: {name: '', stopId: 'de-DELFI_de:05111:18235', lat: 51.22, lon: 6.79, departure: '2026-10-24T06:10:00Z', scheduledDeparture: '2026-10-24T06:10:00Z', cancelled: true},
			to: {name: '', stopId: 'de-DELFI_de:05315:11201', lat: 50.94, lon: 6.96, arrival: '2026-10-24T06:40:00Z', scheduledArrival: '2026-10-24T06:40:00Z', cancelled: true},
			duration: 1800, startTime: '2026-10-24T06:10:00Z', endTime: '2026-10-24T06:40:00Z',
			scheduledStartTime: '2026-10-24T06:10:00Z', scheduledEndTime: '2026-10-24T06:40:00Z',
			realTime: false, scheduled: true, cancelled: true,
			legGeometry: {points: '', precision: 6, length: 0},
			alerts: [{headerText: 'reconstruct_itinerary: additional trip not found'}],
		};
		build({async refreshItinerary() { return itinerary({legs: [walk(), dummy]}); }});
		const r = await request(app).post('/api/refresh').set(auth).send({refreshToken: 'aXRpbi0xYWJj'}).expect(410);
		expect(r.body.error.code).toBe('REFRESH_EXPIRED');
		expect(JSON.stringify(r.body)).not.toMatch(/reconstruct|not found/);
	});

	it('Fussweg-Platzhalter ("no offset found") wird ebenfalls REFRESH_EXPIRED statt falscher Ausfall', async () => {
		const dummyWalk = {mode: 'WALK', cancelled: true, realTime: false, from: {name: '', lat: 51.22, lon: 6.79}, to: {name: '', lat: 51.22, lon: 6.79},
			startTime: '2026-10-24T06:00:00Z', endTime: '2026-10-24T06:06:00Z', scheduledStartTime: '2026-10-24T06:00:00Z', scheduledEndTime: '2026-10-24T06:06:00Z',
			duration: 360, scheduled: true, legGeometry: {points: '', precision: 6, length: 0}, alerts: [{headerText: 'no offset found'}]};
		build({async refreshItinerary() { return itinerary({legs: [dummyWalk, leg()]}); }});
		await request(app).post('/api/refresh').set(auth).send({refreshToken: 'aXRpbi0xYWJj'}).expect(410);
	});

	it('ein echter Ausfall (mit tripId und GTFS-RT-Meldung) bleibt ein Ausfall', async () => {
		const cancelled = leg({extra: {cancelled: true, alerts: [{headerText: 'Zugausfall', descriptionText: 'Faellt heute aus', severityLevel: 'WARNING'}]}});
		build({async refreshItinerary() { return itinerary({legs: [walk(), cancelled]}); }});
		const r = await request(app).post('/api/refresh').set(auth).send({refreshToken: 'aXRpbi0xYWJj'}).expect(200);
		expect(r.body.journey.cancelled).toBe(true);
	});

	it('meldet ungueltige/abgelaufene Tokens als REFRESH_EXPIRED (410)', async () => {
		for (const s of [400, 404]) {
			build({async refreshItinerary() { throw httpError(s); }});
			const r = await request(app).post('/api/refresh').set(auth).send({refreshToken: 'aXRpbi0xYWJj'}).expect(410);
			expect(r.body.error.code).toBe('REFRESH_EXPIRED');
		}
	});

	it('lehnt Steuerzeichen im Token ab', async () => {
		await request(app).post('/api/refresh').set(auth).send({refreshToken: 'abc\ndef\u0000ghi'}).expect(400);
	});
});

describe('Datenqualitaet (aus dem Live-Test)', () => {
	it('Zwischenhalte ohne Echtzeit haben Verspaetung null, nicht 0', async () => {
		const noRt = leg({extra: {realTime: false}});
		build({async plan() { return {itineraries: [itinerary({legs: [noRt]})]}; }});
		const r = await request(app).post('/api/routes').set(auth).send({origin: {type: 'stop', id: 'de-DELFI_de:05111:18235'}, destination: {type: 'stop', id: 'de-DELFI_de:05315:11201'}}).expect(200);
		const l = r.body.journeys[0].legs[0];
		expect(l.departureDelaySeconds).toBeNull();
		expect(l.stopovers[0].arrivalDelaySeconds).toBeNull();
	});

	it('normalisiert Gleisangaben und Liniennamen', async () => {
		const {normTrack, lineName} = await import('../src/lib/mapper.js');
		expect(normTrack('Gl. 1')).toBe('1');
		expect(normTrack('Gleis 17')).toBe('17');
		expect(normTrack('Steig B')).toBe('Steig B');
		expect(normTrack('  ')).toBeNull();
		expect(lineName({displayName: 'RE5 (28517)'})).toBe('RE5');
		expect(lineName({displayName: 'STR 704'})).toBe('STR 704');
		expect(lineName({routeShortName: 'RE5', displayName: 'RE5 (28517)'})).toBe('RE5');
		expect(lineName({routeShortName: '704', displayName: 'STR 704'})).toBe('STR 704');
		expect(normTrack('Glashütte')).toBe('Glashütte');
		expect(normTrack('Gl1')).toBe('1');
		expect(lineName({routeShortName: 'RB48 (17343)'})).toBe('RB48');
		expect(lineName({tripShortName: '17343'})).toBe('17343');
	});

	it('fasst doppelte Haltestellen aus mehreren Datensaetzen zusammen und bevorzugt DELFI', async () => {
		build({
			async geocode() {
				return [
					{type: 'STOP', id: 'at-Railway-Current-Reference-Data-2026_de:05111:18235:93:16', name: 'Düsseldorf Hbf', lat: 51.2199, lon: 6.7944},
					{type: 'STOP', id: 'de-DELFI_de:05111:18235', name: 'Düsseldorf Hbf', lat: 51.2200, lon: 6.7943},
					{type: 'STOP', id: 'de-DELFI_de:05162:20055', name: 'Neuss Hauptbahnhof', lat: 51.2048, lon: 6.6845},
				];
			},
		});
		const r = await request(app).get('/api/locations?query=D%C3%BCsseldorf%20Hbf').set(auth).expect(200);
		expect(r.body.places.map((p) => p.id)).toEqual(['de-DELFI_de:05111:18235', 'de-DELFI_de:05162:20055']);
	});

	it('Gleis aus "Gl. 1" wird zu "1" im Leg', async () => {
		build({async plan() { return {itineraries: [itinerary({legs: [leg({from: {...placeDusHbf, track: 'Gl. 1', scheduledTrack: 'Gl. 1'}, displayName: 'RB48 (17343)'})]})]}; }});
		const r = await request(app).post('/api/routes').set(auth).send({origin: {type: 'stop', id: 'de-DELFI_de:05111:18235'}, destination: {type: 'stop', id: 'de-DELFI_de:05315:11201'}}).expect(200);
		expect(r.body.journeys[0].legs[0]).toMatchObject({departurePlatform: '1', platformChanged: false, line: {name: 'RB48', fahrtNr: '10123'}});
	});
});

describe('Fixture-Plausibilitaet', () => {
	it('Fixture-Haltestelle hat eine MOTIS-typische ID', () => {
		expect(placeDusHbf.stopId).toMatch(/^de-DELFI_/);
	});
});
