import {createHash, timingSafeEqual} from 'node:crypto';
import {rateLimit} from 'express-rate-limit';
import {TransitError, ErrorCode} from '../lib/errors.js';

const sha256 = (s) => createHash('sha256').update(s, 'utf8').digest();

// Bearer-Auth mit konstanter Laufzeit (Hash-Vergleich verhindert Laengen-Leaks).
// Akzeptiert ein Token oder eine Liste; es wird immer gegen ALLE Eintraege verglichen (kein frueher Abbruch).
export function requireBearer(expected) {
	const hashes = [expected].flat().map(sha256);
	return (req, _res, next) => {
		const header = req.get('authorization') ?? '';
		const match = /^Bearer ([\x21-\x7E]{1,512})$/i.exec(header);
		const given = sha256(match?.[1] ?? '');
		let ok = false;
		for (const h of hashes) ok = timingSafeEqual(given, h) || ok;
		if (!match || !ok) return next(new TransitError(ErrorCode.UNAUTHORIZED));
		return next();
	};
}

export function apiRateLimit(perMinute, prefix = 'api', {global = false} = {}) {
	return rateLimit({
		windowMs: 60_000,
		limit: perMinute,
		identifier: prefix,
		// global: ein gemeinsamer Zaehler fuer alle Clients statt pro IP
		...(global ? {keyGenerator: () => `global:${prefix}`} : {}),
		// Keine RateLimit-Header: draft-8 enthaelt einen gekuerzten, ungesalzenen Hash der Client-IP (Caddy-Log).
		standardHeaders: false,
		legacyHeaders: false,
		handler: (_req, _res, next) => next(new TransitError(ErrorCode.RATE_LIMITED, {retryAfterSeconds: 60})),
	});
}

// Keine Antwort darf in Zwischen-Caches landen (Standortbezug).
export function noStore(_req, res, next) {
	res.set('Cache-Control', 'no-store');
	res.set('Pragma', 'no-cache');
	next();
}
