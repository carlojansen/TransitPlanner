// Zentrale, validierte Konfiguration. Alle Werte kommen aus Umgebungsvariablen.
// Fehlende Pflichtwerte brechen den Start ab (fail fast), statt mit unsicheren Defaults zu laufen.
import {z} from 'zod';

// Transitous-Nutzungsregeln (https://transitous.org/api/): Staging- und interne Server-Endpunkte
// duerfen von Anwendungen nicht genutzt werden.
const FORBIDDEN_MOTIS_HOSTS = [/^staging\.api\.transitous\.org$/i, /(^|\.)motis-project\.(org|de)$/i, /(^|\.)spline\.de$/i];

// Token: 32-512 Zeichen, nur druckbares ASCII ohne Leerzeichen (passt zum Bearer-Parser).
const token = z.string().min(32).max(512).regex(/^[\x21-\x7E]+$/);

const schema = z.object({
	NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),
	HOST: z.string().default('127.0.0.1'),
	PORT: z.coerce.number().int().min(1).max(65535).default(3000),

	// MOTIS-Instanz. Standard: Transitous. Spaeter austauschbar gegen eine eigene Instanz.
	MOTIS_BASE_URL: z.url({protocol: /^https$/}).default('https://api.transitous.org')
		.refine((u) => !FORBIDDEN_MOTIS_HOSTS.some((re) => re.test(new URL(u).hostname)), {
			message: 'Staging-/interne Transitous-Endpunkte sind fuer Anwendungen nicht erlaubt.',
		}),

	// Transitous verlangt: Name der Anwendung, Version und Kontakt (E-Mail oder URL).
	// Beispiel: "TransitPlanner/0.1.0 (name@example.de)"
	USER_AGENT: z.string().regex(/^[A-Za-z][\w.-]*\/\d+\.\d+[\w.-]* \(.*(@|https?:\/\/).*\)$/, {
		message: 'USER_AGENT muss "Name/Version (Kontakt)" sein, Kontakt = E-Mail oder URL (Transitous-Nutzungsregel).',
	}),

	// Gemeinsames Geheimnis zwischen App und Backend (Bearer). Mindestens 32 Zeichen.
	API_TOKEN: token,
	// Optional: weitere gueltige Tokens, kommagetrennt (Rotation ohne Ausfall). Jedes mindestens 32 Zeichen.
	API_TOKENS: z.string().default('').transform((s) => s.split(',').map((t) => t.trim()).filter(Boolean))
		.pipe(z.array(token)),

	// Hinter Caddy/Reverse-Proxy: Anzahl vertrauenswuerdiger Proxy-Hops fuer req.ip.
	TRUST_PROXY: z.coerce.number().int().min(0).max(5).default(1),

	// Schutz des Backends selbst (pro Client-IP).
	RATE_LIMIT_PER_MINUTE: z.coerce.number().int().min(1).default(60),
	// Zusaetzliche Limits pro Client-IP fuer teure Pfade.
	RATE_LIMIT_LOCATIONS_PER_MINUTE: z.coerce.number().int().min(1).default(20),
	RATE_LIMIT_ROUTES_PER_MINUTE: z.coerce.number().int().min(1).default(8),
	RATE_LIMIT_REFRESH_PER_MINUTE: z.coerce.number().int().min(1).default(12),

	// Ruecksicht auf Transitous (ehrenamtlich betrieben): feste Obergrenze fuer ausgehende Anfragen.
	// Standard 1 Anfrage je 1000 ms = 60/Minute.
	UPSTREAM_LIMIT: z.coerce.number().int().min(1).default(1),
	UPSTREAM_INTERVAL_MS: z.coerce.number().int().min(100).default(1000),
	UPSTREAM_TIMEOUT_MS: z.coerce.number().int().min(1000).default(12000),
	UPSTREAM_MAX_QUEUE: z.coerce.number().int().min(1).default(20),

	LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'silent']).default('info'),
});

export function loadConfig(env = process.env) {
	const parsed = schema.safeParse(env);
	if (!parsed.success) {
		const issues = parsed.error.issues.map((i) => `  - ${i.path.join('.')}: ${i.message}`).join('\n');
		throw new Error(`Ungueltige Konfiguration:\n${issues}`);
	}
	return Object.freeze(parsed.data);
}
