import ActivityKit
import AppIntents
import SwiftUI
import TransitCore
import WidgetKit

extension TripActivityState {
    var symbol: String {
        if problem != nil { return "exclamationmark.triangle.fill" }
        switch phase {
        case .leave, .walk, .finalWalk: return "figure.walk"
        case .transfer: return "arrow.triangle.swap"
        case .arrived: return "checkmark.circle.fill"
        case .platform, .riding, .exitNext: return ride?.displayMode.symbolName ?? "tram.fill"
        }
    }

    var tint: Color { problem != nil ? Color(.statusAlert) : ride?.displayMode.color ?? Color(.accentBlue) }
}

/// Laeuft ohne Updates weiter. Abgelaufen steht die Uhrzeit da statt "0:00".
struct ActivityCountdown: View {
    let state: TripActivityState
    let stale: Bool

    var body: some View {
        let now = Date()
        Group {
            if let target = state.target, target > now, !stale {
                Text(timerInterval: now...target, countsDown: true)
            } else if state.phase == .leave {
                Text("Los")
            } else if let target = state.target {
                Text(target, format: .clock)
            } else {
                Image(systemName: state.symbol).accessibilityHidden(true)
            }
        }
        .monospacedDigit()
        .contentTransition(.numericText(countsDown: true))
    }
}

/// Fortschritt ueber die Fahrzeuge; das aktuelle ist hervorgehoben, Farbe ist nicht die einzige Angabe (Linie steht im Badge).
struct ActivityLegBar: View {
    let state: TripActivityState

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(state.modes.enumerated()), id: \.offset) { index, mode in
                Capsule()
                    .fill(index <= state.current ? mode.color : Color(.fillTertiary))
                    .frame(height: 4)
                    .widgetAccentable()
            }
        }
        .accessibilityHidden(true)
    }
}

struct ActivityDetails: View {
    let state: TripActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let stop = state.stop { Text(stop).lineLimit(1).privacySensitive() }
            HStack(spacing: 8) {
                if let platform = state.ride?.platformText, state.phase != .riding, state.phase != .exitNext {
                    Text(platform).lineLimit(1)
                }
                if let delay = state.delayMinutes {
                    Text("\(delay) Min. später")
                        .foregroundStyle(Color(.statusWarn))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(Color(.labelSecondary))
        .minimumScaleFactor(0.6)
    }
}

struct ActivityRefreshButton: View {
    var body: some View {
        Button(intent: RefreshTripIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Aktualisieren")
    }
}

/// Sperrbildschirm: Anweisung und Countdown oben, Halt und Gleis, Leg-Bar, Aktualisieren.
struct ActivityLockView: View {
    let state: TripActivityState
    let stale: Bool
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let ride = state.ride { RideBadge(ride: ride) }
                    Text(state.title(stale: stale))
                        .font(.headline)
                        .foregroundStyle(state.problem == nil ? Color.primary : Color(.statusAlert))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .widgetAccentable()
                }
                HStack(alignment: .firstTextBaseline) {
                    ActivityDetails(state: state)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        if let label = state.targetLabel, !stale {
                            Text(label).font(.caption).foregroundStyle(Color(.labelSecondary)).lineLimit(1)
                        }
                        ActivityCountdown(state: state, stale: stale)
                            .font(.title2.bold())
                            .fontDesign(.rounded)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1)
                            .frame(maxWidth: 110, alignment: .trailing)
                            .minimumScaleFactor(0.6)
                            .widgetAccentable()
                    }
                }
                if state.modes.count > 1 { ActivityLegBar(state: state) }
                if stale, state.phase != .leave {
                    Text("Stand evtl. nicht aktuell").font(.caption).foregroundStyle(Color(.labelSecondary))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.spoken(stale: stale, includeStops: !redaction.contains(.privacy)))
            ActivityRefreshButton()
        }
        .padding(16)
    }
}

struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            ActivityLockView(state: context.state, stale: context.isStale)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let state = context.state
            let stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let ride = state.ride { RideBadge(ride: ride).padding(.leading, 4) }
                }
                DynamicIslandExpandedRegion(.trailing, priority: 1) {
                    ActivityCountdown(state: state, stale: stale)
                        .font(.title3.bold())
                        .fontDesign(.rounded)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .frame(maxWidth: 88, alignment: .trailing)
                        .minimumScaleFactor(0.6)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title(stale: stale))
                        .font(.headline)
                        .foregroundStyle(state.problem == nil ? Color.primary : Color(.statusAlert))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            ActivityDetails(state: state)
                            if state.modes.count > 1 { ActivityLegBar(state: state) }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(state.spoken(stale: stale, includeStops: false))
                        Spacer(minLength: 0)
                        ActivityRefreshButton()
                    }
                }
            } compactLeading: {
                HStack(spacing: 2) {
                    Image(systemName: state.symbol)
                    if let line = state.ride?.badgeText { Text(line).lineLimit(1).minimumScaleFactor(0.6) }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(state.tint)
                .frame(maxWidth: 72)
            } compactTrailing: {
                ActivityCountdown(state: state, stale: stale)
                    .font(.caption.weight(.semibold))
                    .fontDesign(.rounded)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 48)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel(state.spoken(stale: stale, includeStops: false))
            } minimal: {
                Group {
                    if state.problem != nil {
                        Image(systemName: state.symbol).foregroundStyle(state.tint)
                    } else {
                        ActivityCountdown(state: state, stale: stale)
                            .font(.caption2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.5)
                    }
                }
                .accessibilityLabel(state.spoken(stale: stale, includeStops: false))
            }
            .keylineTint(state.tint)
        }
    }
}

#if DEBUG
extension WidgetSample {
    static func activity(phase: String = "leave", problem: String? = nil, delay: Int? = 3, minutes: Double = 12, now: Date = Date()) -> TripActivityState {
        let target = now.addingTimeInterval(minutes * 60).timeIntervalSinceReferenceDate
        let ride = #"{"mode":"tram","replacement":false,"line":"STR 704","from":"Düsseldorf Hbf","to":"Bilk S","platform":"2","plannedPlatform":"1","cancelled":false}"#
        let problemJSON = problem.map { #""problem":"\#($0)","# } ?? ""
        let delayJSON = delay.map { #""delayMinutes":\#($0),"# } ?? ""
        let json = #"{"phase":"\#(phase)","target":\#(target),"ride":\#(ride),"destination":"Köln Hbf","modes":["tram","regional","bus"],"current":1,\#(delayJSON)\#(problemJSON)"x":0}"#
        guard let state = try? JSONDecoder().decode(TripActivityState.self, from: Data(json.utf8)) else {
            preconditionFailure("Beispiel-JSON passt nicht zu TripActivityState")
        }
        return state
    }

    static let attributes = TripActivityAttributes(key: "preview", startAt: nil)
}

#Preview("Sperrbildschirm", as: .content, using: WidgetSample.attributes) {
    TripLiveActivity()
} contentStates: {
    WidgetSample.activity()
    WidgetSample.activity(phase: "exitNext", delay: nil, minutes: 3)
    WidgetSample.activity(problem: "cancelled", delay: nil)
}

#Preview("Island kompakt", as: .dynamicIsland(.compact), using: WidgetSample.attributes) {
    TripLiveActivity()
} contentStates: {
    WidgetSample.activity()
}

#Preview("Island erweitert", as: .dynamicIsland(.expanded), using: WidgetSample.attributes) {
    TripLiveActivity()
} contentStates: {
    WidgetSample.activity()
}

#Preview("Island minimal", as: .dynamicIsland(.minimal), using: WidgetSample.attributes) {
    TripLiveActivity()
} contentStates: {
    WidgetSample.activity()
}
#endif
