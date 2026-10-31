// Uebersetzt MOTIS-2-Antworten (Transitous) in das schlanke, stabile JSON-Schema fuer die App.
// Das Schema ist in docs/API.md dokumentiert und entspricht den Swift-Codable-Modellen (Meilenstein 2).
import polyline from '@mapbox/polyline';

const round5 = (n) => (typeof n === 'number' && Number.isFinite(n) ? Math.round(n * 1e5) / 1e5 : null);

// MOTIS-Modus -> Modus der App (docs/API.md)
const MODE_MAP = Object.freeze({
	WALK: 'walk',
	TRAM: 'tram',
	SUBWAY: 'subway',
	METRO: 'subway',
	SUBURBAN: 'suburban',
	REGIONAL_RAIL: 'regional',
	REGIONAL_FAST_RAIL: 'regionalExpress',
	RAIL: 'regional',
	BUS: 'bus',
	COACH: 'bus',
	FERRY: 'ferry',
	FUNICULAR: 'funicular',
	CABLE_CAR: 'funicular',
	AERIAL_LIFT: 'aerialLift',
	AREAL_LIFT: 'aerialLift',
	HIGHSPEED_RAIL: 'nationalExpress',
	LONG_DISTANCE: 'national',
	NIGHT_RAIL: 'national',
	OTHER: 'other',
	ODM: 'onDemand',
	FLEX: 'onDemand',
	RIDE_SHARING: 'other',
	AIRPLANE: 'airplane',
});

export const mapMode = (m) => MODE_MAP[m] ?? 'unknown';

const LONG_DISTANCE_MODES = new Set(['HIGHSPEED_RAIL', 'LONG_DISTANCE', 'NIGHT_RAIL', 'COACH', 'AIRPLANE']);
// Feeds mit generischem GTFS route_type 2 (Bahn) landen in MOTIS als REGIONAL_RAIL, route_type 3 (auch
// Fernbus) als BUS (nigiri src/loader/gtfs/route.cc). Dann entscheiden Zuggattung bzw. Betreiber.
const LONG_DISTANCE_NAME = /^(ICE|ICD|IC|EC|ECE|EN|NJ|RJX?|TGV|FLX|THA|EST|WB)\b/i;
const LONG_DISTANCE_AGENCY = /\b(flix\s?(bus|train)?|blablacar|eurolines|pinkbus|regiojet)\b/i;

const seconds = (a, b) => {
	if (!a || !b) return null;
	const d = Math.round((Date.parse(a) - Date.parse(b)) / 1000);
	return Number.isFinite(d) ? d : null;
};

// Manche Feeds schreiben "Gl. 1" oder "Gleis 1" in das Gleisfeld; die App erwartet die reine Angabe ("1").
export function normTrack(t) {
	if (typeof t !== 'string') return null;
	// Nur "Gleis", "Gl." oder "Gl" vor Leerzeichen/Ziffer entfernen (nicht "Glashuette").
	const v = t.trim().replace(/^(gleis\b|gl\.|gl(?=\s|\d))\s*/i, '').trim();
	return v.length ? v : null;
}

// Transitous haengt die Zugnummer an den Anzeigenamen ("RE5 (28517)"); die Nummer steht separat in fahrtNr.
const stripTripNo = (s) => (typeof s === 'string' ? s.replace(/\s*\(\d+\)\s*$/, '').trim() : '');
// displayName zuerst: routeShortName ist (MOTIS API >= v4) der rohe GTFS-Kurzname ohne Gattung ("704" statt "STR 704").
export function lineName(leg) {
	return stripTripNo(leg.displayName) || stripTripNo(leg.routeShortName) || leg.tripShortName || null;
}

const hexColor = (c) => (typeof c === 'string' && /^[0-9a-f]{6}$/i.test(c) ? `#${c.toUpperCase()}` : null);

