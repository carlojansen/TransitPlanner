import ActivityKit
import Foundation
import TransitCore

/// In App und Widget-Target; `TripActivityState` liegt ohne ActivityKit in TransitCore. `key` ist eine lokale ID ohne Inhalt.
struct TripActivityAttributes: ActivityAttributes {
    typealias ContentState = TripActivityState

    let key: String
    /// Geplanter Start; laesst sich spaeter nicht aendern, darum Teil der festen Attribute.
    let startAt: Date?
}
