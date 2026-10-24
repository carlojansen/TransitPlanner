import pino from 'pino';
import {loadConfig} from './config.js';
import {createApp} from './app.js';
import {createMotisClient} from './services/motisClient.js';
import {createTransitService} from './services/transitService.js';
import {createUpstreamGate} from './lib/upstreamGate.js';

const config = loadConfig();
const logger = pino({
	level: config.LOG_LEVEL,
	// Zusaetzliches Sicherheitsnetz, falls doch einmal ein Request-Objekt geloggt wird.
	redact: ['req.headers.authorization', 'req.query', 'req.body', '*.refreshToken', '*.latitude', '*.longitude'],
});

const client = createMotisClient({baseUrl: config.MOTIS_BASE_URL, userAgent: config.USER_AGENT});
const gate = createUpstreamGate({
	limit: config.UPSTREAM_LIMIT,
	intervalMs: config.UPSTREAM_INTERVAL_MS,
	maxQueue: config.UPSTREAM_MAX_QUEUE,
});
const service = createTransitService({client, gate, timeoutMs: config.UPSTREAM_TIMEOUT_MS, logger});
const app = createApp({config, service, logger});

// Lauscht nur auf localhost. TLS 1.3 terminiert der Reverse-Proxy (deploy/Caddyfile).
const server = app.listen(config.PORT, config.HOST, () => {
	logger.info({host: config.HOST, port: config.PORT, upstream: new URL(config.MOTIS_BASE_URL).host}, 'TransitPlanner backend listening');
});
// keepAliveTimeout muss laenger sein als Caddys Upstream-Idle-Zeit (2 min), sonst sporadische 502.
// headersTimeout/requestTimeout begrenzen die einzelne Anfrage (Slowloris-Schutz).
server.keepAliveTimeout = 125_000;
server.headersTimeout = 15_000;
server.requestTimeout = 30_000;

const shutdown = (signal) => {
	logger.info({signal}, 'shutting down');
	server.close(() => process.exit(0));
	setTimeout(() => process.exit(1), 5000).unref();
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
