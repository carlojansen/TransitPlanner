import SwiftUI
import TransitCore
import UserNotifications

/// D1 Erinnerung einrichten (DESIGN.md): oben das Ergebnis, darunter die Rechnung, "Früher losgehen" als Hauptelement,
/// "Vorwarnen" getrennt davon. Mitteilungs-Erlaubnis erst beim Scharfschalten.
struct ReminderSheet: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.dismiss) private var dismiss
    let index: Int
    @State private var earlierMinutes = 0
    @State private var warnMinutes = 0
    @State private var failure: String?

    private static let earlierChoices = [0, 5, 10, 15, 20]
    private static let warnChoices = [0, 5, 10]

    private var timeToLeave: TimeToLeave? {
        guard let calibrated = flow.calibratedJourney(at: index) else { return nil }
        return try? DepartureScheduler().timeToLeave(for: calibrated)
    }

    /// Losgehen laut Rueckwaertsrechnung, um "frueher losgehen" verschoben.
    private var leaveAt: Date? { timeToLeave.map { $0.leaveAt.addingTimeInterval(-TimeInterval(earlierMinutes * 60)) } }
    private var reminderAt: Date? { leaveAt.map { $0.addingTimeInterval(-TimeInterval(warnMinutes * 60)) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                result
                calculation
                choice(title: "Früher losgehen", footer: "Rechnet sofort neu.", values: Self.earlierChoices, selection: $earlierMinutes, step: 5)
                choice(title: "Vorwarnen", footer: "Zum Losgehen selbst kommt immer eine Mitteilung.", values: Self.warnChoices, selection: $warnMinutes, step: 5)
                if let failure {
                    CardHint(text: failure, tone: .alert)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 8)
        }
        .background(Color(.surfaceSheet))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                SecondaryButton(title: "Abbrechen") { dismiss() }
                    .fixedSize(horizontal: true, vertical: false)
                PrimaryButton(title: "Erinnerung setzen", systemImage: "bell.fill") { Task { await schedule() } }
                    .disabled(reminderAt == nil)
                    .accessibilityIdentifier("setReminder")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: earlierMinutes)
        .sensoryFeedback(.selection, trigger: warnMinutes)
    }

    // MARK: Ergebnis

    private var result: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ERINNERN").font(.caption2.weight(.semibold)).foregroundStyle(Color(.labelSecondary))
            if let leaveAt {
                Text("Losgehen \(leaveAt.clockText)")
                    .font(.title.bold()).fontDesign(.rounded).monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }
            if let reminderAt {
                Text("Erinnerung um \(reminderAt.clockText)")
                    .font(.subheadline).foregroundStyle(Color(.labelSecondary)).monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .animation(Motion.micro, value: earlierMinutes + warnMinutes)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Rechnung

    @ViewBuilder private var calculation: some View {
        if let t = timeToLeave {
            ContentCard {
                VStack(spacing: 0) {
                    line("Abfahrt", t.firstDeparture.clockText)
                    Divider()
                    line("Gehweg", "\(max(1, Int((Double(t.walkSeconds) / 60).rounded(.up)))) Min.")
                    Divider()
                    line("Am Gleis sein vorher", "\(t.bufferSeconds / 60) Min.")
                }
            }
            .padding(.vertical, -4)
        }
    }

    private func line(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).font(.body)
            Spacer()
            Text(value).font(.body).foregroundStyle(Color(.labelSecondary)).monospacedDigit()
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    // MARK: Auswahl

    /// Stepper in 5-Minuten-Schritten plus Schnellwahl.
    private func choice(title: LocalizedStringKey, footer: LocalizedStringKey, values: [Int], selection: Binding<Int>, step: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
            ContentCard {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper(value: selection, in: 0...60, step: step) {
                        Text("\(selection.wrappedValue) Min.").font(.body).monospacedDigit()
                    }
                    HStack(spacing: 6) {
                        ForEach(values, id: \.self) { value in
                            let on = selection.wrappedValue == value
                            Button { withAnimation(Motion.micro) { selection.wrappedValue = value } } label: {
                                Text("\(value)")
                                    .font(.footnote.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(on ? Color(.labelOnAccent) : Color.primary)
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .background(on ? Color(.buttonFill) : Color(.fillTertiary), in: .capsule)
                                    .padding(.vertical, 5)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                            .accessibilityLabel(Text("\(value) Minuten"))
                        }
                    }
                }
            }
            Text(footer).font(.footnote).foregroundStyle(Color(.labelSecondary))
        }
    }

    // MARK: Scharfschalten

    /// Mitteilungs-Erlaubnis erst hier; lokale Mitteilungen, nichts geht an den Server.
    private func schedule() async {
        guard let leaveAt, let reminderAt, let journey = flow.journey(at: index) else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
            failure = String(localized: "Mitteilungen sind aus. Erlaube sie in den iOS-Einstellungen.")
            return
        }
        let line = journey.legs.first { !$0.isWalk }
        let body = [line?.badgeName, line?.origin.name, line?.departurePlatform.map { String(localized: "Gleis \($0)") }]
            .compactMap { $0 }.joined(separator: " · ")
        guard leaveAt > .now else {
            failure = String(localized: "Der Zeitpunkt zum Losgehen ist schon vorbei.")
            return
        }
        func request(_ title: String, at date: Date, id: String) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
            return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        }
        do {
            flow.clearReminder()
            if warnMinutes > 0, reminderAt > .now {
                try await center.add(request(String(localized: "Gleich losgehen: \(leaveAt.clockText)"), at: reminderAt, id: AppFlow.reminderIdentifiers[0]))
            }
            try await center.add(request(String(localized: "Jetzt losgehen"), at: leaveAt, id: AppFlow.reminderIdentifiers[1]))
            flow.setReminder(at: reminderAt, forJourney: index)
            dismiss()
        } catch {
            failure = String(localized: "Erinnerung konnte nicht gesetzt werden.")
        }
    }
}

#if DEBUG
// MARK: - Vorschau (Mock-Daten und Flow aus PreviewSupport.swift)

#Preview("Erinnern, Hell", traits: .modifier(PreviewFlow.routes(PreviewData.long))) {
    PreviewSheetBackdrop { ReminderSheet(index: 0) }
}
#Preview("Erinnern, Dunkel", traits: .modifier(PreviewFlow.routes(PreviewData.long))) {
    PreviewSheetBackdrop { ReminderSheet(index: 0) }.preferredColorScheme(.dark)
}
#Preview("Erinnern, AX3", traits: .modifier(PreviewFlow.routes(PreviewData.long))) {
    PreviewSheetBackdrop { ReminderSheet(index: 0) }.dynamicTypeSize(.accessibility3)
}
/// Ohne Kalibrierung (Planung laeuft noch): kein Ergebnis, "Erinnerung setzen" deaktiviert.
#Preview("Erinnern, ohne Rechnung", traits: .modifier(PreviewFlow.loading)) {
    PreviewSheetBackdrop { ReminderSheet(index: 0) }
}
#endif