export function mapPlace(p) {
	if (!p) return null;
	const isStop = typeof p.stopId === 'string' && p.stopId.length > 0;
	const out = {
		kind: isStop ? 'stop' : 'coordinate',
		id: isStop ? p.stopId : null,
		name: isStop ? (p.name ?? null) : null, // Koordinaten-Endpunkte haben keinen Namen; die App kennt ihn lokal
		latitude: round5(p.lat),
		longitude: round5(p.lon),
	};
	if (Array.isArray(p.modes) && p.modes.length) out.modes = [...new Set(p.modes.map(mapMode))];
	return out;
}

// Geocode-Treffer (Match) -> Place
export function mapMatch(m) {
	return {
		kind: 'stop',
		id: m.id,
		name: m.name,
		latitude: round5(m.lat),
		longitude: round5(m.lon),
		...(Array.isArray(m.modes) && m.modes.length ? {modes: [...new Set(m.modes.map(mapMode))]} : {}),
		...(Array.isArray(m.areas) && m.areas.length ? {area: m.areas.find((a) => a.default)?.name ?? m.areas[m.areas.length - 1]?.name ?? null} : {}),
	};
}

const GTFS_ENUM = /^[A-Z_]{1,40}$/;
const gtfsEnum = (v) => (typeof v === 'string' && GTFS_ENUM.test(v) ? v : null);

function mapAlerts(alerts) {
	if (!Array.isArray(alerts)) return [];
	return alerts
		.filter((a) => a && (a.headerText || a.descriptionText))
		.map((a) => ({
			type: a.severityLevel === 'SEVERE' || a.severityLevel === 'WARNING' ? 'warning' : 'hint',
			code: (typeof a.code === 'string' ? a.code.slice(0, 64) : null) ?? gtfsEnum(a.effect),
			summary: a.headerText || null,
			text: a.descriptionText || a.headerText,
			cause: gtfsEnum(a.cause),
			effect: gtfsEnum(a.effect),
		}));
}

// MOTIS-Richtung (HARD_LEFT) -> App-Richtung (hardLeft), siehe docs/API.md Step
const DIRECTIONS = new Set(['DEPART', 'CONTINUE', 'LEFT', 'SLIGHTLY_LEFT', 'HARD_LEFT', 'RIGHT', 'SLIGHTLY_RIGHT', 'HARD_RIGHT',
	'UTURN_LEFT', 'UTURN_RIGHT', 'CIRCLE_CLOCKWISE', 'CIRCLE_COUNTERCLOCKWISE', 'STAIRS', 'ELEVATOR']);
const camel = (s) => s.toLowerCase().replace(/_([a-z])/g, (_, c) => c.toUpperCase());
const level = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);

const MAX_STEPS = 60; // begrenzt die Antwortgroesse; laengere Wege sind fuer die Bahnhofsfuehrung irrelevant

export function mapSteps(steps) {
	if (!Array.isArray(steps)) return [];
	return steps
		.filter((s) => s && typeof s === 'object')
		.map((s) => ({
			direction: DIRECTIONS.has(s.relativeDirection) ? camel(s.relativeDirection) : 'unknown',
			distanceMeters: typeof s.distance === 'number' && Number.isFinite(s.distance) ? Math.round(s.distance) : null,
			fromLevel: level(s.fromLevel),
			toLevel: level(s.toLevel),
			streetName: typeof s.streetName === 'string' && s.streetName.trim() ? s.streetName.trim().slice(0, 120) : null,
		}))
		.filter((s) => s.direction !== 'unknown' || s.distanceMeters !== null)
		.slice(0, MAX_STEPS);
}

// Schienenersatzverkehr: GTFS route_type 714 (Rail Replacement Bus) oder Kennzeichnung im Namen.
// Nicht "Ersatzzug" (Schiene) und nicht "Ersatzhaltestelle".
const REPLACEMENT_NAME = /\bSEV(?=\b|\d)|ersatzverkehr|\bersatzbus/i;
export function isReplacement(leg) {
	if (leg.routeType === 714) return true;
	return [leg.displayName, leg.routeShortName, leg.routeLongName, leg.category?.name, leg.category?.shortName]
		.some((s) => typeof s === 'string' && REPLACEMENT_NAME.test(s));
}

