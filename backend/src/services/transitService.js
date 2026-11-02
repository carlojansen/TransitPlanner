// Fachlogik von Meilenstein 1. Unabhaengig von Express, damit sie mit einem Fake-Client testbar ist.
// Datenquelle: MOTIS 2 (Transitous). Zum Wechsel weg von der DB-Navigator-API siehe docs/STATUS.md.
import {createHmac, randomBytes} from 'node:crypto';
import {TransitError, ErrorCode, mapUpstreamError, upstreamStatus} from '../lib/errors.js';
import {createUpstreamGate} from '../lib/upstreamGate.js';
import {mapPlace, mapMatch, mapJourney, isLongDistanceItinerary, hasReconstructionFailure} from '../lib/mapper.js';
import {fuzz} from '../lib/privacy.js';
import {TTLCache} from '../lib/ttlCache.js';
import {joinList} from './motisClient.js';

// Nahverkehr + Regionalverkehr (SPEZIFIKATION 7). Bewusst NICHT "RAIL": das schliesst in MOTIS
// Hochgeschwindigkeits- und Fernverkehr mit ein (motis/src/timetable/modes_to_clasz_mask.cc).
// REGIONAL_RAIL deckt RE/RB/IRE ab, SUBURBAN auch METRO. OTHER enthaelt Sonderformen wie die Schwebebahn.
// Bewusst NICHT ODM (Rufbus/AST): erfordert Voranmeldung, fuer Live-Navigation ungeeignet.
export const NAHVERKEHR_MODES = Object.freeze([
	'TRAM', 'SUBWAY', 'SUBURBAN', 'REGIONAL_RAIL', 'BUS', 'FERRY', 'FUNICULAR', 'AERIAL_LIFT', 'OTHER',
]);

// Pillen der App -> MOTIS-Modi.
const PILL_MODES = Object.freeze({tram: 'TRAM', subway: 'SUBWAY', suburban: 'SUBURBAN', regional: 'REGIONAL_RAIL', bus: 'BUS'});

const NEARBY_RADIUS_M = 500;
// Transitous-Nutzungsregel: Link auf die Quellen sichtbar anzeigen; dazu OSM-Namensnennung.
const ATTRIBUTION = Object.freeze({
	text: 'Fahrplandaten: Transitous und Datenquellen. Wege- und Kartendaten: © OpenStreetMap-Mitwirkende.',
	links: Object.freeze([
		Object.freeze({label: 'Transitous-Datenquellen', url: 'https://transitous.org/sources/'}),
		Object.freeze({label: 'OpenStreetMap', url: 'https://www.openstreetmap.org/copyright'}),
	]),
});

// Unerwartete Antwortform: Upstream-Problem, und nichts davon wird gecacht.
function shapeError() {
	return new TransitError(ErrorCode.UPSTREAM_UNAVAILABLE);
}

function haversineMeters(aLat, aLon, bLat, bLon) {
	const toRad = (d) => (d * Math.PI) / 180;
	const dLat = toRad(bLat - aLat);
	const dLon = toRad(bLon - aLon);
	const h = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(aLat)) * Math.cos(toRad(bLat)) * Math.sin(dLon / 2) ** 2;
	return 2 * 6_371_000 * Math.asin(Math.sqrt(h));
}

// Transitous fuehrt dieselbe Haltestelle teils aus mehreren Datensaetzen (z. B. DELFI und ein
// oesterreichischer Bahn-Datensatz auf Bahnsteig-Ebene). Gleicher Name in < 300 m = Duplikat;
// die DELFI-ID wird bevorzugt (stabiler fuer Favoriten), sonst der erste Treffer.
const PREFERRED_ID = /^de-DELFI_/;
export function dedupeStops(places) {
	const out = [];
	for (const p of places) {
		const dup = out.findIndex((q) => q.name.toLocaleLowerCase('de-DE') === p.name.toLocaleLowerCase('de-DE')
			&& typeof q.latitude === 'number' && typeof p.latitude === 'number'
			&& haversineMeters(q.latitude, q.longitude, p.latitude, p.longitude) < 300);
		if (dup === -1) out.push(p);
		else if (!PREFERRED_ID.test(out[dup].id) && PREFERRED_ID.test(p.id)) out[dup] = p;
	}
	return out;
}

// Cache-Schluessel ohne Klartext von Suchtext oder Koordinaten im Speicher: HMAC mit pro Prozess
// zufaelligem Schluessel (nicht rueckrechenbar, auch nicht per Woerterbuch/Koordinatenraster).
const cacheSecret = randomBytes(32);
const hashKey = (s) => createHmac('sha256', cacheSecret).update(s, 'utf8').digest('base64url');

