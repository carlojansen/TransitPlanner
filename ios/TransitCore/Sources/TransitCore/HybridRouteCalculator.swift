import CoreLocation
import Foundation
import MapKit

/// Apple-Maps-Standardgehzeit fuer einen Fussweg.
public struct WalkingETA: Sendable, Hashable {
    public let seconds: TimeInterval
    public let distanceMeters: Double

    public init(seconds: TimeInterval, distanceMeters: Double) {
        self.seconds = seconds
        self.distanceMeters = distanceMeters
    }
}

public protocol WalkingDirectionsProviding: Sendable {
    func walkingETA(from: GeoCoordinate, to: GeoCoordinate) async throws -> WalkingETA
}

public struct MapKitWalkingDirections: WalkingDirectionsProviding {
    public init() {}

    public func walkingETA(from: GeoCoordinate, to: GeoCoordinate) async throws -> WalkingETA {
        let request = MKDirections.Request()
        request.source = Self.item(from)
        request.destination = Self.item(to)
        request.transportType = .walking
        // ETA statt voller Route: gleiche Gehzeit, weniger Last (Geometrie liefert schon das Backend).
        let eta = try await MKDirections(request: request).calculateETA()
        return WalkingETA(seconds: eta.expectedTravelTime, distanceMeters: eta.distance)
    }

    private static func item(_ c: GeoCoordinate) -> MKMapItem {
        MKMapItem(location: CLLocation(latitude: c.latitude, longitude: c.longitude), address: nil)
    }
}

/// Kalibrierte Gehzeit eines Fussweg-Abschnitts.
public struct WalkEstimate: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// MKDirections x WalkingPaceFactor
        case appleMaps
        /// MKDirections nicht verfuegbar oder Weg zu kurz: MOTIS-Dauer x WalkingPaceFactor
        case timetable
    }

    public let legIndex: Int
    public let seconds: Int
    public let distanceMeters: Int?
    public let source: Source
}

public struct TransferCheck: Sendable, Hashable {
    /// Index des Umstiegs-Fusswegs
    public let legIndex: Int
    /// Zeit, die nach dem kalibrierten Fussweg bis zur Abfahrt bleibt (negativ = nicht zu schaffen).
    public let slackSeconds: Int
    public var isAtRisk: Bool { slackSeconds < TransferCheck.minimumSlackSeconds }
    public static let minimumSlackSeconds = 60
}

public struct CalibratedJourney: Sendable, Hashable {
    public let journey: Journey
    /// Kalibrierte Gehzeiten je Fussweg-Abschnitt (Schluessel: Leg-Index).
    public let walks: [Int: WalkEstimate]
    public let transfers: [TransferCheck]

    /// Summe der kalibrierten Fusswege vor dem ersten Fahrzeug.
    public var accessWalkSeconds: Int {
        journey.legs.prefix(while: \.isWalk).reduce(0) { $0 + (walks[$1.index]?.seconds ?? $1.durationSeconds ?? 0) }
    }

    /// Ankunft am Ziel mit kalibriertem letzten Fussweg.
    public var arrivalAtDestination: Date? {
        guard let lastTransit = journey.legs.last(where: { !$0.isWalk }), let arrival = lastTransit.arrival else {
            return journey.arrival
        }
        let egress = journey.legs.reversed().prefix(while: \.isWalk).reduce(0) { $0 + (walks[$1.index]?.seconds ?? $1.durationSeconds ?? 0) }
        return arrival.addingTimeInterval(TimeInterval(egress))
    }
}

/// Paralleler Hybrid-Rechner: Verbindungen vom Backend, Fusswege per MKDirections (.walking) x WalkingPaceFactor.
public struct HybridRouteCalculator: Sendable {
    /// Unterhalb dieser Luftlinie wird MKDirections nicht gefragt (gleicher Bahnsteig, Rauschen).
    public static let minimumAppleMapsDistance: Double = 25

    private let api: TransitAPIClient
    private let directions: any WalkingDirectionsProviding

    public init(api: TransitAPIClient, directions: any WalkingDirectionsProviding = MapKitWalkingDirections()) {
        self.api = api
        self.directions = directions
    }

    public enum Stage: Sendable {
        /// Sofort darstellbares Grundgeruest (Fahrplan-Gehzeiten).
        case skeleton(RoutesResponse)
        /// Mit Apple-Maps-Gehzeiten kalibriert.
        case calibrated(RoutesResponse, [CalibratedJourney])
    }