// Encoded Polyline (Praezision aus der Antwort) -> GeoJSON LineString [[lon, lat], ...]
export function mapPolyline(geom) {
	if (!geom || typeof geom.points !== 'string' || geom.points.length === 0) return null;
	let pts;
	try {
		pts = polyline.decode(geom.points, Number.isInteger(geom.precision) ? geom.precision : 5);
	} catch {
		return null;
	}
	const coords = [];
	for (const [lat, lon] of pts) {
		const p = [round5(lon), round5(lat)];
		const last = coords[coords.length - 1];
		if (p[0] === null || p[1] === null) continue;
		if (!last || last[0] !== p[0] || last[1] !== p[1]) coords.push(p);
	}
	return coords.length >= 2 ? {type: 'LineString', coordinates: coords} : null;
}

function mapStopover(p, realtime) {
	return {
		stop: mapPlace(p),
		arrival: p.arrival ?? null,
		plannedArrival: p.scheduledArrival ?? null,
		arrivalDelaySeconds: realtime ? seconds(p.arrival, p.scheduledArrival) : null,
		departure: p.departure ?? null,
		plannedDeparture: p.scheduledDeparture ?? null,
		departureDelaySeconds: realtime ? seconds(p.departure, p.scheduledDeparture) : null,
		platform: normTrack(p.track),
		plannedPlatform: normTrack(p.scheduledTrack),
		cancelled: p.cancelled === true,
	};
}

export function mapLeg(leg, index, {withPolylines = true} = {}) {
	const mode = mapMode(leg.mode);
	const realtime = leg.realTime === true;
	const base = {
		index,
		mode,
		origin: mapPlace(leg.from),
		destination: mapPlace(leg.to),
		departure: leg.startTime ?? null,
		plannedDeparture: leg.scheduledStartTime ?? null,
		departureDelaySeconds: realtime ? seconds(leg.startTime, leg.scheduledStartTime) : null,
		arrival: leg.endTime ?? null,
		plannedArrival: leg.scheduledEndTime ?? null,
		arrivalDelaySeconds: realtime ? seconds(leg.endTime, leg.scheduledEndTime) : null,
		durationSeconds: typeof leg.duration === 'number' ? leg.duration : null,
		realtime,
		cancelled: leg.cancelled === true || leg.from?.cancelled === true || leg.to?.cancelled === true,
		polyline: withPolylines ? mapPolyline(leg.legGeometry) : null,
	};

	if (mode === 'walk') {
		return {
			...base,
			isTransfer: false, // wird in mapJourney gesetzt
			distanceMeters: typeof leg.distance === 'number' ? Math.round(leg.distance) : null,
			// Fussgaenger-Routing von MOTIS (OSM). Die App ersetzt die Dauer durch MKDirections x WalkingPaceFactor.
			durationSource: 'motis-osm',
			// Wegfuehrung braucht die App nur einmal; Refresh ohne Polylines (Polling) laesst sie weg.
			steps: withPolylines ? mapSteps(leg.steps) : [],
		};
	}

	const depPlatform = normTrack(leg.from?.track);
	const depPlanned = normTrack(leg.from?.scheduledTrack);
	const arrPlatform = normTrack(leg.to?.track);
	const arrPlanned = normTrack(leg.to?.scheduledTrack);
	return {
		...base,
		line: {
			name: lineName(leg),
			productName: leg.category?.shortName ?? null,
			fahrtNr: leg.tripShortName ?? null,
			operator: leg.agencyName ?? null,
			color: hexColor(leg.routeColor),
			textColor: hexColor(leg.routeTextColor),
		},
		direction: leg.headsign ?? leg.tripTo?.name ?? null,
		tripId: leg.tripId ?? null,
		departurePlatform: depPlatform,
		plannedDeparturePlatform: depPlanned,
		arrivalPlatform: arrPlatform,
		plannedArrivalPlatform: arrPlanned,
		platformChanged: Boolean((depPlatform && depPlanned && depPlatform !== depPlanned) || (arrPlatform && arrPlanned && arrPlatform !== arrPlanned)),
		replacement: isReplacement(leg),
		// Fehlendes Feld = unbekannt, nie als barrierefrei werten
		wheelchairAccessible: leg.wheelchairAccessible === 'ACCESSIBLE' ? 'yes' : leg.wheelchairAccessible === 'NOT_ACCESSIBLE' ? 'no' : 'unknown',
		loadFactor: null, // Transitous liefert keine Auslastung
		stopovers: Array.isArray(leg.intermediateStops) ? leg.intermediateStops.map((p) => mapStopover(p, realtime)) : [],
		remarks: mapAlerts([...(leg.alerts ?? []), ...(leg.from?.alerts ?? []), ...(leg.to?.alerts ?? [])]),
	};
}

