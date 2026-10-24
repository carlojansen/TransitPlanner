import CoreLocation
import Foundation

public struct LocationFix: Sendable, Hashable {
    public let coordinate: GeoCoordinate
    public let horizontalAccuracy: Double
    public let timestamp: Date

    public init(coordinate: GeoCoordinate, horizontalAccuracy: Double, timestamp: Date) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }
}

/// Standortquelle. Produktiv nur CoreLocation (GPS/WLAN/Mobilfunk auf dem Geraet), nie IP-Geolokalisierung.
public protocol LocationProviding: Sendable {
    func currentFix() async throws(TransitError) -> LocationFix
}

/// VPN-sicher: Standort ausschliesslich aus CoreLocation. Der Fix wird nicht gespeichert (ephemeral).
public struct CoreLocationService: LocationProviding {
    public var maxAccuracyMeters: Double
    public var maxAgeSeconds: TimeInterval
    public var timeoutSeconds: Double

    public init(maxAccuracyMeters: Double = 1_000, maxAgeSeconds: TimeInterval = 60, timeoutSeconds: Double = 10) {
        self.maxAccuracyMeters = maxAccuracyMeters
        self.maxAgeSeconds = maxAgeSeconds
        self.timeoutSeconds = timeoutSeconds
    }

    public func currentFix() async throws(TransitError) -> LocationFix {
        let maxAccuracy = maxAccuracyMeters
        let maxAge = maxAgeSeconds
        let timeout = timeoutSeconds
        do {
            return try await withThrowingTaskGroup(of: LocationFix.self) { group in
                group.addTask { try await Self.firstUsableFix(maxAccuracy: maxAccuracy, maxAge: maxAge) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw TransitError.locationUnavailable
                }
                defer { group.cancelAll() }
                guard let fix = try await group.next() else { throw TransitError.locationUnavailable }
                return fix
            }
        } catch let error as TransitError {
            throw error
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .locationUnavailable
        }
    }

    private static func firstUsableFix(maxAccuracy: Double, maxAge: TimeInterval) async throws -> LocationFix {
        // Haelt die When-In-Use-Berechtigung fuer die Dauer der Abfrage.
        #if os(iOS)
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        #endif
        for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
            if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                throw TransitError.locationDenied
            }
            guard let location = update.location,
                  location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= maxAccuracy,
                  abs(location.timestamp.timeIntervalSinceNow) <= maxAge
            else { continue }
            return LocationFix(
                coordinate: GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                horizontalAccuracy: location.horizontalAccuracy,
                timestamp: location.timestamp
            )
        }
        throw TransitError.locationUnavailable
    }
}
