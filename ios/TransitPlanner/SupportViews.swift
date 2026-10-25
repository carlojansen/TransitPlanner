import SwiftUI
import TransitCore

// MARK: - Inline-Banner (keine Alerts, AGENT.md Punkt 7)

struct InlineBanner: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.openURL) private var openURL
    let error: TransitError

    var body: some View {
        let message = error.errorDescription ?? ""
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                if let until = flow.blockedUntil {
                    let now = Date()
                    HStack(spacing: 4) {
                        Text("Wieder möglich in")
                        Text(timerInterval: now...max(now, until), countsDown: true)
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                let actions = flow.actions(for: error)
                if !actions.isEmpty {
                    HStack {
                        ForEach(actions, id: \.self) { action in
                            Button(action.title) {
                                if action == .openSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                } else {
                                    flow.perform(action)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("banner")
        .onAppear { AccessibilityNotification.Announcement(message).post() }
        .transition(.opacity)
    }

    private var symbol: String {
        switch error {
        case .offline: "wifi.slash"
        case .rateLimited: "hourglass"
        case .missingToken, .unauthorized, .keychainFailure: "key.fill"
        case .locationDenied, .locationUnavailable: "location.slash"
        case .pinningFailed: "lock.trianglebadge.exclamationmark"
        default: "exclamationmark.triangle.fill"
        }
    }
}

extension BannerAction {
    var title: LocalizedStringKey {
        switch self {
        case .retry: "Erneut versuchen"
        case .enterKey: "Schlüssel eintragen"
        case .openSettings: "Einstellungen"
        case .switchToStops: "Haltestelle suchen"
        case .newSearch: "Neu suchen"
        }
    }
}

// MARK: - Quellenangabe (RESEARCH-M3 Abschnitt 8)

/// Text und Links aus `attribution` der Antwort; nur https-Links.
struct AttributionFooter: View {
    let attribution: Attribution
    @State private var showsSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(attribution.text)
                .accessibilityIdentifier("attributionText")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { links }
                VStack(alignment: .leading, spacing: 0) { links }
            }
            Button("Quellen und Lizenzen") { showsSources = true }
                .frame(minHeight: 44)
                .contentShape(.rect)
                .accessibilityIdentifier("sourcesButton")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .sheet(isPresented: $showsSources) {
            NavigationStack {
                SourcesView(attribution: attribution)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { showsSources = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder private var links: some View {
        ForEach(attribution.httpsLinks, id: \.self) { link in
            Link(link.label, destination: link.url)
                .frame(minHeight: 44) // Touch-Flaeche (AGENT.md 4.3.1)
                .contentShape(.rect)
                .accessibilityIdentifier("attributionLink.\(link.label)")
        }
    }
}

struct SourcesView: View {
    let attribution: Attribution?

    var body: some View {
        List {
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
            if let attribution {
                Section {
                    Text(attribution.text)
                    ForEach(attribution.httpsLinks, id: \.self) { link in
                        Link(link.label, destination: link.url)
                    }
                } header: {
                    Text("Angabe der letzten Antwort")
                }
            }
        }
        .navigationTitle("Quellen und Lizenzen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StaticLink: View {
    let title: LocalizedStringKey
    let url: String

    var body: some View {
        if let destination = URL(string: url) { Link(title, destination: destination) }
    }
}

// MARK: - Einstellungen und Server-Schluessel (RESEARCH-M3 Abschnitt 5)

struct SettingsSheet: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ServerKeyView()
                    } label: {
                        LabeledContent("Dein Server", value: flow.hasServerKey ? String(localized: "Schlüssel gespeichert") : String(localized: "Schlüssel fehlt"))
                    }
                    .accessibilityIdentifier("serverKeyLink")
                }
                Section {
                    NavigationLink("Quellen und Lizenzen") { SourcesView(attribution: flow.attribution) }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}

struct ServerKeyView: View {
    @Environment(AppFlow.self) private var flow
    @State private var draft = ""
    @State private var problem: String?
    @State private var confirmsDelete = false

    var body: some View {
        Form {
            Section {
                if flow.hasServerKey {
                    Label("Schlüssel gespeichert", systemImage: "checkmark.seal.fill")
                        .accessibilityIdentifier("serverKeyStatus")
                } else {
                    Label("Kein Schlüssel gespeichert", systemImage: "key")
                        .accessibilityIdentifier("serverKeyStatus")
                }
            } footer: {
                Text("Der Schlüssel öffnet den Zugang zu deinem Fahrplan-Server. Er bleibt nur auf diesem iPhone im Schlüsselbund (ohne iCloud) und wird nicht wieder angezeigt.")
            }

            Section {
                // Kein .password-Content-Type: sonst bietet iOS an, den Schluessel im Passwoerter-Schluesselbund (iCloud) zu sichern.
                SecureField("Server-Schlüssel", text: $draft)
                    .textContentType(nil)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .accessibilityIdentifier("serverKeyField")
                PasteButton(payloadType: String.self) { items in
                    if let first = items.first {
                        Task { @MainActor in draft = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                }
                Button("Speichern", action: save)
                    .disabled(draft.isEmpty)
                    .accessibilityIdentifier("saveServerKey")
            } header: {
                Text(flow.hasServerKey ? "Schlüssel ersetzen" : "Schlüssel eintragen")
            } footer: {
                if let problem {
                    Text(problem).foregroundStyle(.red)
                } else {
                    Text("Nach dem Einfügen den Schlüssel aus der Zwischenablage des anderen Geräts entfernen.")
                }
            }

            if flow.hasServerKey {
                Section {
                    Button("Schlüssel löschen", role: .destructive) { confirmsDelete = true }
                }
            }
        }
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

    private func save() {
        guard let key = AppFlow.validatedServerKey(draft) else {
            problem = String(localized: "Der Schlüssel muss 32 bis 512 Zeichen lang sein, ohne Leerzeichen.")
            return
        }
        do {
            try flow.saveServerKey(key)
            draft = ""
            problem = nil
        } catch {
            problem = error.errorDescription
        }
    }
}
