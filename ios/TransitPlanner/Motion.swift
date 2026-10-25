import SwiftUI

/// Einzige Quelle fuer Animationen (AGENT.md 4.3). Keine Werte direkt im View-Code, kein `.linear`.
enum Motion {
    /// Zustandswechsel, Morphing, Kamerafahrten, Ein-/Ausblenden von Overlays.
    static let standard = Animation.spring(response: 0.4, dampingFraction: 1.0)
    /// Mikro-Interaktionen (Schalter, Zahlen, Aufklappen).
    static let micro = Animation.spring(response: 0.25, dampingFraction: 1.0)
    /// Nur nach Gesten mit Schwung.
    static let momentum = Animation.spring(response: 0.3, dampingFraction: 0.8)
}
