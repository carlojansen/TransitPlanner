import SwiftUI
import TransitCore
import WidgetKit

struct NextTripEntry: TimelineEntry {
    let date: Date
    let trip: TripSnapshot.Trip?
}

extension TripSnapshot.Ride {
    /// Wie `Leg`: Ersatzverkehr immer als Bus, Badge nie doppelt "SEV".
    var displayMode: TransitMode { replacement ? .bus : mode }

    var badgeText: String {
        let name = line ?? displayMode.displayName
        guard replacement, !name.uppercased().hasPrefix("SEV") else { return name }
        return String(localized: "SEV \(name)")
    }
}

/// Eine Ansicht je Familie, alle aus demselben Eintrag. Tipp oeffnet die App (kein Deep Link: der Snapshot hat keine Trip-ID).
struct NextTripView: View {
    let entry: NextTripEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        Group {
            if let trip = entry.trip {
                content(trip)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(trip.spoken(at: entry.date, includeStops: !redaction.contains(.privacy)))
            } else {
                EmptyTripView(family: family)
            }
        }
        .containerBackground(Color(.surfaceCard), for: .widget)
    }

    @ViewBuilder private func content(_ trip: TripSnapshot.Trip) -> some View {
        switch family {
        case .accessoryCircular: CircularTripView(entry: entry, trip: trip)
        case .accessoryRectangular: RectangularTripView(entry: entry, trip: trip)
        case .systemMedium: MediumTripView(entry: entry, trip: trip)
        default: SmallTripView(entry: entry, trip: trip)
        }
    }
}

struct EmptyTripView: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "bell").font(.title3).accessibilityLabel("Keine Erinnerungen")
            }
        case .accessoryRectangular:
            Label("Keine Erinnerungen", systemImage: "bell").font(.footnote).minimumScaleFactor(0.6)
        default:
            VStack(spacing: 8) {
                Image(systemName: "bell")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Keine Erinnerungen")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
            }
        }
    }
}

/// Der eine Wert, um den es geht: Losgehen, Countdown oder Ankunft. Der Countdown laeuft ohne weitere Eintraege.
struct TripValue: View {
    let entry: NextTripEntry
    let trip: TripSnapshot.Trip

    var body: some View {
        switch trip.phase(at: entry.date) {
        case .later: Text(trip.leaveText(at: entry.date))
        case .soon: Text(timerInterval: entry.date...trip.leaveAt, countsDown: true)
        case .leaveNow: Text(ReminderText.title(.leave, warnMinutes: 0))
        case .riding: Text(trip.arrival, format: .clock)
        }
    }

    static func eyebrow(_ trip: TripSnapshot.Trip, at date: Date) -> LocalizedStringKey? {
        switch trip.phase(at: date) {
        case .later: "Losgehen"
        case .soon: trip.isEstimated ? "Los in ca." : "Los in"
        case .leaveNow: nil
        case .riding: "Ankunft"
        }
    }
}

/// Eyebrow und Wert; eine weggefallene Verbindung ersetzt beides, in Worten.
struct TripHead: View {
    let entry: NextTripEntry
    let trip: TripSnapshot.Trip

    var body: some View {
        if let lost = trip.lostText {
            Label(lost, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(.statusAlert))
                .minimumScaleFactor(0.6)
                .widgetAccentable()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let eyebrow = TripValue.eyebrow(trip, at: entry.date) {
                    Text(eyebrow).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                }
                TripValue(entry: entry, trip: trip)
                    .font(.title2.weight(.semibold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .widgetAccentable()
            }
        }
    }
}

/// Wie `LineBadge`. Getoent/Akzent faerbt Flaeche und Schrift gleich, dort also nur der Rand.
struct RideBadge: View {
    let ride: TripSnapshot.Ride
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.dynamicTypeSize) private var typeSize

    private var label: some View {
        HStack(spacing: 2) {
            // Bei AX braucht die Zeit neben dem Badge den Platz; der Name bleibt.
            if !typeSize.isAccessibilitySize { Image(systemName: ride.displayMode.symbolName) }
            Text(ride.badgeText)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.4)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    var body: some View {
        if renderingMode == .fullColor {
            label
                .foregroundStyle(Color(.labelOnAccent))
                .background(ride.displayMode.color, in: .rect(cornerRadius: 6, style: .continuous))
        } else {
            label
                .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(lineWidth: 1) }
                .widgetAccentable()
        }
    }
}

