// Datenschutz-Helfer (AGENT.md 3.1): Coordinate Fuzzing.

// Rundet auf n Nachkommastellen. 3 Stellen ~ 110 m, 4 Stellen ~ 11 m, 5 Stellen ~ 1 m.
export function fuzz(value, decimals) {
	const f = 10 ** decimals;
	return Math.round(value * f) / f;
}
