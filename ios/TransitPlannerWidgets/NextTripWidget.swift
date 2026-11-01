import SwiftUI
import TransitCore
import WidgetKit

@main
struct TransitPlannerWidgets: WidgetBundle {
    var body: some Widget { NextTripWidget() }
}

struct NextTripEntry: TimelineEntry {
    let date: Date
    let hasTrip: Bool
}

/// Kein Netz, nur der Snapshot der App. Der Inhalt zeigt bewusst noch keine Fahrplandaten (Etappe 4).
struct NextTripProvider: TimelineProvider {
    private func entry(_ snapshot: TripSnapshot, at date: Date) -> NextTripEntry {
        NextTripEntry(date: date, hasTrip: !snapshot.upcoming(now: date).isEmpty)
    }

    func placeholder(in context: Context) -> NextTripEntry { NextTripEntry(date: Date(), hasTrip: false) }

    func getSnapshot(in context: Context, completion: @escaping (NextTripEntry) -> Void) {
        completion(entry(TripSnapshotFile.read(TripSnapshotFile.sharedURL), at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextTripEntry>) -> Void) {
        let now = Date()
        let snapshot = TripSnapshotFile.read(TripSnapshotFile.sharedURL)
        completion(Timeline(entries: [entry(snapshot, at: now)], policy: .after(snapshot.nextReload(now: now))))
    }
}

struct NextTripView: View {
    let entry: NextTripEntry

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: entry.hasTrip ? "bell.badge" : "bell")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(entry.hasTrip ? "Erinnerung gesetzt" : "Keine Erinnerungen")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct NextTripWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextTrip", provider: NextTripProvider()) { entry in
            NextTripView(entry: entry)
        }
        .configurationDisplayName("Nächste Fahrt")
        .description("Zeigt, ob eine Erinnerung gesetzt ist.")
        .supportedFamilies([.systemSmall])
    }
}
