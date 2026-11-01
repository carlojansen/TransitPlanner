import Foundation
import Observation
import SwiftData
import Synchronization
import TransitCore
import UserNotifications

/// Gespeicherte Erinnerung. Der refreshToken liegt in der Keychain (`SecretKey.refreshToken(tripID:)`), nie hier.
struct StoredReminder: Identifiable, Hashable, Sendable {
    let id: UUID
    var request: ManualTripRequest
    var plan: ReminderPlan
}

protocol ReminderStoring: Sendable {
    /// Uebersteht einen Neustart? Sonst darf nichts scharfgeschaltet werden.
    var isDurable: Bool { get }
    @MainActor func all() -> [StoredReminder]
    /// Entfernt endgueltig unlesbare Zeilen und nennt ihre IDs. Ein voruebergehender Keychain-Fehler zaehlt nicht.
    /// Darum muessen neue Felder im Plan optional sein (`PlannedTrip.sealedPlan`), sonst fallen bestehende Erinnerungen hier weg.
    @MainActor func removeUnreadable() -> [UUID]
    @MainActor func save(_ reminder: StoredReminder) throws(TransitError)
    @MainActor func remove(_ id: UUID)
}

/// `UNUserNotificationCenter` hinter einem Protokoll (Tests, Previews).
protocol ReminderNotifying: Sendable {
    func requestAuthorization() async -> Bool
    func add(_ alerts: [ReminderAlert]) async throws(TransitError)
    func remove(_ identifiers: [String])
}

/// Alles liegt versiegelt in `PlannedTrip`; im Klartext nur die Zeit fuer die Sortierung.
@MainActor
final class SwiftDataReminders: ReminderStoring {
    nonisolated let isDurable = true
    /// Der Kontext haelt den Container nicht (siehe `SwiftDataPlaces`).
    private let container: ModelContainer
    private let context: ModelContext
    private let sealer: LocalSealer

    init(container: ModelContainer, sealer: LocalSealer) {
        self.container = container
        context = container.mainContext
        self.sealer = sealer
    }

    private func rows() -> [PlannedTrip] {
        (try? context.fetch(FetchDescriptor<PlannedTrip>(sortBy: [SortDescriptor(\.targetTime)]))) ?? []
    }

    func all() -> [StoredReminder] {
        // ponytail: entschluesselt auf dem MainActor beim Start; bei vielen Erinnerungen in einen Actor verlegen.
        rows().compactMap { row in
            guard let plan = try? row.plan(using: sealer), let request = try? row.request(using: sealer) else { return nil }
            return StoredReminder(id: row.id, request: request, plan: plan)
        }
    }

    func removeUnreadable() -> [UUID] {
        let broken = rows().filter { row in
            do throws(TransitError) {
                _ = try row.plan(using: sealer)
                _ = try row.request(using: sealer)
                return false
            } catch {
                return error == .decodingFailed
            }
        }
        let ids = broken.map(\.id)
        broken.forEach(context.delete)
        try? context.save()
        return ids
    }

    func save(_ reminder: StoredReminder) throws(TransitError) {
        if let row = rows().first(where: { $0.id == reminder.id }) {
            try row.update(reminder.plan, request: reminder.request, sealer: sealer)
        } else {
            context.insert(try PlannedTrip(id: reminder.id, request: reminder.request, plan: reminder.plan, sealer: sealer))
        }
        do { try context.save() } catch { throw .storageUnavailable }
    }

    func remove(_ id: UUID) {
        rows().filter { $0.id == id }.forEach(context.delete)
        try? context.save()
    }
}

/// Speicher nur im Arbeitsspeicher: Rueckfall ohne Store, Fake fuer Tests und Vorschauen.
final class MemoryReminders: ReminderStoring {
    private let items = Mutex<[StoredReminder]>([])
    /// Speichern scheitert (Tests).
    let failing = Mutex(false)
    let isDurable: Bool

    init(isDurable: Bool = true) { self.isDurable = isDurable }

