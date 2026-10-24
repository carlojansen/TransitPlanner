// Drossel fuer alle Anfragen an die Upstream-API (Transitous wird ehrenamtlich betrieben).
//
// Eigenschaften:
//  - Feste Rate (limit pro intervalMs), begrenzte Warteschlange (maxQueue).
//  - Volle Warteschlange: sofortige Ablehnung statt Stau.
//  - Auftraege mit zu wenig Restbudget (< minRemainingMs) werden nicht mehr gesendet.
//  - Genau ein Retry, nur bei transienten Netzwerkfehlern und 502/504, nur wenn die Deadline es zulaesst.
//    (MOTIS liefert 500 auch fuer deterministische Fehler; die werden nicht wiederholt.)
//  - 429/503 vom Upstream pausieren die Drossel global fuer Retry-After (Standard 30 s); waehrenddessen
//    wird sofort mit UPSTREAM_UNAVAILABLE abgelehnt, statt weiter Last zu erzeugen.
//  - Beim Gesamt-Timeout wird ein AbortSignal ausgeloest: laufende HTTP-Anfragen brechen wirklich ab.
//    fn bekommt das Signal als einziges Argument.
import {TransitError, ErrorCode, isNetworkError, upstreamStatus, TRANSIENT_NETWORK_CODES} from './errors.js';

// 503 bewusst nicht: loest die globale Pause aus (BACKOFF_STATUS) statt eines Retries.
const RETRYABLE_STATUS = new Set([502, 504]);
const BACKOFF_STATUS = new Set([429, 503]);
const DEFAULT_BACKOFF_S = 30;
const MAX_BACKOFF_S = 300;

export function isRetryable(err) {
	if (err?.name === 'AbortError') return false;
	const status = upstreamStatus(err);
	if (typeof status === 'number') return RETRYABLE_STATUS.has(status);
	// Mit Fehlercode entscheidet nur der Code (z. B. TLS-Zertifikatsfehler: nicht wiederholen).
	const code = err?.cause?.code ?? err?.code;
	if (code) return TRANSIENT_NETWORK_CODES.has(code);
	// Ohne Code: Weiterleitungen (redirect: 'error') sind deterministisch, nicht wiederholen.
	if (/redirect/i.test(String(err?.cause?.message ?? ''))) return false;
	return isNetworkError(err);
}

// Ein Auftrag geht nur raus, wenn sein Restbudget fuer eine Antwort realistisch reicht.
// Sonst wuerde die Antwort verworfen und Upstream-Kapazitaet fuer niemanden verbraucht.
const MIN_REMAINING_MS = 2000;

export function createUpstreamGate({limit = 1, intervalMs = 1000, maxQueue = 20, minRemainingMs = MIN_REMAINING_MS, now = () => Date.now()} = {}) {
	const spacing = intervalMs / limit;
	let nextSlot = 0;
	let pausedUntil = 0;
	const queue = [];
	let timer = null;

	const timeoutError = () => {
		const e = new Error('upstream timeout');
		e.name = 'TimeoutError';
		return e;
	};

	const pausedError = () => new TransitError(ErrorCode.UPSTREAM_UNAVAILABLE, {
		retryAfterSeconds: Math.max(1, Math.ceil((pausedUntil - now()) / 1000)),
	});

	const tooLate = (deadline) => {
		const remaining = deadline - now();
		return remaining <= 0 || remaining < minRemainingMs;
	};

	function schedule() {
		if (timer || queue.length === 0) return;
		timer = setTimeout(drain, Math.max(0, nextSlot - now()));
	}

	function purgeExpired() {
		for (let i = queue.length - 1; i >= 0; i--) {
			const job = queue[i];
			if (tooLate(job.deadline)) {
				queue.splice(i, 1);
				job.reject(timeoutError());
			}
		}
	}

	function rejectAllPaused() {
		while (queue.length) queue.shift().reject(pausedError());
	}

	function noteBackoff(err) {
		if (!BACKOFF_STATUS.has(upstreamStatus(err))) return;
		const s = Number.isFinite(err?.retryAfterSeconds) && err.retryAfterSeconds > 0
			? Math.min(err.retryAfterSeconds, MAX_BACKOFF_S) : DEFAULT_BACKOFF_S;
		pausedUntil = Math.max(pausedUntil, now() + s * 1000);
		rejectAllPaused();
	}

	function drain() {
		if (timer) clearTimeout(timer);
		timer = null;
		while (queue.length > 0) {
			if (pausedUntil > now()) { rejectAllPaused(); return; }
			const job = queue[0];
			if (tooLate(job.deadline)) {
				queue.shift();
				job.reject(timeoutError());
				continue;
			}
			if (nextSlot > now()) break;
			queue.shift();
			nextSlot = now() + spacing;
			Promise.resolve().then(job.fn).then(job.resolve, (err) => {
				noteBackoff(err);
				job.reject(err);
			});
		}
		schedule();
	}

	function enqueue(fn, deadline) {
		if (pausedUntil > now()) return Promise.reject(pausedError());
		// Abgelaufene Eintraege zaehlen nicht gegen die Kapazitaet.
		purgeExpired();
		if (queue.length >= maxQueue) {
			return Promise.reject(new TransitError(ErrorCode.UPSTREAM_UNAVAILABLE, {retryAfterSeconds: 10}));
		}
		if (tooLate(deadline)) return Promise.reject(timeoutError());
		return new Promise((resolve, reject) => {
			queue.push({fn, deadline, resolve, reject});
			drain();
		});
	}

	// Fuehrt fn ueber die Drossel aus. Gesamtdauer inkl. Wartezeit und Retry <= timeoutMs.
	async function run(fn, {timeoutMs}) {
		const deadline = now() + timeoutMs;
		const controller = new AbortController();
		const job = () => fn(controller.signal);
		let timeoutHandle;
		const overall = new Promise((_, reject) => {
			timeoutHandle = setTimeout(() => {
				controller.abort();
				// Wartende Jobs dieses Aufrufs sofort aus der Queue nehmen (blockieren sonst Kapazitaet).
				purgeExpired();
				reject(timeoutError());
			}, timeoutMs);
		});
		const attempt = async () => {
			try {
				return await enqueue(job, deadline);
			} catch (err) {
				if (!controller.signal.aborted && isRetryable(err) && pausedUntil <= now() && deadline - now() > spacing + minRemainingMs) {
					return enqueue(job, deadline);
				}
				throw err;
			}
		};
		try {
			return await Promise.race([attempt(), overall]);
		} finally {
			clearTimeout(timeoutHandle);
		}
	}

	return {
		run,
		get pending() {
			return queue.length;
		},
		get paused() {
			return pausedUntil > now();
		},
		// Anfragen pro Minute, die der Upstream maximal sieht
		get perMinute() {
			return Math.floor((60_000 / intervalMs) * limit);
		},
	};
}