// App-Endpunkt -> MOTIS fromPlace/toPlace ("lat,lon" oder Stop-ID).
// Adressen gehen nur als Koordinate raus, nie mit Namen (Zero-Knowledge), gerundet auf 4 Stellen (~11 m):
// genug fuer den Fussweg zur Haltestelle, aber keine metergenaue Hausposition.
function toMotisPlace(point) {
	if (point.type === 'stop') return point.id;
	return `${fuzz(point.latitude, 4)},${fuzz(point.longitude, 4)}`;
}

export function createTransitService({client, gate = createUpstreamGate(), timeoutMs = 12_000, logger, routing = {}}) {
	const searchCache = new TTLCache({maxEntries: 1000, ttlMs: 6 * 60 * 60 * 1000}); // Haltestellennamen aendern sich selten
	const nearbyCache = new TTLCache({maxEntries: 1000, ttlMs: 10 * 60 * 1000});

	async function call(fn, {budgetMs = timeoutMs} = {}) {
		try {
			return await gate.run(fn, {timeoutMs: budgetMs});
		} catch (err) {
			const mapped = mapUpstreamError(err);
			// Nur Fehlerklasse loggen, niemals Eingaben oder Upstream-Payloads.
			logger?.warn({code: mapped.code, upstream: err?.name ?? 'Error', status: upstreamStatus(err)}, 'upstream error');
			throw mapped;
		}
	}

	// GET /api/locations
	async function locations({query, lat, lon}) {
		const hasCoord = typeof lat === 'number' && typeof lon === 'number';
		// Coordinate Fuzzing (AGENT.md 3.1.3). Die App rundet bereits; wir runden defensiv erneut.
		const fLat = hasCoord ? fuzz(lat, 3) : null;
		const fLon = hasCoord ? fuzz(lon, 3) : null;

		if (query) {
			const key = hashKey(query.toLocaleLowerCase('de-DE'));
			let matches = searchCache.get(key);
			if (!matches) {
				// Nur Haltestellen: Adressen loest die App lokal per MKLocalSearch auf (AGENT.md 3.1.1, 3.2.4).
				// Kein Standort-Bias an Transitous; die Naehe-Sortierung passiert hier lokal.
				matches = await call((signal) => client.geocode({text: query, type: joinList(['STOP']), numResults: 10, language: 'de'}, signal));
				if (!Array.isArray(matches)) throw shapeError();
				searchCache.set(key, matches);
			}
			let places = dedupeStops(matches
				.filter((m) => m && m.type === 'STOP' && m.id && m.name)
				.map(mapMatch));
			if (hasCoord) {
				places = places
					.map((p) => (typeof p.latitude === 'number'
						? {...p, distanceMeters: Math.round(haversineMeters(fLat, fLon, p.latitude, p.longitude))}
						: p))
					.sort((a, b) => (a.distanceMeters ?? Infinity) - (b.distanceMeters ?? Infinity));
			}
			return {places, attribution: ATTRIBUTION};
		}

		if (!hasCoord) throw new TransitError(ErrorCode.INVALID_REQUEST, {details: ['query oder lat/lon erforderlich']});

		const key = hashKey(`${fLat},${fLon}`);
		let places = nearbyCache.get(key);
		if (!places) {
			// MOTIS hat keinen Umkreis-Endpunkt: Haltestellen im umschliessenden Rechteck holen, lokal auf den Radius filtern.
			const dLat = NEARBY_RADIUS_M / 111_320;
			const dLon = NEARBY_RADIUS_M / (111_320 * Math.cos((fLat * Math.PI) / 180));
			const min = `${fuzz(fLat - dLat, 5)},${fuzz(fLon - dLon, 5)}`;
			const max = `${fuzz(fLat + dLat, 5)},${fuzz(fLon + dLon, 5)}`;
			const raw = await call((signal) => client.stops({min, max, grouped: true, language: 'de'}, signal));
			if (!Array.isArray(raw)) throw shapeError();
			places = raw
				.map(mapPlace)
				.filter((p) => p && p.kind === 'stop' && p.name && typeof p.latitude === 'number')
				.map((p) => ({...p, distanceMeters: Math.round(haversineMeters(fLat, fLon, p.latitude, p.longitude))}))
				.filter((p) => p.distanceMeters <= NEARBY_RADIUS_M)
				.sort((a, b) => a.distanceMeters - b.distanceMeters)
				.slice(0, 12);
			nearbyCache.set(key, places);
		}
		return {places, attribution: ATTRIBUTION};
	}

	// POST /api/routes
	async function routes({origin, destination, targetTime, isArrivalTime, onlyNahverkehr, modes, accessibility, results, laterThan, earlierThan}) {
		const query = {
			fromPlace: toMotisPlace(origin),
			toPlace: toMotisPlace(destination),
			arriveBy: isArrivalTime,
			numItineraries: results,
			detailedTransfers: true, // Fusswege mit Geometrie fuer die Karte
			joinInterlinedLegs: true,
			language: 'de',
			maxPreTransitTime: routing.maxPreTransitSeconds ?? 900,
			maxPostTransitTime: routing.maxPostTransitSeconds ?? 900,
			additionalTransferTime: routing.additionalTransferMinutes ?? 0,
		};
		if (accessibility === 'stepFree') query.pedestrianProfile = 'WHEELCHAIR';
		if (targetTime) query.time = new Date(targetTime).toISOString();
		if (modes?.length) query.transitModes = joinList([...new Set(modes.map((m) => PILL_MODES[m]))]);
		else if (onlyNahverkehr) query.transitModes = joinList(NAHVERKEHR_MODES);
		// Paging: MOTIS verlangt dieselben Parameter plus Cursor.
		const cursor = laterThan ?? earlierThan;
		if (cursor) query.pageCursor = cursor;

		const fetchPlan = async (q) => {
			const r = await call((signal) => client.plan(q, signal));
			if (!r || !Array.isArray(r.itineraries)) throw shapeError();
			return r;
		};
		const filterLongDistance = onlyNahverkehr || modes?.length > 0; // API.md: bei modes bleibt der Fernverkehr-Filter
		const keep = (list) => (filterLongDistance ? list.filter((it) => !isLongDistanceItinerary(it)) : list);

		let res = await fetchPlan(query);
		let itineraries = keep(res.itineraries);
		let removedLongDistance = res.itineraries.length - itineraries.length;
		// Feeds, die Fernverkehr als REGIONAL_RAIL/BUS kodieren, werden erst hier herausgefiltert und koennen
		// echte Nahverkehrsalternativen verdraengt haben. Nur wenn dadurch nichts uebrig bleibt: genau ein
		// zweiter Versuch mit mehr Verbindungen (begrenzte Zusatzlast fuer Transitous).
		if (itineraries.length === 0 && removedLongDistance > 0 && !cursor) {
			res = await fetchPlan({...query, numItineraries: Math.min(results * 3, 12)});
			itineraries = keep(res.itineraries);
			removedLongDistance += res.itineraries.length - itineraries.length;
		}
		itineraries = itineraries.slice(0, results);

		// Bei sehr kurzen Distanzen (Fussweg bis ca. 5 min) rechnet MOTIS gar kein OEV-Routing und liefert
		// nur "direct" (motis src/endpoints/routing.cc). Dann ist Laufen die Antwort.
		let walkOnly = false;
		if (itineraries.length === 0 && Array.isArray(res.direct) && res.direct.length > 0) {
			itineraries = res.direct.slice(0, 1);
			walkOnly = true;
		}
		if (itineraries.length === 0) throw new TransitError(ErrorCode.NO_CONNECTIONS);

		return {
			journeys: itineraries.map((it) => mapJourney(it)),
			walkOnly,
			removedLongDistance,
			earlierRef: walkOnly ? null : (res.previousPageCursor || null),
			laterRef: walkOnly ? null : (res.nextPageCursor || null),
			fetchedAt: new Date().toISOString(),
			attribution: ATTRIBUTION,
		};
	}

	// POST /api/refresh
	async function refresh({refreshToken, polylines, accessibility}) {
		let it;
		try {
			it = await call((signal) => client.refreshItinerary({itineraryId: refreshToken, detailedTransfers: true, joinInterlinedLegs: true, language: 'de',
				...(accessibility === 'stepFree' ? {pedestrianProfile: 'WHEELCHAIR'} : {})}, signal));
		} catch (err) {
			if (err.code === ErrorCode.NOT_FOUND || err.code === ErrorCode.INVALID_REQUEST) {
				throw new TransitError(ErrorCode.REFRESH_EXPIRED, {cause: err});
			}
			throw err;
		}
		if (!it || !Array.isArray(it.legs)) throw shapeError();
		// Nicht mehr rekonstruierbare Fahrt (200 mit Platzhalter-Abschnitt): KEIN Ausfall, sondern abgelaufen.
		// Der interne MOTIS-Fehlertext darf nicht als Meldung beim Nutzer landen.
		if (hasReconstructionFailure(it)) throw new TransitError(ErrorCode.REFRESH_EXPIRED);
		const journey = mapJourney({...it, id: it.id ?? refreshToken}, {withPolylines: polylines});
		return {journey, fetchedAt: new Date().toISOString(), attribution: ATTRIBUTION};
	}

	return {locations, routes, refresh};
}