    /// Progressive Pipeline (SPEZIFIKATION 2.2): erst Skelett, dann kalibrierte Gehzeiten. Fehler sind `TransitError`.
    public func plan(_ trip: some TripRequest, pace: WalkingPaceFactor) -> AsyncThrowingStream<Stage, any Error> {
        let request = trip.routesRequest()
        let originExact = trip.origin.exactCoordinate
        let destinationExact = trip.destination.exactCoordinate
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await api.routes(request)
                    continuation.yield(.skeleton(response))
                    let calibrated = try await calibrate(response.journeys, pace: pace,
                                                         origin: originExact, destination: destinationExact)
                    continuation.yield(.calibrated(response, calibrated))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Ersetzt alle Fussweg-Dauern. Gleiche Wege (z. B. Start -> erste Haltestelle in mehreren Verbindungen)
    /// werden nur einmal berechnet, alle eindeutigen Wege parallel.
    /// `origin`/`destination`: exakte lokale Koordinate (das Backend kennt nur die gerundete).
    public func calibrate(_ journeys: [Journey], pace: WalkingPaceFactor,
                          origin: GeoCoordinate? = nil, destination: GeoCoordinate? = nil) async throws(TransitError) -> [CalibratedJourney] {
        // 1. Eindeutige Segmente sammeln
        var segments = Set<Segment>()
        for journey in journeys {
            for leg in journey.legs where leg.isWalk {
                if let s = segment(for: leg, in: journey, origin: origin, destination: destination),
                   s.from.distance(to: s.to) >= Self.minimumAppleMapsDistance {
                    segments.insert(s)
                }
            }
        }

        // 2. Parallel per TaskGroup. Einzelne Fehlschlaege fallen auf die Fahrplanzeit zurueck.
        let directions = self.directions
        let etas: [Segment: WalkingETA]
        do {
            etas = try await withThrowingTaskGroup(of: (Segment, WalkingETA?).self) { group in
                // ponytail: keine Obergrenze paralleler MKDirections-Anfragen; bei Apple-Drosselung (MKError.loadingThrottled) begrenzen.
                for s in segments {
                    group.addTask {
                        do { return (s, try await directions.walkingETA(from: s.from, to: s.to)) }
                        catch is CancellationError { throw CancellationError() }
                        catch { return (s, nil) }
                    }
                }
                var out: [Segment: WalkingETA] = [:]
                for try await (s, eta) in group { if let eta { out[s] = eta } }
                return out
            }
        } catch {
            throw .cancelled
        }

        // 3. Zusammensetzen
        return journeys.map { journey in
            var walks: [Int: WalkEstimate] = [:]
            for leg in journey.legs where leg.isWalk {
                let eta = segment(for: leg, in: journey, origin: origin, destination: destination).flatMap { etas[$0] }
                if let eta {
                    walks[leg.index] = WalkEstimate(legIndex: leg.index, seconds: pace.apply(to: eta.seconds),
                                                    distanceMeters: Int(eta.distanceMeters.rounded()), source: .appleMaps)
                } else {
                    walks[leg.index] = WalkEstimate(legIndex: leg.index, seconds: pace.apply(to: Double(leg.durationSeconds ?? 0)),
                                                    distanceMeters: leg.distanceMeters, source: .timetable)
                }
            }
            return CalibratedJourney(journey: journey, walks: walks, transfers: Self.transferChecks(journey, walks: walks))
        }
    }

    private struct Segment: Hashable, Sendable {
        let from: GeoCoordinate
        let to: GeoCoordinate
    }

    private func segment(for leg: Leg, in journey: Journey, origin: GeoCoordinate?, destination: GeoCoordinate?) -> Segment? {
        let isFirst = leg.index == journey.legs.first?.index
        let isLast = leg.index == journey.legs.last?.index
        let from = (isFirst && leg.origin.kind == .coordinate ? origin : nil) ?? leg.origin.coordinate
        let to = (isLast && leg.destination.kind == .coordinate ? destination : nil) ?? leg.destination.coordinate
        guard let from, let to else { return nil }
        // Schluessel auf ~1 m runden, damit identische Wege zusammenfallen.
        return Segment(from: from.rounded(decimals: 5), to: to.rounded(decimals: 5))
    }

    static func transferChecks(_ journey: Journey, walks: [Int: WalkEstimate]) -> [TransferCheck] {
        let legs = journey.legs
        var checks: [TransferCheck] = []
        for (i, leg) in legs.enumerated() where leg.isWalk && i > 0 && i < legs.count - 1 {
            let previous = legs[i - 1], next = legs[i + 1]
            guard !previous.isWalk, !next.isWalk, let arrival = previous.arrival, let departure = next.departure else { continue }
            let walk = walks[leg.index]?.seconds ?? leg.durationSeconds ?? 0
            checks.append(TransferCheck(legIndex: leg.index, slackSeconds: Int(departure.timeIntervalSince(arrival)) - walk))
        }
        return checks
    }
}

extension TripEndpoint {
    var exactCoordinate: GeoCoordinate? {
        if case .coordinate(let c, _) = self { return c }
        return nil
    }
}
