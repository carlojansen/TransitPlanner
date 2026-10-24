import {Router} from 'express';
import {TransitError, ErrorCode} from '../lib/errors.js';
import {locationsQuery, routesBody, refreshBody} from './schemas.js';

function parse(schema, input) {
	const r = schema.safeParse(input);
	if (!r.success) {
		// Nur Feldpfad + Meldung zurueckgeben, nie die Eingabewerte selbst.
		const details = r.error.issues.map((i) => (i.path.length ? `${i.path.join('.')}: ${i.message}` : i.message));
		throw new TransitError(ErrorCode.INVALID_REQUEST, {details});
	}
	return r.data;
}

export function apiRouter(service) {
	const router = Router();

	router.get('/locations', async (req, res) => {
		const q = parse(locationsQuery, req.query);
		res.json(await service.locations(q));
	});

	router.post('/routes', async (req, res) => {
		const body = parse(routesBody, req.body);
		res.json(await service.routes(body));
	});

	router.post('/refresh', async (req, res) => {
		const body = parse(refreshBody, req.body);
		res.json(await service.refresh(body));
	});

	return router;
}
