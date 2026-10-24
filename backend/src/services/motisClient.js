// Duenne Huelle um den offiziellen MOTIS-Client (@motis-project/motis-client, gepinnt auf die
// Version, die Transitous betreibt). Aufgaben:
//  - User-Agent nach Transitous-Nutzungsregel an jede Anfrage haengen
//  - AbortSignal durchreichen, damit Timeouts die Anfrage wirklich abbrechen
//  - Listen-Parameter korrekt serialisieren (siehe joinList)
//  - HTTP-Fehler in Error-Objekte mit response.status uebersetzen; Fehler-Bodies werden verworfen
import {plan, refreshItinerary, geocode, stops} from '@motis-project/motis-client';

// MOTIS erwartet Listen kommagetrennt (OpenAPI: explode=false). Der generierte Client sendet Arrays
// jedoch als wiederholte Parameter (a=1&a=2); der Server wuerde dann nur einen Wert uebernehmen.
export const joinList = (arr) => arr.join(',');

export function createMotisClient({baseUrl, userAgent, fetchImpl}) {
	const headers = {'User-Agent': userAgent, Accept: 'application/json'};

	async function call(endpoint, query, signal) {
		const res = await endpoint({
			baseUrl, headers, query, signal,
			// Keine Weiterleitungen folgen: die Query (Koordinaten) und der User-Agent duerfen nicht
			// an ein anderes Ziel gehen.
			redirect: 'error',
			...(fetchImpl ? {fetch: fetchImpl} : {}),
		});
		if (res.error !== undefined || !res.response?.ok) {
			const err = new Error(`MOTIS HTTP ${res.response?.status ?? 'error'}`);
			err.name = 'UpstreamHttpError';
			// Nur der Status wird weitergegeben, der Body (kann Eingaben spiegeln) nicht.
			err.response = {status: res.response?.status};
			const ra = Number.parseInt(res.response?.headers?.get?.('retry-after') ?? '', 10);
			if (Number.isFinite(ra) && ra > 0) err.retryAfterSeconds = ra;
			throw err;
		}
		// Unerwartete Antwortform (z. B. HTML-Fehlerseite mit 200, leerer Body) ist ein Upstream-Problem.
		const ctype = res.response.headers?.get?.('content-type') ?? '';
		if (!/json/i.test(ctype) || res.data === undefined || res.data === null || typeof res.data !== 'object') {
			const err = new Error('MOTIS unexpected response');
			err.name = 'UpstreamShapeError';
			throw err;
		}
		return res.data;
	}

	return {
		plan: (query, signal) => call(plan, query, signal),
		refreshItinerary: (query, signal) => call(refreshItinerary, query, signal),
		geocode: (query, signal) => call(geocode, query, signal),
		stops: (query, signal) => call(stops, query, signal),
	};
}
