import Foundation
import Observation
import PitchstoneStore
import PitchstoneSync
import SwiftData

/// Stato dell'app osservato dalle viste: archivio locale, repository e sync.
/// Le viste leggono `nodes` e chiamano i metodi; dopo ogni modifica la lista
/// viene ricaricata dall'archivio, che resta la fonte di verità.
@MainActor
@Observable
final class NotesModel {
    private(set) var nodes: [NodeRecord] = []
    private(set) var syncStatus: SyncStatus = .notConfigured
    /// Ultimo errore da mostrare all'utente.
    var errorMessage: String?

    let deviceID: String
    let store: SwiftDataSyncStore
    let repository: Repository
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var autoSync: AutoSync?
    @ObservationIgnored private let defaults: UserDefaults

    enum SyncStatus: Equatable {
        case notConfigured
        case idle(lastSync: Date?)
        case syncing
        case failed(String)
    }

    init(container: ModelContainer, defaults: UserDefaults = .standard, startSync: Bool = true) {
        self.defaults = defaults
        deviceID = Self.deviceID(defaults)
        store = SwiftDataSyncStore(container: container)
        repository = Repository(store: store, deviceID: deviceID)
        repository.purgeTrash()
        reload()
        if startSync { configureSync() }
    }

    // MARK: Lettura

    func reload() {
        nodes = store.allNodes()
    }

    var activeNodes: [NodeRecord] { nodes.filter { $0.deletedAt == nil } }
    var trashedNodes: [NodeRecord] { nodes.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) } }

    func node(_ id: UUID) -> NodeRecord? { nodes.first { $0.id == id } }

    /// Nodo con questo titolo, per i link `[[...]]`. Il confronto ignora maiuscole e accenti.
    func node(titled title: String) -> NodeRecord? {
        let key = Self.titleKey(title)
        return activeNodes.first { Self.titleKey($0.title) == key }
    }

    static func titleKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    func history(of id: UUID) -> [NodeVersionRecord] { repository.history(of: id) }

    /// Giorni rimasti prima dell'eliminazione definitiva dal cestino.
    func daysLeftInTrash(_ node: NodeRecord, now: Date = Date()) -> Int {
        guard let deleted = node.deletedAt else { return 0 }
        let expiry = deleted.addingTimeInterval(Repository.trashRetention)
        return max(0, Int(ceil(expiry.timeIntervalSince(now) / 86_400)))
    }

    // MARK: Modifiche

    @discardableResult
    func createNode(type: NodeType = .concept, title: String = "", area: Area = .studio, body: String = "") -> NodeRecord {
        let node = repository.createNode(type: type, title: title, body: body, area: area)
        changed()
        return node
    }

    /// Apre il nodo collegato da `[[titolo]]`, creandolo se non esiste.
    func openOrCreate(titled title: String, area: Area) -> UUID {
        if let existing = node(titled: title) { return existing.id }
        return createNode(title: title.trimmingCharacters(in: .whitespacesAndNewlines), area: area).id
    }

    @discardableResult
    func update(_ id: UUID, _ change: (inout NodeRecord) -> Void) -> Bool {
        do {
            try repository.updateNode(id, change)
            changed()
            return true
        } catch RepositoryError.syncedNodeCannotBecomeSensitive {
            errorMessage = String(localized: "Questo nodo è già sincronizzato e non può diventare un dato di salute. Crea un nuovo nodo di salute: resterà solo su questo iPad.")
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    func trash(_ id: UUID) {
        perform { try repository.trashNode(id) }
    }

    func restore(_ id: UUID) {
        perform { try repository.restoreNode(id) }
    }

    func restoreVersion(_ version: Int, of id: UUID) {
        perform { try repository.restoreVersion(version, of: id) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            changed()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func changed() {
        reload()
        scheduleSync()
    }

    /// Le modifiche si sincronizzano dopo 30 s di calma, o subito con `flushSync()`:
    /// ogni sync con un corpo cambiato crea una versione sul server, e lo storico
    /// non deve riempirsi di micro-versioni scritte durante la digitazione.
    static let syncDelay: Duration = .seconds(30)
    @ObservationIgnored private var pendingSync: Task<Void, Never>?

    private func scheduleSync() {
        guard autoSync != nil else { return }
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.syncDelay)
            } catch {
                return
            }
            self?.flushSync()
        }
    }

    /// Sincronizza subito: quando si lascia un nodo o l'app va in background.
    func flushSync() {
        pendingSync?.cancel()
        pendingSync = nil
        autoSync?.syncNow()
    }

    // MARK: Sync

    var workerURL: String {
        get { defaults.string(forKey: "workerURL") ?? "" }
        set { defaults.set(newValue, forKey: "workerURL") }
    }

    var hasCredentials: Bool { AccessKeychain.load() != nil }

    /// Salva indirizzo del Worker e service token, poi riavvia la sync.
    func saveSyncSettings(workerURL: String, clientID: String, clientSecret: String) {
        self.workerURL = workerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty, !secret.isEmpty {
            do {
                try AccessKeychain.save(AccessCredentials(clientID: id, clientSecret: secret))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        configureSync()
    }

    func configureSync() {
        autoSync?.stop()
        autoSync = nil
        engine = nil
        guard let url = URL(string: workerURL), url.scheme == "https", let credentials = AccessKeychain.load() else {
            syncStatus = .notConfigured
            return
        }
        let engine = SyncEngine(store: store, transport: HTTPSyncTransport(baseURL: url, credentials: credentials), deviceID: deviceID)
        self.engine = engine
        syncStatus = .idle(lastSync: nil)
        let autoSync = AutoSync(engine: engine) { [weak self] outcome in self?.finished(outcome) }
        autoSync.start()
        self.autoSync = autoSync
    }

    func syncNow() async {
        guard let engine else { return }
        syncStatus = .syncing
        finished(await engine.sync())
    }

    var rejections: [Rejection] { engine?.rejections ?? [] }

    private func finished(_ outcome: SyncOutcome) {
        switch outcome {
        case .synced: syncStatus = .idle(lastSync: Date())
        case .failed(let message): syncStatus = .failed(message)
        case .skipped: break
        }
        reload()
    }

    private static func deviceID(_ defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: "deviceID") { return id }
        let id = "ipad-" + UUID().uuidString.prefix(8).lowercased()
        defaults.set(id, forKey: "deviceID")
        return id
    }
}
