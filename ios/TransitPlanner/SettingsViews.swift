import PhotosUI
import SwiftUI
import TransitCore
import UniformTypeIdentifiers

// MARK: - A1 / A2 Erster Start

struct OnboardingView: View {
    @Environment(AppFlow.self) private var flow
    let step: OnboardingStep

    var body: some View {
        switch step {
        case .welcome: WelcomeView()
        case .serverKey:
            NavigationStack {
                ServerKeyView()
                    .safeAreaInset(edge: .bottom) {
                        PrimaryButton(title: flow.hasServerKey ? "Weiter" : "Später eintragen") { flow.finishServerKeyStep() }
                            .accessibilityIdentifier("onboardingDone")
                            .padding(16)
                    }
            }
        }
    }
}

/// A1: ein Bildschirm, ueberspringbar; Mitteilungen werden hier nicht abgefragt.
private struct WelcomeView: View {
    @Environment(AppFlow.self) private var flow
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Willkommen bei TransitPlanner")
                    .font(.largeTitle.bold())
                    .padding(.top, 48)
                feature("location.fill", "Fußwege mit deinem Tempo",
                        "Dein Standort bleibt auf dem iPhone. Der Fahrplan-Server bekommt nur eine gerundete Koordinate.")
                feature("tram.fill", "Nahverkehr und Regio",
                        "Straßenbahn, Bus, U- und S-Bahn und Regionalzüge mit Echtzeit, wo verfügbar.")
                feature("bell.badge", "Rechtzeitig los",
                        "Erinnerungen fragst du erst, wenn du die erste einrichtest.")
            }
            .padding(.horizontal, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                PrimaryButton(title: "Weiter") {
                    busy = true
                    Task { await flow.finishWelcome(allowLocation: true) }
                }
                .disabled(busy)
                .accessibilityIdentifier("welcomeContinue")
                Button("Ohne Standort fortfahren") {
                    Task { await flow.finishWelcome(allowLocation: false) }
                }
                .frame(minHeight: 44)
                .disabled(busy)
                .accessibilityIdentifier("welcomeWithoutLocation")
            }
            .padding(16)
        }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(.accentBlue))
                .font(.title)
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - A2 Dein Server

struct ServerKeyView: View {
    @Environment(AppFlow.self) private var flow
    @State private var draft = ""
    @State private var problem: String?
    @State private var confirmsDelete = false
    @State private var replacing = false

