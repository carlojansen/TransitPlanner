import SwiftUI
import TransitCore

/// D1 Erinnerung einrichten (DESIGN.md): oben das Ergebnis, darunter die Rechnung, "Früher losgehen" als Hauptelement,
/// "Vorwarnen" getrennt davon. Mitteilungs-Erlaubnis erst beim Scharfschalten.
struct ReminderSheet: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.dismiss) private var dismiss
    let index: Int
    @State private var earlierMinutes: Int
    @State private var warnMinutes: Int
    @State private var failure: String?
    /// Verbindung beim Oeffnen: aendert sich die Liste darunter (Neu laden, Kalibrierung), gilt der Index nicht mehr.
    @State private var openedToken: String?

    static let earlierChoices = [0, 5, 10, 15, 20]
    private static let warnChoices = [0, 5, 10]

    /// Startwerte von aussen statt in `onAppear`: eine Aenderung dort loeste beim Oeffnen die Haptik aus.
    /// Ohne gespeicherte Erinnerung "Vorwarnen" T-5 aus D3.
    init(index: Int, earlierMinutes: Int = 0, warnMinutes: Int? = nil) {
        self.index = index
        _earlierMinutes = State(initialValue: earlierMinutes)
        _warnMinutes = State(initialValue: warnMinutes ?? 5)
    }

    private var timeToLeave: TimeToLeave? {
        guard let calibrated = flow.calibratedJourney(at: index) else { return nil }
        return try? flow.reminders.scheduler.timeToLeave(for: calibrated)
    }

    /// Losgehen laut Rueckwaertsrechnung, um "frueher losgehen" verschoben.
    private var leaveAt: Date? { timeToLeave.map { $0.leaveAt.addingTimeInterval(-TimeInterval(earlierMinutes * 60)) } }
    /// Wie `ReminderPlan.nextAlarm`: eine Vorwarnung in der Vergangenheit kommt nicht mehr, dann zaehlt das Losgehen.
    private var reminderAt: Date? {
        leaveAt.map { leave in
            let warn = leave.addingTimeInterval(-TimeInterval(warnMinutes * 60))
            return warn > flow.now ? warn : leave
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                result
                calculation
                choice(title: "Früher losgehen", footer: "Rechnet sofort neu.", values: Self.earlierChoices, selection: $earlierMinutes, step: 5)
                choice(title: "Vorwarnen", footer: "Zum Losgehen selbst kommt immer eine Mitteilung.", values: Self.warnChoices, selection: $warnMinutes, step: 5)
                if let failure {
                    CardHint(text: failure, tone: .alert)
                        .onAppear { AccessibilityNotification.Announcement(failure).post() }
                        .id(failure)
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
        .onAppear {
            openedToken = flow.journey(at: index)?.refreshToken
        }
        .onChange(of: flow.journey(at: index)?.refreshToken) { _, token in
            if let openedToken, token != openedToken { dismiss() }
        }
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
                            .contentTransition(.numericText())
                            .animation(Motion.micro, value: selection.wrappedValue)
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
        guard let leaveAt else { return }
        guard await flow.reminders.requestAuthorization() else {
            failure = String(localized: "Mitteilungen sind aus. Erlaube sie in den iOS-Einstellungen.")
            return
        }
        guard leaveAt > flow.now else {
            failure = String(localized: "Der Zeitpunkt zum Losgehen ist schon vorbei.")
            return
        }
        do throws(TransitError) {
            try await flow.setReminder(forJourney: index, earlierMinutes: earlierMinutes, warnMinutes: warnMinutes)
            dismiss()
        } catch {
            failure = error.errorDescription
        }
    }
}

// MARK: - D2 Erinnerungen

/// Liste ueber den Kartenknopf: "ca.", solange nicht neu berechnet; heute aktive mit Echtzeit-Delta; Loeschen per Wischen
/// ohne Rueckfrage, mit Rueckgaengig im Banner.
struct RemindersSheet: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            Group {
                if flow.reminders.rows.isEmpty {
                    ContentUnavailableView("Keine Erinnerungen", systemImage: "bell",
                                           description: Text("Tippe in einer Verbindung auf Erinnern."))
                } else {
                    List(flow.reminders.rows) { reminder in
                        ReminderRow(reminder: reminder)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Löschen", systemImage: "trash", role: .destructive) { flow.reminders.delete(reminder.id) }
                            }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle(Text("Erinnerungen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if let error = flow.reminders.failure {
                        InlineBanner(error: error).id(error).transition(bannerTransition)
                    }
                    if flow.reminders.undo != nil { UndoBanner().transition(bannerTransition) }
                }
            }
            .animation(Motion.standard, value: flow.reminders.undo != nil)
            .animation(Motion.standard, value: flow.reminders.failure)
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear { flow.reminders.clearFailure() }
    }

    private var bannerTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
}

