import SwiftUI
import TransitCore
import WidgetKit

@main
struct TransitPlannerWidgets: WidgetBundle {
    @WidgetBundleBuilder var body: some Widget {
        NextTripWidget()
        TripLiveActivity()
    }
}

/// Kein Netz, nur der Snapshot der App; Reihenfolge und Abstand kommen aus `TripSnapshot.timeline`.
struct NextTripProvider: TimelineProvider {
    private func read() -> TripSnapshot { TripSnapshotFile.read(TripSnapshotFile.sharedURL) }

    func placeholder(in context: Context) -> NextTripEntry { NextTripEntry(date: Date(), trip: nil) }

    func getSnapshot(in context: Context, completion: @escaping (NextTripEntry) -> Void) {
        let now = Date()
        completion(NextTripEntry(date: now, trip: read().timeline(now: now).first?.trip))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextTripEntry>) -> Void) {
        let now = Date()
        let entries = read().timeline(now: now).map { NextTripEntry(date: $0.date, trip: $0.trip) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(TripSnapshot.rereadInterval))))
    }
}

struct NextTripWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextTrip", provider: NextTripProvider()) { entry in
            NextTripView(entry: entry)
        }
        .configurationDisplayName("Nächste Fahrt")
        .description("Zeigt die nächste Fahrt aus deinen Erinnerungen. Fahrplandaten: Transitous, OpenStreetMap.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .systemSmall, .systemMedium])
    }
}
