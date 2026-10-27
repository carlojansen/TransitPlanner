import Foundation

/// Persoenlicher Gehzeit-Faktor (SPEZIFIKATION 4.1): `Reale_Gehzeit = MKDirections_Zeit * Faktor`.
/// < 1 = schneller als Apple-Maps-Standard. Lernt aus gemessenen Fusswegen, manuell ueberschreibbar.
public struct WalkingPaceFactor: Codable, Sendable, Hashable {
    public static let allowedRange: ClosedRange<Double> = 0.5...2.0
    /// Messungen ausserhalb gelten als Ausreisser (Pause, Umweg, Ampel-Rekord).
    public static let plausibleRatio: ClosedRange<Double> = 0.4...2.5
    /// Kurze Wege sind zu verrauscht (GPS, Ampel).
    public static let minimumPredictedSeconds: Double = 60
    /// Gewicht neuer Messungen, sobald genug Daten vorliegen.
    public static let smoothing: Double = 0.2

    public private(set) var learned: Double
    public private(set) var sampleCount: Int
    /// Vom Nutzer gesetzt; hat Vorrang vor dem gelernten Wert.
    public var manualOverride: Double?

    public init(learned: Double = 1.0, sampleCount: Int = 0, manualOverride: Double? = nil) {
        self.learned = Self.clamp(learned)
        self.sampleCount = max(0, sampleCount)
        self.manualOverride = manualOverride
    }

    public var value: Double { Self.clamp(manualOverride ?? learned) }

    /// Kalibrierte Gehzeit in Sekunden (aufgerundet, lieber eine Sekunde zu frueh los).
    public func apply(to seconds: Double) -> Int {
        Int((max(0, seconds) * value).rounded(.up))
    }

    /// Gehzeit in ganzen Minuten fuer eine Luftlinie (Haltestellen in der Naehe): aufgerundet, mindestens 1.
    public func walkMinutes(meters: Int) -> Int {
        max(1, Int((Double(apply(to: Double(max(0, meters)) / NavigationEngine.defaultWalkSpeed)) / 60).rounded(.up)))
    }

    /// Nimmt eine Messung auf. Gibt false zurueck, wenn sie verworfen wurde.
    @discardableResult
    public mutating func record(predictedSeconds: Double, actualSeconds: Double) -> Bool {
        guard predictedSeconds >= Self.minimumPredictedSeconds, actualSeconds > 0 else { return false }
        let ratio = actualSeconds / predictedSeconds
        guard Self.plausibleRatio.contains(ratio) else { return false }
        // Anfangs gleitender Mittelwert (schnelles Lernen), danach exponentielle Glaettung (passt sich langsam an).
        let weight = sampleCount < 5 ? 1.0 / Double(sampleCount + 1) : Self.smoothing
        learned = Self.clamp(learned + weight * (ratio - learned))
        sampleCount += 1
        return true
    }

    private static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 1.0 }
        return min(max(v, allowedRange.lowerBound), allowedRange.upperBound)
    }
}
