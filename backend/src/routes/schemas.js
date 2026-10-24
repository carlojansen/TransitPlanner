// Strikte Eingabe-Schemata. Unbekannte Felder werden abgelehnt (.strict()), damit die App
// gar nicht erst versehentlich Identitaets- oder Kalenderdaten mitschicken kann (Zero-Knowledge).
import {z} from 'zod';

// Query-Parameter sind Strings. Nur echte Dezimalzahlen zulassen (kein "", kein "0x10", kein "1e3").
const decimal = z.string().regex(/^-?\d{1,3}(\.\d{1,8})?$/, 'Dezimalzahl erwartet').transform(Number);

// Grob Deutschland + Nachbarregionen. Alles ausserhalb ist fuer diesen Planer fachlich sinnlos.
const inServiceArea = (p) => p.latitude >= 45 && p.latitude <= 56.5 && p.longitude >= 4 && p.longitude <= 17.5;

const round5 = (n) => Math.round(n * 1e5) / 1e5;

export const locationsQuery = z.object({
	query: z.string().trim().min(2).max(80).optional(),
	lat: decimal.optional(),
	lon: decimal.optional(),
}).strict()
	.refine((q) => (q.lat === undefined) === (q.lon === undefined), {message: 'lat und lon nur gemeinsam'})
	.refine((q) => q.query || q.lat !== undefined, {message: 'query oder lat/lon erforderlich'})
	.refine((q) => q.lat === undefined || inServiceArea({latitude: q.lat, longitude: q.lon}), {message: 'Koordinate ausserhalb des Bediengebiets'});

// MOTIS-Stop-IDs sind opake Strings (z. B. "de-DELFI_de:05111:18235"). Kein Komma (MOTIS deutet
// "a,b" als Koordinate), keine Leer- oder Steuerzeichen.
const stopPoint = z.object({
	type: z.literal('stop'),
	id: z.string().regex(/^[\x21-\x2B\x2D-\x7E]{1,160}$/, 'Stop-ID erwartet'),
}).strict();

const coordPoint = z.object({
	type: z.literal('coordinate'),
	latitude: z.number().min(-90).max(90),
	longitude: z.number().min(-180).max(180),
}).strict().refine(inServiceArea, {message: 'Koordinate ausserhalb des Bediengebiets'});

const point = z.discriminatedUnion('type', [stopPoint, coordPoint]);

const sameDbPoint = (a, b) => (a.type === 'stop' && b.type === 'stop' && a.id === b.id)
	|| (a.type === 'coordinate' && b.type === 'coordinate'
		&& round5(a.latitude) === round5(b.latitude) && round5(a.longitude) === round5(b.longitude));

// Opake Upstream-Werte (itineraryId = Base64, Paging-Cursor): Laenge und Zeichensatz begrenzen, Inhalt nicht interpretieren.
const opaque = z.string().min(1).max(6000).regex(/^[\x21-\x7E]+$/, 'ungueltige Zeichen');

export const routesBody = z.object({
	origin: point,
	destination: point,
	// ISO-8601 mit Zeitzonen-Offset, z. B. 2026-10-24T08:15:00+02:00
	targetTime: z.iso.datetime({offset: true}).optional(),
	isArrivalTime: z.boolean().default(false),
	onlyNahverkehr: z.boolean().default(true),
	results: z.number().int().min(1).max(6).default(4),
	// Paging: Wert aus earlierRef/laterRef einer vorherigen Antwort. MOTIS verlangt dazu dieselben
	// uebrigen Parameter wie bei der Ursprungsanfrage (inkl. targetTime).
	laterThan: opaque.optional(),
	earlierThan: opaque.optional(),
}).strict()
	.refine((b) => !sameDbPoint(b.origin, b.destination), {message: 'Start und Ziel sind identisch'})
	.refine((b) => !(b.laterThan && b.earlierThan), {message: 'laterThan und earlierThan schliessen sich aus'})
	.refine((b) => {
		if (!b.targetTime) return true;
		const t = Date.parse(b.targetTime);
		const now = Date.now();
		return t > now - 6 * 3600_000 && t < now + 60 * 24 * 3600_000;
	}, {message: 'targetTime ausserhalb des erlaubten Fensters'});

export const refreshBody = z.object({
	refreshToken: opaque.refine((t) => t.length >= 8, {message: 'zu kurz'}),
	polylines: z.boolean().default(false),
}).strict();
