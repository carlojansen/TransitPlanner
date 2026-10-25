import SwiftUI
import TransitCore

// Farben aus dem Asset Catalog (DESIGN.md 1, Any/Dark). Farbe ist nie die einzige Information.

extension TransitMode {
    var color: Color {
        switch self {
        case .walk: Color(.modeWalk)
        case .tram: Color(.modeTram)
        case .subway: Color(.modeUbahn)
        case .suburban: Color(.modeSbahn)
        case .bus, .onDemand: Color(.modeBus)
        case .regional, .regionalExpress, .national, .nationalExpress: Color(.modeRegio)
        case .ferry, .funicular, .aerialLift, .airplane, .other, .unknown: Color(.accentBlue)
        }
    }

    var symbolName: String {
        switch self {
        case .walk: "figure.walk"
        case .tram: "tram.fill"
        case .bus, .onDemand: "bus.fill"
        case .subway: "tram.fill.tunnel"
        case .suburban, .regional, .regionalExpress, .national, .nationalExpress: "train.side.front.car"
        case .ferry: "ferry.fill"
        case .funicular, .aerialLift: "cablecar.fill"
        case .airplane: "airplane"
        case .other, .unknown: "questionmark.circle"
        }
    }

    var displayName: String {
        switch self {
        case .walk: String(localized: "Fußweg")
        case .tram: String(localized: "Straßenbahn")
        case .bus: String(localized: "Bus")
        case .onDemand: String(localized: "Rufbus")
        case .subway: String(localized: "U-Bahn")
        case .suburban: String(localized: "S-Bahn")
        case .regional, .regionalExpress: String(localized: "Regionalzug")
        case .national, .nationalExpress: String(localized: "Fernzug")
        case .ferry: String(localized: "Fähre")
        case .funicular: String(localized: "Standseilbahn")
        case .aerialLift: String(localized: "Seilbahn")
        case .airplane: String(localized: "Flugzeug")
        case .other, .unknown: String(localized: "Verkehrsmittel")
        }
    }
}

extension Leg {
    /// Ersatzverkehr wird immer als Bus gezeichnet (mode/bus), auch wenn der Feed etwas anderes meldet.
    var displayMode: TransitMode { replacement ? .bus : mode }

    /// Kurzname fuer Badges: Linienname, sonst Verkehrsmittel.
    var badgeName: String { line?.name ?? displayMode.displayName }

    /// Verspaetung in Minuten, nur mit Echtzeitdaten.
    var departureDelayMinutes: Int? {
        guard realtime, let d = departureDelaySeconds, d >= 60 else { return nil }
        return d / 60
    }
}

extension Step.Direction {
    var symbolName: String {
        switch self {
        case .depart: "figure.walk.departure"
        case .continue, .unknown: "arrow.up"
        case .left, .hardLeft: "arrow.turn.up.left"
        case .slightlyLeft: "arrow.up.left"
        case .right, .hardRight: "arrow.turn.up.right"
        case .slightlyRight: "arrow.up.right"
        case .uturnLeft: "arrow.uturn.left"
        case .uturnRight: "arrow.uturn.right"
        case .circleClockwise: "arrow.clockwise"
        case .circleCounterclockwise: "arrow.counterclockwise"
        case .stairs: "figure.stairs"
        case .elevator: "arrow.up.and.down.square"
        }
    }

    var spokenName: String {
        switch self {
        case .depart: String(localized: "Losgehen")
        case .continue: String(localized: "Geradeaus")
        case .left: String(localized: "Links abbiegen")
        case .slightlyLeft: String(localized: "Leicht links")
        case .hardLeft: String(localized: "Scharf links")
        case .right: String(localized: "Rechts abbiegen")
        case .slightlyRight: String(localized: "Leicht rechts")
        case .hardRight: String(localized: "Scharf rechts")
        case .uturnLeft, .uturnRight: String(localized: "Wenden")
        case .circleClockwise, .circleCounterclockwise: String(localized: "Im Kreisverkehr")
        case .stairs: String(localized: "Treppe")
        case .elevator: String(localized: "Aufzug")
        case .unknown: String(localized: "Weiter")
        }
    }
}

/// Ton fuer Banner und Hinweise (DESIGN.md H1): Flaeche + Symbolfarbe.
enum Tone {
    case info, warn, alert

    var tint: Color {
        switch self {
        case .info: Color(.accentBlueTint)
        case .warn: Color(.statusWarnTint)
        case .alert: Color(.statusAlertTint)
        }
    }

    var foreground: Color {
        switch self {
        case .info: Color(.accentBlue)
        case .warn: Color(.statusWarn)
        case .alert: Color(.statusAlert)
        }
    }
}
