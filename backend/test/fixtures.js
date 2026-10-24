// MOTIS-2-Fixtures (Struktur wie /api/v6/plan, /api/v6/refresh-itinerary, /api/v1/geocode, /api/v6/map/stops).
import polyline from '@mapbox/polyline';

export const placeDusHbf = {
	name: 'Düsseldorf Hbf', stopId: 'de-DELFI_de:05111:18235', lat: 51.219960, lon: 6.794316,
	track: '9', scheduledTrack: '10', modes: ['REGIONAL_RAIL', 'SUBURBAN', 'TRAM'],
};
export const placeKoelnHbf = {name: 'Köln Hbf', stopId: 'de-DELFI_de:05315:11201', lat: 50.942823, lon: 6.958730, track: '4', scheduledTrack: '4'};
const placeStart = {name: 'START', lat: 51.22012, lon: 6.79046};

const enc = (pts, precision = 6) => ({points: polyline.encode(pts, precision), precision, length: pts.length});

export function leg({mode = 'REGIONAL_RAIL', displayName = 'RE 5', from = placeDusHbf, to = placeKoelnHbf, start = '2026-10-24T06:13:00Z', end = '2026-10-24T06:42:00Z', schedStart = '2026-10-24T06:10:00Z', schedEnd = '2026-10-24T06:40:00Z', extra = {}} = {}) {
	return {
		mode, from, to,
		duration: (Date.parse(end) - Date.parse(start)) / 1000,
		startTime: start, endTime: end, scheduledStartTime: schedStart, scheduledEndTime: schedEnd,
		realTime: true, scheduled: true,
		headsign: 'Koblenz Hbf', tripId: 'trip-1', displayName, routeShortName: displayName,
		tripShortName: '10123', agencyName: 'National Express', routeColor: 'e2001a', routeTextColor: 'ffffff',
		category: {id: 'RE', name: 'Regional-Express', shortName: 'RE'},
		intermediateStops: [{name: 'Düsseldorf-Benrath', stopId: 'de-DELFI_x', lat: 51.16, lon: 6.88, arrival: '2026-10-24T06:22:00Z', scheduledArrival: '2026-10-24T06:20:00Z', departure: '2026-10-24T06:23:00Z', scheduledDeparture: '2026-10-24T06:21:00Z', track: '2', scheduledTrack: '2'}],
		legGeometry: enc([[51.21996, 6.794316], [51.21996, 6.794316], [51.1, 6.85], [50.942823, 6.95873]]),
		alerts: [{headerText: 'Gleiswechsel', descriptionText: 'Heute von Gleis 9', severityLevel: 'WARNING'}],
		...extra,
	};
}

export function walk({from = placeStart, to = placeDusHbf, start = '2026-10-24T06:00:00Z', end = '2026-10-24T06:06:00Z', distance = 420.4} = {}) {
	return {
		mode: 'WALK', from, to, duration: (Date.parse(end) - Date.parse(start)) / 1000,
		startTime: start, endTime: end, scheduledStartTime: start, scheduledEndTime: end,
		realTime: false, scheduled: true, distance,
		legGeometry: enc([[from.lat, from.lon], [to.lat, to.lon]]),
	};
}

export function itinerary({id = 'aXRpbi0x', legs} = {}) {
	const l = legs ?? [walk(), leg()];
	return {
		id, legs: l, transfers: Math.max(0, l.filter((x) => x.mode !== 'WALK').length - 1),
		startTime: l[0].startTime, endTime: l[l.length - 1].endTime,
		duration: (Date.parse(l[l.length - 1].endTime) - Date.parse(l[0].startTime)) / 1000,
	};
}

export function createFakeClient(overrides = {}) {
	const calls = [];
	const client = {
		calls,
		async geocode(query) {
			calls.push(['geocode', query]);
			return [
				{type: 'STOP', id: placeKoelnHbf.stopId, name: 'Köln Hbf', lat: placeKoelnHbf.lat, lon: placeKoelnHbf.lon, areas: [], score: 1, tokens: []},
				{type: 'STOP', id: placeDusHbf.stopId, name: 'Düsseldorf Hbf', lat: placeDusHbf.lat, lon: placeDusHbf.lon, areas: [{name: 'Düsseldorf', default: true}], score: 1, tokens: [], modes: ['TRAM', 'REGIONAL_RAIL']},
			];
		},
		async stops(query) {
			calls.push(['stops', query]);
			return [
				{name: 'Düsseldorf Hbf', stopId: placeDusHbf.stopId, lat: 51.2205, lon: 6.7935},
				{name: 'Weit weg', stopId: 'de-far', lat: 51.2300, lon: 6.7935}, // ~1 km, ausserhalb des Radius
				{name: 'Ohne ID', lat: 51.2206, lon: 6.7936},
			];
		},
		async plan(query) {
			calls.push(['plan', query]);
			return {itineraries: [itinerary(), itinerary({id: 'aXRpbi0y'})], previousPageCursor: 'prev', nextPageCursor: 'next', direct: []};
		},
		async refreshItinerary(query) {
			calls.push(['refreshItinerary', query]);
			return itinerary({id: query.itineraryId});
		},
		...overrides,
	};
	return client;
}
