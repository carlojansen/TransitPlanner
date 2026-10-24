// Live-Test gegen Transitous. Lokal im macOS-Terminal ausfuehren: npm run smoke
// Benoetigt .env (USER_AGENT, API_TOKEN). Startet keinen Server, sondern ruft den Service direkt.
// Bewusst sparsam: 4 Anfragen insgesamt (Transitous wird ehrenamtlich betrieben).
import {loadConfig} from '../src/config.js';
import {createMotisClient} from '../src/services/motisClient.js';
import {createTransitService} from '../src/services/transitService.js';
import {createUpstreamGate} from '../src/lib/upstreamGate.js';

const config = loadConfig();
const client = createMotisClient({baseUrl: config.MOTIS_BASE_URL, userAgent: config.USER_AGENT});
const gate = createUpstreamGate({limit: config.UPSTREAM_LIMIT, intervalMs: config.UPSTREAM_INTERVAL_MS});
const service = createTransitService({client, gate, timeoutMs: config.UPSTREAM_TIMEOUT_MS});

console.log(`Upstream: ${config.MOTIS_BASE_URL}  User-Agent: ${config.USER_AGENT}\n`);

const step = async (label, fn) => {
	const t = Date.now();
	try {
		const out = await fn();
		console.log(`OK    ${label} (${Date.now() - t} ms)`);
		return out;
	} catch (err) {
		const status = err.cause?.response?.status ? ` HTTP ${err.cause.response.status}` : '';
		console.log(`FAIL  ${label}: ${err.code ?? err.name}${status} ${err.cause?.message ?? err.message}`);
		process.exitCode = 1;
		return null;
	}
};

const time = (iso) => (iso ? new Date(iso).toLocaleTimeString('de-DE', {hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Berlin'}) : '--:--');

const search = await step('Haltestellensuche "Düsseldorf Hbf"', () => service.locations({query: 'Düsseldorf Hbf'}));
if (search) console.log('      ->', search.places.slice(0, 3).map((p) => `${p.name} [${p.id}]`).join(' | '));

const near = await step('Umkreis 500 m um Düsseldorf Hbf', () => service.locations({lat: 51.2199, lon: 6.7943}));
if (near) console.log('      ->', near.places.slice(0, 4).map((p) => `${p.name} (${p.distanceMeters} m)`).join(' | '));

const from = search?.places.find((p) => /Düsseldorf Hbf/.test(p.name));
const routes = await step('Route Düsseldorf Hbf -> Köln Hbf (nur Nahverkehr)', () => service.routes({
	origin: from ? {type: 'stop', id: from.id} : {type: 'coordinate', latitude: 51.21996, longitude: 6.79432},
	destination: {type: 'coordinate', latitude: 50.94282, longitude: 6.95873},
	isArrivalTime: false, onlyNahverkehr: true, results: 3,
}));
if (routes) {
	for (const j of routes.journeys) {
		const lines = j.legs.filter((l) => l.mode !== 'walk').map((l) => {
			const d = l.departureDelaySeconds ? ` +${Math.round(l.departureDelaySeconds / 60)}` : '';
			return `${l.line.name ?? l.mode}${d}${l.departurePlatform ? ` Gl. ${l.departurePlatform}` : ''}`;
		}).join(' > ');
		console.log(`      -> ${time(j.departure)}-${time(j.arrival)}  ${lines}  | ${Math.round(j.durationSeconds / 60)} min, Echtzeit: ${j.realtime}, Polylines: ${j.hasPolylines}`);
	}
	const fern = routes.journeys.filter((j) => j.modes.some((m) => m === 'national' || m === 'nationalExpress'));
	console.log(fern.length ? 'FAIL  Fernverkehr trotz Filter enthalten!' : 'OK    kein Fernverkehr im Ergebnis');
	if (fern.length) process.exitCode = 1;
	const token = routes.journeys[0]?.refreshToken;
	if (token) {
		const r = await step('Refresh der ersten Verbindung', () => service.refresh({refreshToken: token, polylines: false}));
		if (r) console.log(`      -> ${time(r.journey.departure)}-${time(r.journey.arrival)}, ${r.journey.legs.length} Abschnitte`);
	}
}
if (routes?.removedLongDistance) console.log(`      (${routes.removedLongDistance} Verbindung(en) mit Fernverkehr herausgefiltert)`);
console.log(`\nQuellenangabe fuer die App: ${(routes?.attribution?.links ?? []).map((l) => l.url).join(' | ')}`);
