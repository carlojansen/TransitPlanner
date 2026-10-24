import express from 'express';
import helmet from 'helmet';
import {TransitError, ErrorCode} from './lib/errors.js';
import {apiRouter} from './routes/api.js';
import {requireBearer, apiRateLimit, noStore} from './middleware/security.js';

export function createApp({config, service, logger}) {
	const app = express();
	app.disable('x-powered-by');
	app.set('trust proxy', config.TRUST_PROXY);
	app.set('query parser', 'simple'); // keine verschachtelten Query-Objekte

	// Reine JSON-API fuer eine native App: kein CORS, keine Frames, strikte CSP.
	app.use(helmet({
		contentSecurityPolicy: {directives: {defaultSrc: ["'none'"], frameAncestors: ["'none'"]}},
		crossOriginResourcePolicy: {policy: 'same-origin'},
	}));

	// Zugriffslog ohne Query-String, ohne Body, ohne IP: Pfade und Statuscodes reichen fuer den Betrieb.
	app.use((req, res, next) => {
		const start = process.hrtime.bigint();
		res.on('finish', () => {
			const ms = Number(process.hrtime.bigint() - start) / 1e6;
			logger?.info({method: req.method, path: req.path, status: res.statusCode, ms: Math.round(ms)}, 'request');
		});
		next();
	});

	app.get('/healthz', (_req, res) => res.json({status: 'ok'}));

	// Reihenfolge ist sicherheitsrelevant: vor der Authentifizierung nur das Limit pro IP.
	app.use('/api',
		noStore,
		apiRateLimit(config.RATE_LIMIT_PER_MINUTE, 'api'),
		requireBearer(config.API_TOKEN),
		express.json({limit: '8kb', strict: true, type: 'application/json'}),
	);

	// Routensuchen sind fuer Transitous die teuersten Anfragen (Nutzungsregel: Routing sparsam einsetzen).
	// Eigenes, GLOBALES Limit (alle Clients zusammen): hoechstens die Haelfte der Upstream-Kapazitaet.
	// Erst NACH requireBearer, sonst koennte jeder ohne Token den gemeinsamen Zaehler leeren und alle aussperren.
	const upstreamPerMinute = Math.floor((60_000 / config.UPSTREAM_INTERVAL_MS) * config.UPSTREAM_LIMIT);
	app.use('/api/routes', apiRateLimit(Math.max(1, Math.floor(upstreamPerMinute / 2)), 'routes', {global: true}));

	app.use('/api', apiRouter(service));

	app.use((_req, _res, next) => next(new TransitError(ErrorCode.NOT_FOUND)));

	// eslint-disable-next-line no-unused-vars
	app.use((err, _req, res, _next) => {
		let e = err;
		if (!(e instanceof TransitError)) {
			if (err?.type === 'entity.parse.failed' || err?.type === 'entity.too.large' || err?.status === 400 || err?.status === 413) {
				e = new TransitError(ErrorCode.INVALID_REQUEST);
			} else {
				logger?.error({err: {name: err?.name, message: err?.message}}, 'unhandled error');
				e = new TransitError(ErrorCode.INTERNAL);
			}
		}
		if (e.retryAfterSeconds) res.set('Retry-After', String(e.retryAfterSeconds));
		res.status(e.status).json(e.toJSON());
	});

	return app;
}