/// Listenzeile (DESIGN.md 4): Symbol in Modusfarbe, Titel, Untertitel, Zeit rechts; bei AX untereinander.
private struct ReminderRow: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.dynamicTypeSize) private var typeSize
    let reminder: StoredReminder

    private var plan: ReminderPlan { reminder.plan }
    private var vehicle: Leg? { plan.journey.legs.first { !$0.isWalk } }

    private var detail: String {
        guard let vehicle else { return String(localized: "Fußweg") }
        return [vehicle.badgeName, vehicle.origin.name, vehicle.departurePlatform.map { String(localized: "Gleis \($0)") }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var time: String {
        let clock = plan.leaveAt.clockText
        let text = plan.isEstimated ? String(localized: "ca. \(clock)") : clock
        guard !Calendar.current.isDate(plan.leaveAt, inSameDayAs: flow.now) else { return text }
        return plan.leaveAt.formatted(.dateTime.weekday(.abbreviated).day().month(.twoDigits)) + ", " + text
    }

    /// Echtzeit-Delta nur fuer heute aktive.
    private var delay: Int? { plan.isActive(now: flow.now) ? plan.delayMinutes : nil }

    private var spoken: String {
        let change = delay.map { String(localized: "\($0) Minuten später") }
        return [reminder.request.destination.label, String(localized: "Losgehen \(time)"), change, detail]
            .compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                                      : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Image(systemName: vehicle?.displayMode.symbolName ?? "figure.walk")
                    .foregroundStyle(vehicle?.displayMode.color ?? Color(.modeWalk))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reminder.request.destination.label).font(.body)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                    Text(time)
                        .font(.footnote).monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(Motion.micro, value: time)
                    if let delay { DelayBadge(minutes: delay) }
                }
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(spoken))
            if plan.status == .lost { LostReminderHint(reminder: reminder) }
        }
        .padding(.vertical, 4)
    }
}

/// Hinweis Kritisch (C 4b): die Verbindung faellt weg. Der Wecker bleibt stehen, die Wahl trifft der Nutzer.
struct LostReminderHint: View {
    @Environment(AppFlow.self) private var flow
    let reminder: StoredReminder

    var body: some View {
        let text = String(localized: "Verbindung um \(reminder.plan.scheduled.firstDeparture.clockText) fällt aus oder der Anschluss reicht nicht.")
        VStack(alignment: .leading, spacing: 8) {
            CardHint(text: text, symbol: "xmark.octagon.fill", tone: .alert)
            // Rahmen im Label (sonst bleibt die Tippflaeche kleiner), borderless: in der Liste nicht die ganze Zeile.
            Button { flow.nextConnection(for: reminder) } label: {
                Label("Nächste Verbindung", systemImage: "arrow.triangle.branch")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
                .buttonStyle(.borderless)
                .disabled(flow.blockedUntil != nil)
                .accessibilityIdentifier("reminderNextConnection")
        }
        .onAppear { AccessibilityNotification.Announcement(text).post() }
    }
}

/// Inline-Banner (Radius 14, Innenabstand 12) fuer die 5 Sekunden nach dem Loeschen.
private struct UndoBanner: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        let message = String(localized: "Erinnerung gelöscht")
        HStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tone.info.foreground)
                .accessibilityHidden(true)
            Text(message).font(.subheadline).foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button { Task { await flow.reminders.undoDelete() } } label: {
                Text("Rückgängig")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                    .contentShape(.rect)
            }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("undoDelete")
        }
        .padding(12)
        .background(Tone.info.tint, in: .rect(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear { AccessibilityNotification.Announcement(message).post() }
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
#Preview("Erinnerungen", traits: .modifier(PreviewFlow.reminders)) {
    PreviewSheetBackdrop { RemindersSheet() }
}
#Preview("Erinnerungen, AX3", traits: .modifier(PreviewFlow.reminders)) {
    PreviewSheetBackdrop { RemindersSheet() }.dynamicTypeSize(.accessibility3)
}
#Preview("Erinnerungen, leer", traits: .modifier(PreviewFlow.start)) {
    PreviewSheetBackdrop { RemindersSheet() }
}
/// Ohne Kalibrierung (Planung laeuft noch): kein Ergebnis, "Erinnerung setzen" deaktiviert.
#Preview("Erinnern, ohne Rechnung", traits: .modifier(PreviewFlow.loading)) {
    PreviewSheetBackdrop { ReminderSheet(index: 0) }
}
#endif
