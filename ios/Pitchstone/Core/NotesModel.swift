import Foundation
import Observation
import PitchstoneAI
import PitchstoneImport
import PitchstoneNotes
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
    private(set) var edges: [EdgeRecord] = []
    /// Cresce a ogni ricarica: le viste del disegno lo leggono per aggiornarsi.
    private(set) var inkRevision = 0
    /// Cresce a ogni ricarica dell'archivio: chi ricava dati dai nodi (il grafo) lo osserva.
    var revision: Int { inkRevision }
    private(set) var syncStatus: SyncStatus = .notConfigured
    /// Ultimo errore da mostrare all'utente.
    var errorMessage: String?

    let deviceID: String
    let store: SwiftDataSyncStore
    let repository: Repository
    /// File degli allegati sul dispositivo.
    let files: AttachmentFileStore
    /// Scaricamento dei file dal bucket; nil se la sync non è configurata.
    @ObservationIgnored private(set) var transfer: AttachmentTransfer?
    /// Testo estratto da allegati e scrittura a mano (solo locale).
    let textIndex: TextIndexStore
    private(set) var extractedTexts: [ExtractedText] = []
    /// L'indicizzazione parte da sola dopo le modifiche; nei test si chiama a mano.
    @ObservationIgnored let autoIndex: Bool
    @ObservationIgnored var indexing: Task<Void, Never>?
    @ObservationIgnored var indexAgain = false
    /// Analisi automatica (fase 6): stato locale, nodi sospettati di contenere dati di
    /// salute (trattenuti sul dispositivo e fuori dai prompt), proposte da confermare.
    let analysisStore: AnalysisStore
    // Scritti da NotesModel+Analysis.swift: un `private(set)` non si può impostare da un altro file.
    var healthSuspects: Set<UUID> = []
    var pendingProposals: [UUID: [PendingProposal]] = [:]
    /// Esiti del rilevatore, per nodo: si ricalcolano solo se cambia la chiave (data e testo estratto).
    @ObservationIgnored var assessments: [UUID: (key: String, result: HealthAssessment)] = [:]
    /// Segnali giudicati innocui, per nodo: in memoria, letti dalla sync a ogni voce.
    @ObservationIgnored var dismissedSignals: [UUID: Set<String>] = [:]
    /// Testo estratto da allegati e pagine a penna, per nodo: conta anche per la salute.
    @ObservationIgnored var extractedByNode: [UUID: String] = [:]
    @ObservationIgnored var analysisRunning = false
    @ObservationIgnored var analyzeAgain = false
    /// Nodi modificati in questa sessione: l'analisi automatica guarda solo questi.
    @ObservationIgnored var recentlyEdited: Set<UUID> = []
    @ObservationIgnored var analyzing: Task<Void, Never>?
    /// Nei test: modelli finti per l'analisi.
    @ObservationIgnored var analysisProvidersOverride: (local: ChatProvider?, online: ChatProvider?)?
    /// Chat: indice dei frammenti (ricostruito quando cambia `revision`), vettori, modelli.
    @ObservationIgnored var chatIndex: (revision: Int, index: SemanticIndex)?
    @ObservationIgnored lazy var chatEmbedder: TextEmbedder? = {
        let embedder = NLTextEmbedder()
        return embedder.isAvailable ? embedder : nil
    }()
    /// Nei test: modelli finti al posto di Gemini e del modello locale.
    @ObservationIgnored var chatRouterOverride: ChatRouter?
    /// Trasporto verso il Worker, anche per Gemini; nil se la sync non è configurata.
    @ObservationIgnored private(set) var workerTransport: HTTPSyncTransport?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var autoSync: AutoSync?
    @ObservationIgnored let defaults: UserDefaults

    enum SyncStatus: Equatable {
        case notConfigured
        case idle(lastSync: Date?)
        case syncing
        case failed(String)
    }

    init(
        container: ModelContainer, defaults: UserDefaults = .standard, startSync: Bool = true,
        attachmentsDirectory: URL? = nil, autoIndex: Bool = false
    ) {
        self.defaults = defaults
        self.autoIndex = autoIndex
        textIndex = TextIndexStore(container: container)
        analysisStore = AnalysisStore(container: container)
        deviceID = Self.deviceID(defaults)
        store = SwiftDataSyncStore(container: container)
        repository = Repository(store: store, deviceID: deviceID)
        let files = DirectoryAttachmentFiles(directory: attachmentsDirectory ?? Self.defaultAttachmentsDirectory)
        self.files = files
        repository.purgeTrash { files.remove($0) }
        reload()
        if startSync { configureSync() }
        if autoIndex { scheduleIndexing() }
    }

    // MARK: Lettura

    func reload() {
        nodes = store.allNodes()
        edges = store.allEdges()
        extractedTexts = textIndex.all()
        refreshAnalysisState()
        inkRevision += 1
    }

    var activeNodes: [NodeRecord] { nodes.filter { $0.deletedAt == nil } }
    var trashedNodes: [NodeRecord] { nodes.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) } }

    func node(_ id: UUID) -> NodeRecord? { nodes.first { $0.id == id } }

    /// Nodo con questo titolo, per i link `[[...]]`. Il confronto ignora maiuscole e accenti.
    func node(titled title: String) -> NodeRecord? {
        let key = Self.titleKey(title)
        return activeNodes.first { Self.titleKey($0.title) == key }
    }

    static func titleKey(_ title: String) -> String { NodeTitle.key(title) }

    func history(of id: UUID) -> [NodeVersionRecord] { repository.history(of: id) }

    // MARK: Disegno

    static var defaultAttachmentsDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Allegati", isDirectory: true)
    }

    func inkPages(of nodeID: UUID) -> [InkPageRecord] {
        _ = inkRevision
        return repository.inkPages(of: nodeID)
    }

    func inkPage(_ id: UUID) -> InkPageRecord? {
        _ = inkRevision
        return store.inkPage(id)
    }

    @discardableResult
    func createInkPage(in nodeID: UUID, background: InkBackground) -> InkPageRecord? {
        do {
            let page = try repository.createInkPage(in: nodeID, background: background)
            changed()
            return page
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateInkPage(_ id: UUID, _ change: (inout InkPageRecord) -> Void) {
        perform { try repository.updateInkPage(id, change) }
    }

    func trashInkPage(_ id: UUID) {
        perform { try repository.trashInkPage(id) }
    }

    func restoreInkPage(_ id: UUID) {
        perform { try repository.restoreInkPage(id) }
    }

    func trashedInkPages(of nodeID: UUID) -> [InkPageRecord] {
        _ = inkRevision
        return repository.trashedInkPages(of: nodeID)
    }

    /// Salva i tratti di una tela partita da `loadedFrom`; ritorna la pagina usata
    /// (una nuova, se nel frattempo la pagina è cambiata per una sync).
    func saveDrawing(_ data: Data, to id: UUID, loadedFrom: Data) -> InkPageRecord? {
        do {
            let page = try repository.saveDrawing(data, to: id, loadedFrom: loadedFrom)
            changed()
            return page
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

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
        // I [[link]] già scritti verso questo titolo diventano archi.
        if !title.isEmpty { resyncLinks(mentioning: [title]) }
        changed()
        return node
    }

    /// Apre il nodo collegato da `[[titolo]]`, creandolo se non esiste.
    /// `source` è il nodo da cui parte il link: se il nodo collegato viene creato ora,
    /// l'arco compare subito nel grafo.
    func openOrCreate(titled title: String, area: Area, from source: UUID? = nil) -> UUID {
        if let existing = node(titled: title) { return existing.id }
        let created = createNode(title: title.trimmingCharacters(in: .whitespacesAndNewlines), area: area)
        if let source {
            syncLinks(of: source)
            // L'arco nuovo deve comparire subito nel grafo.
            changed()
        }
        return created.id
    }

    // MARK: Import

    /// Cosa creerebbe l'import del vault, senza toccare l'archivio.
    func importPlan(_ contents: VaultContents, area: Area) -> VaultImportPlan {
        let titles = store.allNodes().filter { $0.deletedAt == nil }.map(\.title)
        return ObsidianImport.plan(contents, defaultArea: area, existingTitles: titles)
    }

    /// Come `importPlan`, ma calcolato in background.
    func makeImportPlan(_ contents: VaultContents, area: Area) async -> VaultImportPlan {
        let titles = activeNodes.map(\.title)
        return await Task.detached(priority: .userInitiated) {
            ObsidianImport.plan(contents, defaultArea: area, existingTitles: titles)
        }.value
    }

    /// Crea i nodi e gli archi del vault. Le note già nell'app che citano i titoli
    /// nuovi con `[[...]]` ricevono i loro archi.
    @discardableResult
    func importVault(_ plan: VaultImportPlan) -> VaultImporter.Result {
        let result = VaultImporter.apply(plan, to: repository, store: store)
        resyncLinks(mentioning: plan.notes.map(\.title), excluding: Set(result.created))
        changed()
        return result
    }

    /// Collega due nodi a mano (Pencil sul grafo). Non duplica un arco già presente.
    func connect(_ a: UUID, _ b: UUID) {
        guard a != b else { return }
        let exists = edges.contains {
            $0.deletedAt == nil && (($0.sourceID == a && $0.targetID == b) || ($0.sourceID == b && $0.targetID == a))
        }
        guard !exists else { return }
        perform { try repository.createEdge(from: a, to: b, kind: .manual) }
    }

    /// Archi di tipo `link` allineati ai `[[...]]` del corpo. I titoli senza nodo non creano archi.
    /// I titoli si risolvono sull'archivio, non sulla lista in memoria che può essere indietro.
    private func syncLinks(of id: UUID, titles: [String: UUID]? = nil) {
        guard let node = store.node(id) else { return }
        let index = titles ?? titleIndex()
        let targets = MarkdownLinks.wikiTargets(in: node.bodyMD).compactMap { index[Self.titleKey($0)] }
        repository.syncLinkEdges(from: id, to: Set(targets))
    }

    private func titleIndex() -> [String: UUID] {
        var index: [String: UUID] = [:]
        for node in store.allNodes() where node.deletedAt == nil && !node.title.isEmpty {
            index[Self.titleKey(node.title)] = index[Self.titleKey(node.title)] ?? node.id
        }
        return index
    }

    /// Dopo una rinomina o un nodo nuovo: i nodi che citano quei titoli riallineano i loro archi.
    private func resyncLinks(mentioning titles: [String], excluding skipped: Set<UUID> = []) {
        let keys = Set(titles.map(Self.titleKey).filter { !$0.isEmpty })
        guard !keys.isEmpty else { return }
        let index = titleIndex()
        for node in store.allNodes() where node.deletedAt == nil && !skipped.contains(node.id) && node.bodyMD.contains("[[") {
            // Filtro veloce prima di analizzare il Markdown; con molti titoli (un import)
            // costerebbe più dell'analisi stessa.
            if titles.count <= 20 {
                guard titles.contains(where: { !$0.isEmpty && node.bodyMD.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else { continue }
            }
            let mentioned = MarkdownLinks.wikiTargets(in: node.bodyMD).map(Self.titleKey)
            if mentioned.contains(where: keys.contains) { syncLinks(of: node.id, titles: index) }
        }
    }

    @discardableResult
    func update(_ id: UUID, _ change: (inout NodeRecord) -> Void) -> Bool {
        do {
            let old = store.node(id)
            let updated = try repository.updateNode(id, change)
            recentlyEdited.insert(id)
            if updated.bodyMD != old?.bodyMD { syncLinks(of: id) }
            if updated.title != old?.title { resyncLinks(mentioning: [old?.title ?? "", updated.title]) }
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

    func perform(_ action: () throws -> Void) {
        do {
            try action()
            changed()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func changed() {
        if autoIndex {
            scheduleIndexing()
            scheduleAnalysis()
        }
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
        transfer = nil
        workerTransport = nil
        guard let url = URL(string: workerURL), url.scheme == "https", let credentials = AccessKeychain.load() else {
            syncStatus = .notConfigured
            return
        }
        let transport = HTTPSyncTransport(baseURL: url, credentials: credentials)
        workerTransport = transport
        let transfer = AttachmentTransfer(transport: transport, files: files)
        self.transfer = transfer
        let engine = SyncEngine(store: store, transport: transport, deviceID: deviceID, attachments: transfer)
        // Un nodo che sembra un dato di salute aspetta la scelta dell'utente prima di partire.
        engine.holds = { [weak self] node in self?.isHeld(node) ?? false }
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
        // Pagine e allegati arrivati con la sync diventano ricercabili.
        if autoIndex, case .synced(_, let pulled) = outcome, pulled > 0 { scheduleIndexing() }
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