    func all() -> [StoredReminder] { items.withLock { $0 } }
    func removeUnreadable() -> [UUID] { [] }
    func save(_ reminder: StoredReminder) throws(TransitError) {
        if failing.withLock({ $0 }) { throw .storageUnavailable }
        items.withLock { list in
            list.removeAll { $0.id == reminder.id }
            list.append(reminder)
        }
    }
    func remove(_ id: UUID) { items.withLock { $0.removeAll { $0.id == id } } }
}

struct SystemNotifier: ReminderNotifying {
    static let startAction = "reminder.start"
    static let snoozeAction = "reminder.snooze"
    private static let categoryID = "reminder"
    private static let tripKey = "tripID"

    /// "Starten" holt die App nach vorn, der Snooze laeuft ohne sie.
    static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryID, actions: [
            UNNotificationAction(identifier: startAction, title: String(localized: "Starten"), options: .foreground),
            UNNotificationAction(identifier: snoozeAction, title: String(localized: "Später erinnern (5 Min.)"), options: []),
        ], intentIdentifiers: [])
    }

    nonisolated static func tripID(of notification: UNNotification) -> UUID? {
        (notification.request.content.userInfo[tripKey] as? String).flatMap(UUID.init(uuidString:))
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
    }

    static func request(for alert: ReminderAlert, now: Date = Date()) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.interruptionLevel = alert.isTimeSensitive ? .timeSensitive : .active
        content.categoryIdentifier = categoryID
        content.userInfo = [tripKey: alert.tripID.uuidString]
        // Sekundenabstand statt Kalenderdatum: bleibt bei einem Zeitzonenwechsel richtig.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, alert.fireAt.timeIntervalSince(now)), repeats: false)
        return UNNotificationRequest(identifier: alert.identifier, content: content, trigger: trigger)
    }

    func add(_ alerts: [ReminderAlert]) async throws(TransitError) {
        for alert in alerts {
            do { try await UNUserNotificationCenter.current().add(Self.request(for: alert)) } catch { throw .internal }
        }
    }

    func remove(_ identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Mehrere Erinnerungen: Liste, Mitteilungen, Neuberechnung und Aufraeumen. Reine Logik in `ReminderPlan`.
@Observable @MainActor
final class ReminderCenter {
    /// Muss in `BGTaskSchedulerPermittedIdentifiers` stehen (project.yml).
    nonisolated static let backgroundTaskID = "de.carlojansen.transitplanner.reminder-refresh"

    struct Undo {
        let reminder: StoredReminder
        let token: Data?
    }

    /// Einzige Stelle fuer Widgets: jede Aenderung laeuft hier durch (`store`, `purge`).
    private(set) var rows: [StoredReminder] {
        didSet { publishSnapshot() }
    }
    /// Geloeschte Erinnerung samt Token, nur im RAM und nur fuer `deps.undoWindow`.
    private(set) var undo: Undo?
    /// Fehler aus der Liste (Rueckgaengig), als Inline-Banner in D2.
    private(set) var failure: TransitError?
    /// "Am Gleis sein vorher" (Einstellungen); neue Erinnerungen sofort, bestehende ab ihrer naechsten Neuberechnung.
    var stationBufferMinutes = DepartureScheduler.storedBufferMinutes {
        didSet { UserDefaults.standard.set(stationBufferMinutes, forKey: DepartureScheduler.bufferMinutesKey) }
    }

    var scheduler: DepartureScheduler { DepartureScheduler(stationBufferSeconds: stationBufferMinutes * 60) }

    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private var checking = false

    init(_ deps: AppDependencies) {
        self.deps = deps
        for id in deps.reminders.removeUnreadable() {
            try? deps.secrets.delete(.refreshToken(tripID: id))
            deps.notifier.remove(ReminderAlert.identifiers(id))
        }
        rows = deps.reminders.all().sorted { $0.plan.leaveAt < $1.plan.leaveAt }
        publishSnapshot()
    }

    var activeToday: Bool { rows.contains { $0.plan.isActive(now: deps.now()) } }

    /// Verbindung faellt weg und ist noch nicht abgefahren: Hinweis Kritisch in der App.
    var lost: StoredReminder? { rows.first { $0.plan.status == .lost && $0.plan.scheduled.firstDeparture > deps.now() } }

    func reminder(id: UUID) -> StoredReminder? { rows.first { $0.id == id } }

    func reminder(for journey: Journey) -> StoredReminder? {
        rows.first { $0.plan.calibrated.journey.isSameTrip(as: journey) }
    }

    func token(_ id: UUID) -> String? {
        (try? deps.secrets.read(.refreshToken(tripID: id))).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }
    }

    func requestAuthorization() async -> Bool { await deps.notifier.requestAuthorization() }

    /// Dieselbe Fahrt behaelt ihre ID (kein Duplikat, alte Mitteilungen werden ersetzt).
    func set(_ calibrated: CalibratedJourney, request: ManualTripRequest, attribution: Attribution,
             earlierMinutes: Int, warnMinutes: Int) async throws(TransitError) {
        guard deps.reminders.isDurable else { throw .storageUnavailable }
        let plan = try ReminderPlan(calibrated: calibrated.withRefreshToken(nil), earlierMinutes: earlierMinutes,
                                    warnMinutes: warnMinutes, attribution: attribution, scheduler: scheduler)
        let previous = reminder(for: calibrated.journey)
        let oldToken = previous.flatMap { token($0.id) }
        let reminder = StoredReminder(id: previous?.id ?? UUID(), request: request, plan: plan)
        do {
            if let token = calibrated.journey.refreshToken {
                try deps.secrets.write(Data(token.utf8), for: .refreshToken(tripID: reminder.id))
            }
            try store(reminder)
            try await replaceAlerts(of: reminder)
        } catch {
            if let previous {
                // Eine fehlgeschlagene Aenderung kostet nicht die bestehende Erinnerung.
                if let oldToken { try? deps.secrets.write(Data(oldToken.utf8), for: .refreshToken(tripID: previous.id)) }
                try? store(previous)
                let alerts = previous.plan.alerts(tripID: previous.id, now: deps.now())
                try? await deps.notifier.add(alerts)
                // Teilweises `add` des verworfenen Stands wieder entfernen; ein laufender Snooze gehoert zum alten Stand.
                let kept = Set(alerts.map(\.identifier) + [ReminderAlert.identifier(previous.id, .snooze)])
                deps.notifier.remove(ReminderAlert.identifiers(previous.id).filter { !kept.contains($0) })
            } else {
                purge(reminder.id)
            }
            throw error
        }
        failure = nil
        scheduleBackgroundCheck()
    }

    func clearFailure() { failure = nil }

    /// Ohne Rueckfrage; Rueckgaengig stellt alles wieder her.
    func delete(_ id: UUID) {
        guard let reminder = reminder(id: id) else { return }
        let token = (try? deps.secrets.read(.refreshToken(tripID: id))).flatMap { $0 }
        failure = nil
        purge(id)
        undo = Undo(reminder: reminder, token: token)
        undoTask?.cancel()
        let window = deps.undoWindow
        undoTask = Task {
            do { try await Task.sleep(for: window) } catch { return }
            undo = nil
        }
    }

    func undoDelete() async {
        guard let undo else { return }
        self.undo = nil
        undoTask?.cancel()
        do throws(TransitError) {
            try store(undo.reminder)
            if let token = undo.token { try deps.secrets.write(token, for: .refreshToken(tripID: undo.reminder.id)) }
            try await replaceAlerts(of: undo.reminder)
            failure = nil
            scheduleBackgroundCheck()
        } catch {
            purge(undo.reminder.id)
            failure = error
        }
    }

    func snooze(_ id: UUID) async {
        guard let plan = reminder(id: id)?.plan, let alert = plan.snoozeAlert(tripID: id, now: deps.now()) else { return }
        try? await deps.notifier.add([alert])
        // Waehrend `add` geloescht oder neu berechnet: dieser Snooze gilt nicht mehr.
        guard reminder(id: id)?.plan != plan else { return }
        deps.notifier.remove([alert.identifier])
        await snooze(id)
    }

    /// Beim Aktivwerden und im Hintergrund: Vergangenes aufraeumen, Faelliges nacheinander neu berechnen, naechsten Lauf
    /// anmelden. Fragt nur im Fenster ab T-30 und hoechstens alle 5 Min. je Fahrt (`ReminderPlan.refreshDue`).
    func checkDue() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        for reminder in rows where reminder.plan.isOver(now: deps.now()) { purge(reminder.id) }
        for id in rows.filter({ $0.plan.refreshDue(now: deps.now()) }).map(\.id) {
            // Retry-After beachten: lieber spaeter als gegen die Sperre.
            guard !Task.isCancelled, await deps.blockedUntil() == nil else { break }
            await check(id)
        }
        scheduleBackgroundCheck()
    }

    func scheduleBackgroundCheck() {
        deps.scheduleBackgroundCheck(rows.compactMap { $0.plan.nextCheck(now: deps.now()) }.min())
    }

    private func check(_ id: UUID) async {
        guard var reminder = reminder(id: id) else { return }
        // Auch ein Fehlversuch zaehlt fuer die Drosselung.
        reminder.plan.attemptedAt = deps.now()
        try? store(reminder)
        guard let token = token(id) else { return }
        do throws(TransitError) {
            let fresh = try await deps.refresh(token)
            // Waehrend der Anfrage geloescht: nichts wiederbeleben.
            guard var current = self.reminder(id: id) else { return }
            let replace = current.plan.apply(fresh, now: deps.now(), scheduler: scheduler) || current.plan.alertsPending == true
            current.plan.alertsPending = replace ? true : nil
            if let new = fresh.refreshToken, new != token { try deps.secrets.write(Data(new.utf8), for: .refreshToken(tripID: id)) }
            try store(current)
            // Der neue Stand bleibt auch ohne Mitteilungen: der Hinweis in der App haengt daran.
            if replace {
                try await replaceAlerts(of: current)
                if var done = self.reminder(id: id), done.plan.alertsPending == true {
                    done.plan.alertsPending = nil
                    try store(done)
                }
            }
        } catch .refreshExpired {
            guard var current = self.reminder(id: id) else { return }
            current.plan.markExpired()
            try? store(current)
        } catch {
            // Offline, Server: Wecker bleibt, der naechste Lauf versucht es wieder. Kein Banner fuer etwas, das niemand angestossen hat.
        }
    }

    /// Erst hinzufuegen (gleiche ID ersetzt bei iOS), dann Ueberzaehliges entfernen: scheitert `add`, bleibt der alte Wecker.
    /// Auch ein laufender Snooze geht: ersetzt wird nur bei geaendertem Stand, sein Text waere alt; T-0 traegt die Information.
    private func replaceAlerts(of reminder: StoredReminder) async throws(TransitError) {
        let alerts = reminder.plan.alerts(tripID: reminder.id, now: deps.now())
        try await deps.notifier.add(alerts)
        // `add` wartet: die Erinnerung kann inzwischen geloescht oder neu berechnet sein.
        guard let current = self.reminder(id: reminder.id) else {
            deps.notifier.remove(ReminderAlert.identifiers(reminder.id))
            return
        }
        guard current.plan == reminder.plan else { return try await replaceAlerts(of: current) }
        let kept = Set(alerts.map(\.identifier))
        deps.notifier.remove(ReminderAlert.identifiers(reminder.id).filter { !kept.contains($0) })
    }

    private func store(_ reminder: StoredReminder) throws(TransitError) {
        try deps.reminders.save(reminder)
        // In einem Zug: `didSet` soll keinen Zwischenstand veroeffentlichen.
        rows = (rows.filter { $0.id != reminder.id } + [reminder]).sorted { $0.plan.leaveAt < $1.plan.leaveAt }
    }

    /// Vergleich mit der Datei, nicht mit dem letzten Aufruf: ein gescheitertes Schreiben holt der naechste Lauf nach.
    private func publishSnapshot() {
        let snapshot = TripSnapshot(plans: rows.map(\.plan))
        if snapshot != deps.loadSnapshot() { deps.saveSnapshot(snapshot) }
    }

    /// Zeile, Keychain-Eintrag und Mitteilungen; ein Keychain-Fehler darf das Loeschen nicht aufhalten.
    func purge(_ id: UUID) {
        deps.reminders.remove(id)
        try? deps.secrets.delete(.refreshToken(tripID: id))
        deps.notifier.remove(ReminderAlert.identifiers(id))
        rows.removeAll { $0.id == id }
        scheduleBackgroundCheck()
    }
}
