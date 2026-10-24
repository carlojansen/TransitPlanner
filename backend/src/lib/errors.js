// Typisierte Fehler. Die Codes sind 1:1 auf das iOS-Enum `TransitError` abgebildet
// (siehe docs/API.md), damit die App ruhige Inline-Banner statt Alerts zeigen kann.

export const ErrorCode = Object.freeze({
	INVALID_REQUEST: 'INVALID_REQUEST',
	UNAUTHORIZED: 'UNAUTHORIZED',
	NOT_FOUND: 'NOT_FOUND',
	RATE_LIMITED: 'RATE_LIMITED',
	REFRESH_EXPIRED: 'REFRESH_EXPIRED',
	NO_CONNECTIONS: 'NO_CONNECTIONS',
	UPSTREAM_UNAVAILABLE: 'UPSTREAM_UNAVAILABLE',
	UPSTREAM_TIMEOUT: 'UPSTREAM_TIMEOUT',
	INTERNAL: 'INTERNAL',
});

const STATUS = {
	INVALID_REQUEST: 400,
	UNAUTHORIZED: 401,
	NOT_FOUND: 404,
	RATE_LIMITED: 429,
	REFRESH_EXPIRED: 410,
	NO_CONNECTIONS: 404,
	UPSTREAM_UNAVAILABLE: 502,
	UPSTREAM_TIMEOUT: 504,
	INTERNAL: 500,
};

// Nachrichten sind bewusst generisch: keine Stacktraces, keine Upstream-Details, keine Eingabedaten.
const MESSAGES = {
	INVALID_REQUEST: 'Die Anfrage ist ungueltig.',
	UNAUTHORIZED: 'Nicht autorisiert.',
	NOT_FOUND: 'Nicht gefunden.',
	RATE_LIMITED: 'Zu viele Anfragen. Bitte kurz warten.',
	REFRESH_EXPIRED: 'Die Verbindung ist nicht mehr aktuell. Bitte neu suchen.',
	NO_CONNECTIONS: 'Keine passende Verbindung gefunden.',
	UPSTREAM_UNAVAILABLE: 'Fahrplandaten sind gerade nicht erreichbar.',
	UPSTREAM_TIMEOUT: 'Fahrplandaten antworten zu langsam.',
	INTERNAL: 'Interner Fehler.',
};

export class TransitError extends Error {
	constructor(code, {details, cause, retryAfterSeconds} = {}) {
		super(MESSAGES[code] ?? MESSAGES.INTERNAL, {cause});
		this.name = 'TransitError';
		this.code = code in STATUS ? code : ErrorCode.INTERNAL;
		this.status = STATUS[this.code];
		this.details = details;
		this.retryAfterSeconds = retryAfterSeconds;
	}

	toJSON() {
		const body = {code: this.code, message: this.message};
		if (this.details) body.details = this.details;
		if (this.retryAfterSeconds) body.retryAfterSeconds = this.retryAfterSeconds;
		return {error: body};
	}
}

// Uebersetzt Fehler der Upstream-API (MOTIS) in TransitError, ohne Upstream-Interna durchzureichen.
export function mapUpstreamError(err) {
	if (err instanceof TransitError) return err;
	if (err?.name === 'AbortError' || err?.name === 'TimeoutError' || err?.code === 'ETIMEDOUT') {
		return new TransitError(ErrorCode.UPSTREAM_TIMEOUT, {cause: err});
	}
	const status = upstreamStatus(err);
	if (status === 429 || status === 503) {
		const s = Number.isFinite(err?.retryAfterSeconds) && err.retryAfterSeconds > 0 ? Math.min(err.retryAfterSeconds, 300) : 30;
		return new TransitError(ErrorCode.UPSTREAM_UNAVAILABLE, {cause: err, retryAfterSeconds: s});
	}
	if (status === 404 || status === 410) {
		// MOTIS: not_found_exception, z. B. unbekannte Stop-ID (motis src/tag_lookup.cc).
		return new TransitError(ErrorCode.NOT_FOUND, {cause: err});
	}
	if (status === 400 || status === 422) {
		// MOTIS hat die Anfrage fachlich abgelehnt (z. B. kaputte itineraryId, ungueltiger Parameter).
		return new TransitError(ErrorCode.INVALID_REQUEST, {cause: err});
	}
	// Ein TypeError, der kein Netzwerkfehler ist, ist ein Programmierfehler bei uns.
	if (err instanceof TypeError && !isNetworkError(err)) {
		return new TransitError(ErrorCode.INTERNAL, {cause: err});
	}
	// Netzwerkfehler, 5xx, 401/403 (z. B. gesperrt), kaputtes JSON: Upstream-Problem.
	return new TransitError(ErrorCode.UPSTREAM_UNAVAILABLE, {cause: err});
}

export function upstreamStatus(err) {
	const s = err?.response?.status ?? err?.statusCode;
	return typeof s === 'number' ? s : undefined;
}

// Eine gemeinsame Liste transienter Netzwerk-Codes (Node-Sockets und undici).
export const TRANSIENT_NETWORK_CODES = new Set([
	'ECONNRESET', 'ECONNREFUSED', 'ENOTFOUND', 'EAI_AGAIN', 'EPIPE', 'EHOSTUNREACH', 'ENETUNREACH', 'ETIMEDOUT',
	'UND_ERR_SOCKET', 'UND_ERR_CONNECT_TIMEOUT', 'UND_ERR_HEADERS_TIMEOUT', 'UND_ERR_BODY_TIMEOUT', 'UND_ERR_CLOSED',
]);

// Natives fetch() (undici): TypeError("fetch failed") beim Verbindungsaufbau, TypeError("terminated")
// bei Abbruch waehrend des Body-Lesens, jeweils mit err.cause.code.
export function isNetworkError(err) {
	const code = err?.cause?.code ?? err?.code;
	if (code && TRANSIENT_NETWORK_CODES.has(code)) return true;
	return err instanceof TypeError && /fetch failed|terminated/i.test(err.message ?? '');
}