/// "3 Min. später" in Worten; Farbe ist nur Zugabe.
struct DelayLabel: View {
    let minutes: Int

    var body: some View {
        Text("\(minutes) Min. später")
            .foregroundStyle(Color(.statusWarn))
            .monospacedDigit()
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

struct SmallTripView: View {
    let entry: NextTripEntry
    let trip: TripSnapshot.Trip
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let ride = trip.ride(at: entry.date)
        VStack(alignment: .leading, spacing: 4) {
            if let ride { RideBadge(ride: ride) }
            Spacer(minLength: 0)
            TripHead(entry: entry, trip: trip).layoutPriority(1)
            Group {
                if let delay = trip.visibleDelay(at: entry.date) { DelayLabel(minutes: delay) }
                // Bei AX3 reicht die Flaeche nur fuer das Wichtigste.
                if !typeSize.isAccessibilitySize {
                    if let stop = ride?.from { Text("ab \(stop)").lineLimit(1).privacySensitive() }
                    if let platform = ride?.platformText { Text(platform).lineLimit(1) }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct MediumTripView: View {
    let entry: NextTripEntry
    let trip: TripSnapshot.Trip
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let limit = typeSize.isAccessibilitySize ? 2 : 3
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TripHead(entry: entry, trip: trip).layoutPriority(1)
                if let delay = trip.visibleDelay(at: entry.date) { DelayLabel(minutes: delay).font(.caption) }
                Spacer(minLength: 0)
                if let stop = trip.rides.last?.to {
                    Text("nach \(stop)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .privacySensitive()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(trip.rides.prefix(limit).enumerated()), id: \.offset) { _, ride in
                    RideRow(ride: ride)
                }
                if trip.rides.count > limit {
                    Text("und \(trip.rides.count - limit) weitere")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RideRow: View {
    let ride: TripSnapshot.Ride

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                RideBadge(ride: ride)
                // Die Zeit wird nie abgeschnitten, das Badge skaliert.
                if ride.cancelled {
                    Text("fällt aus").foregroundStyle(Color(.statusAlert)).fixedSize()
                } else if let departure = ride.departure {
                    Text(departure, format: .clock).monospacedDigit().contentTransition(.numericText()).fixedSize()
                }
            }
            if let stop = ride.from {
                Text(stop).font(.caption2).foregroundStyle(.secondary).privacySensitive()
            }
        }
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

struct RectangularTripView: View {
    let entry: NextTripEntry
    let trip: TripSnapshot.Trip
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let ride = trip.ride(at: entry.date)
        let delay = trip.visibleDelay(at: entry.date)
        let large = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let lost = trip.lostText {
                    Text(lost)
                } else {
                    HStack(spacing: 4) {
                        if let eyebrow = TripValue.eyebrow(trip, at: entry.date) { Text(eyebrow) }
                        TripValue(entry: entry, trip: trip).monospacedDigit().contentTransition(.numericText(countsDown: true))
                    }
                }
            }
            .font(.headline)
            .widgetAccentable()
            Text([ride?.badgeText, ride?.departure?.clockText, large ? nil : ride?.platformText].compactMap { $0 }.joined(separator: " · "))
                .monospacedDigit()
            // Drei Zeilen sind fest: die Verspaetung geht vor, bei AX steht das Gleis statt des Halts.
            if let delay {
                Text("\(delay) Min. später")
            } else if large, let platform = ride?.platformText {
                Text(platform)
            } else if !large, let stop = ride?.from {
                Text("ab \(stop)").privacySensitive()
            }
        }
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CircularTripView: View {
    let entry: NextTripEntry
    let trip: TripSnapshot.Trip

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: symbol).font(.caption2.weight(.semibold)).widgetAccentable()
                value
                    .font(.caption.weight(.semibold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .padding(4)
        }
    }

    private var symbol: String {
        if trip.status == .lost { return "exclamationmark.triangle.fill" }
        return trip.phase(at: entry.date) == .riding ? "flag.checkered" : "figure.walk"
    }

    @ViewBuilder private var value: some View {
        if trip.status == .lost {
            Text(trip.rides.contains(where: \.cancelled) ? "Ausfall" : "Anschluss")
        } else if trip.phase(at: entry.date) == .leaveNow {
            Text("Los")
        } else if trip.phase(at: entry.date) == .later {
            // Ohne "ca." und Wochentag: im Ring zaehlt die Uhrzeit.
            Text(trip.leaveAt, format: .clock)
        } else {
            TripValue(entry: entry, trip: trip)
        }
    }
}

#if DEBUG
enum WidgetSample {
    /// Ueber JSON wie die echte Datei; `TripSnapshot` hat bewusst keinen Init aus Einzelwerten.
    static func snapshot(status: String = "scheduled", leaveIn minutes: Double = 25, delay: Int? = 3, estimated: Bool = false,
                         cancelled: Bool = false, now: Date = Date()) -> TripSnapshot {
        func t(_ offset: Double) -> Double { now.addingTimeInterval(offset * 60).timeIntervalSinceReferenceDate }
        func ride(_ mode: String, _ line: String, _ from: String, _ to: String, _ start: Double, _ end: Double, _ platform: String?, _ planned: String?,
                  cancelled: Bool = false) -> String {
            let gleis = platform.map { #""platform":"\#($0)","plannedPlatform":"\#(planned ?? $0)","# } ?? ""
            return #"{"mode":"\#(mode)","replacement":false,"line":"\#(line)","direction":"\#(to)","from":"\#(from)","to":"\#(to)","departure":\#(t(start)),"plannedDeparture":\#(t(start)),"arrival":\#(t(end)),\#(gleis)"cancelled":\#(cancelled)}"#
        }
        let leave = minutes
        let rides = [ride("tram", "STR 704", "Düsseldorf Hbf", "Bilk S", leave + 6, leave + 16, "2", "1", cancelled: cancelled),
                     ride("regional", "RE 5", "Bilk S", "Köln Hbf", leave + 21, leave + 45, "9", "9"),
                     ride("bus", "134", "Köln Hbf", "Sülz Weyertal", leave + 50, leave + 62, nil, nil),
                     ride("tram", "9", "Sülz Weyertal", "Lindenthal", leave + 64, leave + 70, nil, nil)]
        let delayJSON = delay.map { #""delayMinutes":\#($0),"# } ?? ""
        let json = #"{"version":1,"trips":[{"leaveAt":\#(t(leave)),"firstDeparture":\#(t(leave + 6)),"arrival":\#(t(leave + 75)),"walkSeconds":240,\#(delayJSON)"status":"\#(status)","isEstimated":\#(estimated),"rides":[\#(rides.joined(separator: ","))]}]}"#
        return (try? JSONDecoder().decode(TripSnapshot.self, from: Data(json.utf8))) ?? .empty
    }

    static func entry(_ snapshot: TripSnapshot, at date: Date = Date()) -> NextTripEntry {
        NextTripEntry(date: date, trip: snapshot.trips.first)
    }
}

#Preview("Klein", as: .systemSmall) {
    NextTripWidget()
} timeline: {
    WidgetSample.entry(WidgetSample.snapshot())
    WidgetSample.entry(WidgetSample.snapshot(status: "lost", cancelled: true))
    NextTripEntry(date: .now, trip: nil)
}

#Preview("Mittel", as: .systemMedium) {
    NextTripWidget()
} timeline: {
    WidgetSample.entry(WidgetSample.snapshot())
    WidgetSample.entry(WidgetSample.snapshot(leaveIn: 300, estimated: true))
    NextTripEntry(date: .now, trip: nil)
}

#Preview("Rechteckig", as: .accessoryRectangular) {
    NextTripWidget()
} timeline: {
    WidgetSample.entry(WidgetSample.snapshot())
    NextTripEntry(date: .now, trip: nil)
}

#Preview("Rund", as: .accessoryCircular) {
    NextTripWidget()
} timeline: {
    WidgetSample.entry(WidgetSample.snapshot())
    NextTripEntry(date: .now, trip: nil)
}
#endif
