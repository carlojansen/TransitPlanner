import PDFKit
import SwiftUI
import TransitCore

/// Vollbild-Anzeige des Tickets: heller Grund nur auf dem Inhalt, kein Teilen, kein Kopieren.
/// Solange die App nicht aktiv ist (App-Umschalter, Hintergrund), steht ein Platzhalter statt des Tickets.
struct TicketView: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemBackground).ignoresSafeArea()
            if scenePhase == .active, let ticket = flow.shownTicket {
                content(ticket)
            } else {
                Image(systemName: "ticket")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
            Button { flow.closeTicket() } label: {
                Label("Schließen", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 44, height: 44)
            }
            .padding(8)
            .accessibilityIdentifier("ticketClose")
        }
    }

    @ViewBuilder private func content(_ ticket: StoredTicket) -> some View {
        switch ticket.kind {
        case .image:
            if let image = UIImage(data: ticket.data) {
                // Weisser Grund hinter dem Bild: Codes lesen sich dort am besten.
                Image(uiImage: image).resizable().scaledToFit()
                    .background(Color.white)
                    .accessibilityLabel("Ticket")
                    .accessibilityIdentifier("ticketImage")
            }
        case .pdf:
            PDFContent(data: ticket.data)
                .accessibilityLabel("Ticket")
                .accessibilityIdentifier("ticketPDF")
        }
    }
}

private struct PDFContent: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(data: data)
        view.autoScales = true
        view.backgroundColor = .white
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

/// Knopf in der Leiste: nur mit lesbarem Ticket und offener Route (Regel im Modell: `offersTicket`).
struct TicketButton: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        if flow.offersTicket {
            Button { flow.showTicket() } label: {
                Label("Ticket zeigen", systemImage: "ticket")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("ticketButton")
        }
    }
}
