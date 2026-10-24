import {describe, it, expect} from 'vitest';
import {createUpstreamGate, isRetryable} from '../src/lib/upstreamGate.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

describe('upstreamGate', () => {
	it('haelt die Rate ein', async () => {
		const gate = createUpstreamGate({limit: 1, intervalMs: 50, maxQueue: 10, minRemainingMs: 0});
		const times = [];
		const start = Date.now();
		await Promise.all([1, 2, 3].map(() => gate.run(async () => times.push(Date.now() - start), {timeoutMs: 1000})));
		expect(times[1] - times[0]).toBeGreaterThanOrEqual(45);
		expect(times[2] - times[1]).toBeGreaterThanOrEqual(45);
	});

	it('lehnt bei voller Warteschlange sofort ab statt zu stauen', async () => {
		const gate = createUpstreamGate({limit: 1, intervalMs: 1000, maxQueue: 2, minRemainingMs: 0});
		const ok = gate.run(async () => 'a', {timeoutMs: 3000}); // laeuft sofort
		const q1 = gate.run(async () => 'b', {timeoutMs: 3000});
		const q2 = gate.run(async () => 'c', {timeoutMs: 3000});
		await expect(gate.run(async () => 'd', {timeoutMs: 3000})).rejects.toMatchObject({code: 'UPSTREAM_UNAVAILABLE', retryAfterSeconds: 10});
		await ok;
		q1.catch(() => {}); q2.catch(() => {});
	});

	it('sendet abgelaufene Auftraege nicht mehr an die DB', async () => {
		const gate = createUpstreamGate({limit: 1, intervalMs: 300, maxQueue: 10, minRemainingMs: 0});
		let calls = 0;
		const fn = async () => { calls++; };
		await gate.run(fn, {timeoutMs: 1000});
		await expect(gate.run(fn, {timeoutMs: 50})).rejects.toMatchObject({name: 'TimeoutError'});
		await sleep(400);
		expect(calls).toBe(1);
	});

	it('wiederholt nur Netzwerkfehler und 5xx, nie 4xx', async () => {
		const gate = createUpstreamGate({limit: 100, intervalMs: 100, maxQueue: 10, minRemainingMs: 0});
		let n = 0;
		const e400 = Object.assign(new Error('Bad Request'), {response: {status: 400}});
		await expect(gate.run(async () => { n++; throw e400; }, {timeoutMs: 2000})).rejects.toBe(e400);
		expect(n).toBe(1);

		n = 0;
		const reset = Object.assign(new TypeError('fetch failed'), {cause: {code: 'ECONNRESET'}});
		const res = await gate.run(async () => { n++; if (n === 1) throw reset; return 'ok'; }, {timeoutMs: 2000});
		expect(res).toBe('ok');
		expect(n).toBe(2);
	});

	it('abgelaufene Jobs blockieren keine Kapazitaet', async () => {
		const gate = createUpstreamGate({limit: 1, intervalMs: 1000, maxQueue: 2, minRemainingMs: 0});
		await gate.run(async () => {}, {timeoutMs: 3000}); // belegt den Slot
		const a = gate.run(async () => {}, {timeoutMs: 30});
		const b = gate.run(async () => {}, {timeoutMs: 30});
		await expect(a).rejects.toMatchObject({name: 'TimeoutError'});
		await expect(b).rejects.toMatchObject({name: 'TimeoutError'});
		expect(gate.pending).toBe(0);
		const c = gate.run(async () => 'ok', {timeoutMs: 3000});
		await expect(c).resolves.toBe('ok');
	});

	it('sendet nichts mit zu kleinem Restbudget', async () => {
		const gate = createUpstreamGate({limit: 10, intervalMs: 100, minRemainingMs: 2000});
		let calls = 0;
		await expect(gate.run(async () => { calls++; }, {timeoutMs: 1500})).rejects.toMatchObject({name: 'TimeoutError'});
		expect(calls).toBe(0);
	});

	it('loest beim Timeout das AbortSignal aus und wiederholt dann nicht', async () => {
		const gate = createUpstreamGate({limit: 100, intervalMs: 100, minRemainingMs: 0});
		let calls = 0;
		let sig;
		const p = gate.run((signal) => { calls++; sig = signal; return new Promise(() => {}); }, {timeoutMs: 50});
		await expect(p).rejects.toMatchObject({name: 'TimeoutError'});
		expect(sig.aborted).toBe(true);
		await sleep(100);
		expect(calls).toBe(1);
	});

	it('pausiert global nach 429 fuer Retry-After und lehnt solange sofort ab', async () => {
		let t = 1_000_000;
		const gate = createUpstreamGate({limit: 100, intervalMs: 100, minRemainingMs: 0, now: () => t});
		const e429 = Object.assign(new Error('Too Many'), {response: {status: 429}, retryAfterSeconds: 20});
		await expect(gate.run(async () => { throw e429; }, {timeoutMs: 1000})).rejects.toBe(e429);
		await new Promise((r) => setTimeout(r, 0));
		expect(gate.paused).toBe(true);
		let called = false;
		await expect(gate.run(async () => { called = true; }, {timeoutMs: 1000})).rejects.toMatchObject({code: 'UPSTREAM_UNAVAILABLE', retryAfterSeconds: 20});
		expect(called).toBe(false);
		t += 21_000;
		await expect(gate.run(async () => 'ok', {timeoutMs: 1000})).resolves.toBe('ok');
	});

	it('klassifiziert Retry-Faehigkeit', () => {
		expect(isRetryable(Object.assign(new TypeError('fetch failed'), {cause: {code: 'ECONNRESET'}}))).toBe(true);
		expect(isRetryable(Object.assign(new TypeError('fetch failed'), {cause: {code: 'CERT_HAS_EXPIRED'}}))).toBe(false);
		expect(isRetryable(Object.assign(new Error('aborted'), {name: 'AbortError'}))).toBe(false);
		expect(isRetryable(Object.assign(new Error(), {response: {status: 502}}))).toBe(true);
		expect(isRetryable(Object.assign(new Error(), {response: {status: 503}}))).toBe(false); // -> globale Pause
		expect(isRetryable(Object.assign(new TypeError('fetch failed'), {cause: new Error('unexpected redirect')}))).toBe(false);
		expect(isRetryable(Object.assign(new Error(), {response: {status: 500}}))).toBe(false); // MOTIS: deterministische Fehler
		expect(isRetryable(Object.assign(new TypeError('terminated'), {cause: {code: 'UND_ERR_SOCKET'}}))).toBe(true);
		expect(isRetryable(Object.assign(new Error(), {response: {status: 429}}))).toBe(false);
		expect(isRetryable(new TypeError('invalid address'))).toBe(false);
	});
});
