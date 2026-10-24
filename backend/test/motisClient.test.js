// Prueft die Huelle um den offiziellen MOTIS-Client mit abgefangenem fetch (kein Netzwerk).
import {describe, it, expect} from 'vitest';
import {createMotisClient, joinList} from '../src/services/motisClient.js';

function recordingFetch(status = 200, body = {itineraries: []}) {
	const seen = [];
	const fetchImpl = async (req) => {
		seen.push(req);
		return new Response(JSON.stringify(body), {status, headers: {'content-type': 'application/json'}});
	};
	return {seen, fetchImpl};
}

describe('motisClient', () => {
	it('sendet den User-Agent und nutzt die v6-Endpunkte', async () => {
		const {seen, fetchImpl} = recordingFetch();
		const c = createMotisClient({baseUrl: 'https://api.transitous.org', userAgent: 'TransitPlanner/0.1.0 (a@b.de)', fetchImpl});
		await c.plan({fromPlace: '51.2,6.7', toPlace: 'x', transitModes: joinList(['TRAM', 'BUS'])});
		const url = new URL(seen[0].url);
		expect(url.origin + url.pathname).toBe('https://api.transitous.org/api/v6/plan');
		expect(seen[0].headers.get('user-agent')).toBe('TransitPlanner/0.1.0 (a@b.de)');
		// Kommagetrennt (OpenAPI explode=false), NICHT als wiederholter Parameter
		expect(url.searchParams.getAll('transitModes')).toEqual(['TRAM,BUS']);
	});

	it('wirft bei HTTP-Fehlern einen Error mit Status, ohne den Body weiterzugeben', async () => {
		const {fetchImpl} = recordingFetch(400, {error: 'unknown stop 51.2,6.7 Musterstr'});
		const c = createMotisClient({baseUrl: 'https://api.transitous.org', userAgent: 'T/1.0 (a@b.de)', fetchImpl});
		const err = await c.refreshItinerary({itineraryId: 'x'}).catch((e) => e);
		expect(err.response.status).toBe(400);
		expect(JSON.stringify(err) + err.message).not.toContain('Musterstr');
	});

	it('folgt keinen Weiterleitungen (Koordinaten duerfen nicht an Dritte gehen)', async () => {
		const {seen, fetchImpl} = recordingFetch();
		const c = createMotisClient({baseUrl: 'https://api.transitous.org', userAgent: 'T/1.0 (a@b.de)', fetchImpl});
		await c.plan({fromPlace: '51.2,6.7', toPlace: 'x'});
		expect(seen[0].redirect).toBe('error');
	});

	it('wertet eine HTML-Antwort mit 200 als Upstream-Problem', async () => {
		const fetchImpl = async () => new Response('<html>blocked</html>', {status: 200, headers: {'content-type': 'text/html'}});
		const c = createMotisClient({baseUrl: 'https://api.transitous.org', userAgent: 'T/1.0 (a@b.de)', fetchImpl});
		await expect(c.plan({fromPlace: '1,1', toPlace: '2,2'})).rejects.toMatchObject({name: 'UpstreamShapeError'});
	});

	it('liest Retry-After bei 429', async () => {
		const fetchImpl = async () => new Response('{}', {status: 429, headers: {'content-type': 'application/json', 'retry-after': '45'}});
		const c = createMotisClient({baseUrl: 'https://api.transitous.org', userAgent: 'T/1.0 (a@b.de)', fetchImpl});
		await expect(c.plan({fromPlace: '1,1', toPlace: '2,2'})).rejects.toMatchObject({response: {status: 429}, retryAfterSeconds: 45});
	});

	it('reicht das AbortSignal an fetch durch', async () => {
		const ac = new AbortController();
		let seenSignal;
		const fetchImpl = async (req) => { seenSignal = req.signal; return new Response('[]', {status: 200, headers: {'content-type': 'application/json'}}); };
		const c = createMotisClient({baseUrl: 'https://api.transitous.org', userAgent: 'T/1.0 (a@b.de)', fetchImpl});
		await c.stops({min: '1,1', max: '2,2'}, ac.signal);
		ac.abort();
		expect(seenSignal.aborted).toBe(true);
	});
});