export function isLongDistanceItinerary(itinerary) {
	return (itinerary.legs ?? []).some((l) => LONG_DISTANCE_MODES.has(l.mode)
		|| (l.mode !== 'WALK' && (
			LONG_DISTANCE_NAME.test(l.routeShortName || l.displayName || l.category?.shortName || '')
			|| LONG_DISTANCE_NAME.test(l.category?.shortName || '')
			|| LONG_DISTANCE_AGENCY.test(l.agencyName || ''))));
}

// MOTIS refresh-itinerary antwortet bei nicht mehr rekonstruierbaren Fahrten NICHT mit 404, sondern mit 200
// und einem Platzhalter-Abschnitt (motis src/itinerary_id.cc make_dummy_leg): cancelled, ohne tripId, ohne
// Echtzeit, ohne Haltestellennamen, mit einem einzigen Alert, dessen headerText ein interner Fehlertext ist.
// Gilt auch fuer Fussweg-Platzhalter ("no offset found", itinerary_id.cc), daher keine Modus-Einschraenkung.
export function hasReconstructionFailure(itinerary) {
	return (itinerary?.legs ?? []).some((l) => l.cancelled === true && l.realTime === false && !l.tripId
		&& !l.from?.name && !l.to?.name
		&& Array.isArray(l.alerts) && l.alerts.length === 1
		&& !l.alerts[0].descriptionText && !l.alerts[0].severityLevel && !l.alerts[0].effect);
}

export function mapJourney(itinerary, opts) {
	const legs = (itinerary.legs ?? []).map((l, i) => mapLeg(l, i, opts));
	// Jeder Fussweg zwischen zwei Fahrzeugen ist fachlich ein Umstieg (SPEZIFIKATION 4.2 transferRouting).
	for (let i = 1; i < legs.length - 1; i++) {
		if (legs[i].mode === 'walk' && legs[i - 1].mode !== 'walk' && legs[i + 1].mode !== 'walk') legs[i].isTransfer = true;
	}
	const transitLegs = legs.filter((l) => l.mode !== 'walk');
	// Haltestellenbezogene Meldungen erscheinen oft an mehreren Legs; auf Journey-Ebene einmalig sammeln.
	const seen = new Set();
	const remarks = [];
	for (const r of transitLegs.flatMap((l) => l.remarks)) {
		const k = `${r.summary}|${r.text}`;
		if (!seen.has(k)) { seen.add(k); remarks.push(r); }
	}
	return {
		refreshToken: itinerary.id ?? null,
		departure: itinerary.startTime ?? legs[0]?.departure ?? null,
		arrival: itinerary.endTime ?? legs[legs.length - 1]?.arrival ?? null,
		durationSeconds: typeof itinerary.duration === 'number' ? itinerary.duration : null,
		transfers: typeof itinerary.transfers === 'number' ? itinerary.transfers : Math.max(0, transitLegs.length - 1),
		modes: [...new Set(transitLegs.map((l) => l.mode))],
		cancelled: legs.some((l) => l.cancelled),
		realtime: transitLegs.some((l) => l.realtime),
		hasPolylines: transitLegs.length > 0 && transitLegs.every((l) => l.polyline !== null),
		legs,
		remarks,
	};
}