    var body: some View {
        Form {
            Section {
                Text("Die App fragt Fahrpläne über deinen eigenen Server ab. Der Schlüssel zeigt dem Server, dass die Anfrage von dir kommt.")
                    .font(.subheadline)
            }
            if flow.hasServerKey && !replacing {
                saved
            } else {
                entry
            }
        }
        .scrollContentBackground(.hidden)
        // Entwurf nicht im Speicher halten, wenn der Nutzer die Seite ohne Speichern verlaesst.
        .onDisappear { draft = "" }
        .navigationTitle("Dein Server")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Schlüssel löschen?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                do throws(TransitError) { try flow.deleteServerKey() } catch { problem = error.errorDescription }
            }
        } message: {
            Text("Ohne Schlüssel kann die App keine Haltestellen und Verbindungen abrufen.")
        }
    }

    @ViewBuilder private var saved: some View {
        Section {
            Label("Schlüssel gespeichert", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color(.statusOk))
                .accessibilityIdentifier("serverKeyStatus")
            Button("Verbindung prüfen") { Task { await flow.checkConnection() } }
                .frame(minHeight: 44)
                .disabled(flow.connectionCheck == .checking)
                .accessibilityIdentifier("checkConnection")
            if let check = flow.connectionCheck { checkResult(check) }
            Button("Schlüssel ersetzen") { replacing = true }
                .frame(minHeight: 44)
        } footer: {
            Text("Der Schlüssel liegt nur auf diesem iPhone im Schlüsselbund (ohne iCloud) und wird nicht wieder angezeigt.")
        }
        Section {
            Button("Schlüssel löschen", role: .destructive) { confirmsDelete = true }
                .frame(minHeight: 44)
        }
    }

    @ViewBuilder private func checkResult(_ check: ConnectionCheck) -> some View {
        switch check {
        case .checking:
            Label("Wird geprüft", systemImage: "antenna.radiowaves.left.and.right")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(.secondary)
        case .connected:
            Label("Verbunden", systemImage: "checkmark.circle.fill").foregroundStyle(Color(.statusOk))
                .accessibilityIdentifier("connectionResult")
        case .failed(let error):
            Label(error.errorDescription ?? "", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(error == .unauthorized ? Color(.statusAlert) : Color(.statusWarn))
                .accessibilityIdentifier("connectionResult")
        }
    }

    @ViewBuilder private var entry: some View {
        Section {
            // Kein .password-Content-Type: sonst bietet iOS an, den Schluessel im Passwoerter-Schluesselbund (iCloud) zu sichern.
            SecureField("Schlüssel", text: $draft)
                .textContentType(nil)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.done)
                .onSubmit(save)
                .frame(minHeight: 44)
                .accessibilityIdentifier("serverKeyField")
            PasteButton(payloadType: String.self) { items in
                if let first = items.first {
                    Task { @MainActor in draft = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
            Button("Speichern", action: save)
                .frame(minHeight: 44)
                .disabled(draft.isEmpty)
                .accessibilityIdentifier("saveServerKey")
        } header: {
            Text(flow.hasServerKey ? "Schlüssel ersetzen" : "Schlüssel eintragen")
        } footer: {
            if let problem {
                Text(problem).foregroundStyle(Color(.statusAlert))
            } else {
                Text("Nach dem Einfügen den Schlüssel aus der Zwischenablage des anderen Geräts entfernen.")
            }
        }
    }

    private func save() {
        guard let key = AppFlow.validatedServerKey(draft) else {
            problem = String(localized: "Der Schlüssel muss 32 bis 512 Zeichen lang sein, ohne Leerzeichen.")
            return
        }
        do {
            try flow.saveServerKey(key)
            draft = ""
            problem = nil
            replacing = false
        } catch {
            problem = error.errorDescription
        }
    }
}

// MARK: - G1 Einstellungen

struct SettingsSheet: View {
    enum Route: Hashable { case server, ticket, sources, report }

    @Environment(AppFlow.self) private var flow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var path: [Route]

    init(opensServer: Bool) {
        _path = State(initialValue: opensServer ? [.server] : [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // Gehtempo, Verkehrsmittel und Mitteilungen folgen, sobald sie etwas bewirken.
                Section {
                    Button { openSystemSettings() } label: {
                        SettingsRow(title: "Standort", value: locationValue, chevron: true)
                    }
                    .accessibilityIdentifier("locationSettingsRow")
                    NavigationLink(value: Route.server) {
                        SettingsRow(title: "Dein Server",
                                    value: flow.hasServerKey ? String(localized: "Schlüssel gespeichert") : String(localized: "Schlüssel fehlt"))
                    }
                    .accessibilityIdentifier("serverKeyLink")
                    NavigationLink(value: Route.ticket) {
                        SettingsRow(title: "Ticket",
                                    value: flow.shownTicket != nil ? String(localized: "Gespeichert")
                                        : flow.hasUnreadableTicket ? String(localized: "Nicht lesbar") : String(localized: "Kein Ticket"))
                    }
                    .accessibilityIdentifier("ticketLink")
                }
                .buttonStyle(.plain)
                Section {
                    StepFreeToggle()
                } footer: {
                    Text("Wege zu und zwischen den Fahrzeugen meiden Treppen und nutzen Aufzüge. Ob ein Fahrzeug selbst barrierefrei ist, steht nicht zuverlässig in den Daten.")
                }
                Section {
                    StationBufferStepper()
                } footer: {
                    Text("Gilt für neue Erinnerungen, bestehende übernehmen den Wert bei der nächsten Neuberechnung. Bei 0 Min. entfällt „Später erinnern“ in der Losgehen-Mitteilung, außer du gehst früher los. Umstiege bewertet die App davon unabhängig.")
                }
                if flow.offersReport {
                    Section {
                        NavigationLink(value: Route.report) { SettingsRow(title: "Bericht senden") }
                            .accessibilityIdentifier("reportLink")
                    } footer: {
                        Text("Für Tester: ein anonymer Bericht über knappe Abfahrten, späte Vorschläge, Ankünfte, Abstürze und deine Markierungen (Knopf auf der Karte). Du siehst ihn vor dem Teilen.")
                    }
                }
                Section {
                    NavigationLink(value: Route.sources) { SettingsRow(title: "Quellen und Lizenzen") }
                    SettingsRow(title: "Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .server: ServerKeyView()
                case .ticket: TicketSettingsView()
                case .sources: SourcesView(attribution: flow.attribution)
                case .report: ReportView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                        .accessibilityIdentifier("settingsDone")
                }
            }
        }
        .presentationDetents([.large])
        .task { await flow.detectTestFlight() }
        .task { await flow.loadTickets() }
    }

    /// Echter iOS-Status (wird bei Rueckkehr in die App neu gelesen).
    private var locationValue: String {
        switch flow.locationAuthorization {
        case .allowed: String(localized: "Beim Verwenden")
        case .denied: String(localized: "Aus")
        case .notDetermined: String(localized: "Nicht gefragt")
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

// MARK: - Bericht senden (TestFlight)

/// Vorschau der Berichtsdatei und Teilen ueber das System-Menue. Nichts verlaesst das Geraet ohne diesen Schritt.
struct ReportView: View {
    @Environment(AppFlow.self) private var flow
    @State private var file: URL?
    @State private var text = ""
    /// Datei liess sich nicht schreiben: nicht als "leer" ausgeben, sonst glaubt der Tester, es gebe nichts zu senden.
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView("Bericht nicht erstellt", systemImage: "exclamationmark.triangle",
                                       description: Text("Die Datei ließ sich nicht schreiben. Versuche es später noch einmal."))
            } else if flow.caseCount == 0 {
                ContentUnavailableView("Noch nichts aufgezeichnet", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Die App notiert knappe oder späte Fälle unterwegs, Abstürze und deine Markierungen über den Knopf auf der Karte."))
            } else {
                List {
                    if let file {
                        Section {
                            ShareLink(item: file) { Label("Bericht teilen", systemImage: "square.and.arrow.up") }
                                .accessibilityIdentifier("reportShare")
                        } footer: {
                            Text("Enthält nur Zahlen, Uhrzeit auf 5 Minuten und Ort auf etwa 1 km gerundet. Keine Namen, Adressen oder Geräte-Kennung.")
                        }
                    }
                    Section {
                        Button("Protokoll löschen", role: .destructive) {
                            flow.clearCaseLog()
                            if let file { try? FileManager.default.removeItem(at: file) }
                            file = nil
                            text = ""
                        }
                        .accessibilityIdentifier("reportClear")
                    }
                    Section {
                        Text(text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } header: {
                        Text("Vorschau")
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Bericht senden")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard flow.caseCount > 0 else { return }
            file = flow.writeReport()
            failed = file == nil
            text = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        }
        .onDisappear { if let file { try? FileManager.default.removeItem(at: file) } }
    }
}

// MARK: - G2 Quellen und Lizenzen

struct SourcesView: View {
    let attribution: Attribution?

    var body: some View {
        List {
            if let attribution {
                Section {
                    Text(attribution.text)
                    ForEach(attribution.httpsLinks, id: \.self) { link in
                        Link(destination: link.url) { linkLabel(link.label) }
                    }
                } header: {
                    Text("Angabe des Fahrplan-Servers")
                }
            }
            Section {
                Text("Offene Fahrplan- und Echtzeitdaten über Transitous (MOTIS 2), u. a. DELFI.")
                StaticLink(title: "Transitous-Datenquellen", url: "https://transitous.org/sources/")
            } header: {
                Text("Fahrplandaten")
            }
            Section {
                Text("© OpenStreetMap-Mitwirkende, verfügbar unter der Open Database License (ODbL).")
                StaticLink(title: "OpenStreetMap-Copyright", url: "https://www.openstreetmap.org/copyright")
            } header: {
                Text("Karten- und Wegdaten")
            }
            Section {
                Text("Gehzeiten berechnet Apple Karten auf dem Gerät. Die Karte stammt von Apple.")
            } header: {
                Text("Fußwege")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Quellen und Lizenzen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func linkLabel(_ title: String) -> some View {
    HStack {
        Text(title)
        Spacer()
        Image(systemName: "arrow.up.right").foregroundStyle(.secondary).accessibilityHidden(true)
    }
    .frame(minHeight: 44)
    .contentShape(.rect)
}

private struct StaticLink: View {
    let title: String
    let url: String

    var body: some View {
        if let destination = URL(string: url) { Link(destination: destination) { linkLabel(title) } }
    }
}

/// Stufenfrei reisen: ein Schalter, gilt fuer die naechste Suche (Einstellungen und Planen teilen den Wert).
struct StepFreeToggle: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        @Bindable var flow = flow
        Toggle("Stufenfrei reisen", isOn: Binding { flow.accessibility == .stepFree } set: { flow.accessibility = $0 ? .stepFree : .none })
            .accessibilityIdentifier("stepFreeToggle")
    }
}

/// Am Gleis sein vorher: globaler Puffer vor dem ersten Fahrzeug, in D1 nur angezeigt.
private struct StationBufferStepper: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        @Bindable var reminders = flow.reminders
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
        Stepper(value: $reminders.stationBufferMinutes, in: 0...15) {
            layout {
                Text("Am Gleis sein vorher")
                if !typeSize.isAccessibilitySize { Spacer() }
                Text("\(reminders.stationBufferMinutes) Min.")
                    .foregroundStyle(Color(.labelSecondary)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Motion.micro, value: reminders.stationBufferMinutes)
            }
        }
        .frame(minHeight: 44)
        .accessibilityValue(Text("\(reminders.stationBufferMinutes) Minuten"))
        .accessibilityIdentifier("stationBufferStepper")
    }
}

// MARK: - Ticket (nur zeigen, nie pruefen)

struct TicketSettingsView: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.scenePhase) private var scenePhase
    @State private var photo: PhotosPickerItem?
    @State private var picksFile = false
    @State private var confirmsDelete = false
    /// Der Fehler steht hier selbst: das Banner der Karte laege unter dem Sheet.
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Text("Dein Ticket liegt verschlüsselt nur auf diesem iPhone. Die App zeigt es nur, sie prüft es nicht.")
                    .font(.subheadline)
            }
            if let ticket = flow.shownTicket {
                Section("Gespeichert") {
                    preview(ticket)
                    Button("Ticket löschen", role: .destructive) { confirmsDelete = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("ticketDelete")
                }
            } else if flow.hasUnreadableTicket {
                Section {
                    Label("Das gespeicherte Ticket lässt sich nicht lesen.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(.statusWarn))
                    Button("Ticket löschen", role: .destructive) { confirmsDelete = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("ticketDelete")
                }
            }
            Section {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Foto wählen", systemImage: "photo").frame(minHeight: 44)
                }
                .accessibilityIdentifier("ticketPhoto")
                Button { picksFile = true } label: {
                    Label("Datei wählen", systemImage: "doc").frame(minHeight: 44)
                }
                .accessibilityIdentifier("ticketFile")
            } footer: {
                Text(flow.shownTicket == nil ? "Bild oder PDF bis 10 MB. Ein PDF wird als Bild gespeichert." : "Ein neues Ticket ersetzt das gespeicherte.")
            }
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(.statusWarn))
                        .accessibilityIdentifier("ticketProblem")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Ticket")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picksFile, allowedContentTypes: [.image, .pdf]) { result in
            Task { await importFile(result) }
        }
        .onChange(of: photo) {
            guard let item = photo else { return }
            photo = nil
            Task { await add { try? await item.loadTransferable(type: Data.self) } }
        }
        .confirmationDialog("Ticket löschen?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                Task {
                    for entry in flow.tickets { await flow.deleteTicket(entry.id) }
                    problem = nil
                }
            }
        } message: {
            Text("Du kannst es danach neu hinzufügen.")
        }
    }

    /// Wie in `TicketView`: nicht aktiv (App-Umschalter) heisst Platzhalter statt Ticket.
    @ViewBuilder private func preview(_ ticket: StoredTicket) -> some View {
        if scenePhase == .active, let image = UIImage(data: ticket.data) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxHeight: 220)
                .accessibilityLabel("Vorschau des Tickets")
        } else {
            Image(systemName: "ticket").font(.largeTitle).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80).accessibilityHidden(true)
        }
    }

    private func importFile(_ result: Result<URL, any Error>) async {
        guard case .success(let url) = result else { return } // Abbruch ist kein Fehler
        await add { try? await Task.detached { try TicketImport.load(url: url) }.value }
    }

    /// Daten holen (nil = nicht lesbar), speichern, Fehler hier zeigen.
    private func add(_ load: () async -> Data?) async {
        problem = nil
        guard let data = await load() else { problem = TransitError.ticketUnreadable.errorDescription; return }
        do throws(TransitError) { try await flow.addTicket(data) } catch { problem = error.errorDescription }
    }
}
