// Kleiner In-Memory-LRU-Cache mit TTL. Nur fuer nicht-personenbezogene Daten
// (Haltestellen-Suchergebnisse). Schluessel enthalten bereits gerundete Koordinaten.

export class TTLCache {
	constructor({maxEntries = 500, ttlMs = 60_000, now = () => Date.now()} = {}) {
		this.maxEntries = maxEntries;
		this.ttlMs = ttlMs;
		this.now = now;
		this.map = new Map();
	}

	get(key) {
		const entry = this.map.get(key);
		if (!entry) return undefined;
		if (entry.expiresAt <= this.now()) {
			this.map.delete(key);
			return undefined;
		}
		// LRU: an das Ende verschieben
		this.map.delete(key);
		this.map.set(key, entry);
		return entry.value;
	}

	set(key, value) {
		if (this.map.has(key)) this.map.delete(key);
		this.map.set(key, {value, expiresAt: this.now() + this.ttlMs});
		while (this.map.size > this.maxEntries) {
			const oldest = this.map.keys().next().value;
			this.map.delete(oldest);
		}
	}

	get size() {
		return this.map.size;
	}
}
