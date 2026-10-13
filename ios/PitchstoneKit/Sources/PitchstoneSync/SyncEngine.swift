import Foundation

/// Canale verso il Worker. Un errore significa "riprova più tardi":
/// l'outbox resta intatta.
public protocol SyncTransport: Sendable {
    func push(_ request: PushRequest) async throws -> PushResponse
    func pull(_ request: PullRequest) async throws -> PullResponse
}

public struct Rejection: Equatable, Sendable {
    public var entity: Entity
    public var id: UUID
    public var reason: String
}

public enum SyncOutcome: Equatable, Sendable {
    case synced(pushed: Int, pulled: Int)
    /// Rete o server non raggiungibili: le modifiche restano in outbox.
    case failed(String)
    /// Un'altra sincronizzazione è già in corso.
    case skipped
}

/// Sync offline-first (ARCHITETTURA.md, sezione 6.5): push dell'outbox, poi
/// pull incrementale dal cursore. I conflitti sono risolti dal server senza
/// perdite; il client non sovrascrive mai una modifica locale non ancora inviata.
@MainActor
public final class SyncEngine {
    public static let batchSize = 500
    /// Limite di un push: il Worker accetta 5 MB, i disegni in base64 pesano.
    public static let maxBatchBytes = 3_500_000

    private let store: SyncStore
    private let transport: SyncTransport
    private let deviceID: String
    private var running = false

    /// Modifiche rifiutate dal server e ancora in outbox, in attesa di correzione.
    public var rejections: [Rejection] {
        store.pendingChanges().compactMap { p in
            p.rejection.map { Rejection(entity: p.entity, id: p.id, reason: $0) }
        }
    }

    public init(store: SyncStore, transport: SyncTransport, deviceID: String) {
        self.store = store
        self.transport = transport
        self.deviceID = deviceID
    }

    @discardableResult
    public func sync() async -> SyncOutcome {
        guard !running else { return .skipped }
        running = true
        defer { running = false }
        do {
            let pushed = try await pushAll()
            let pulled = try await pullAll()
            return .synced(pushed: pushed, pulled: pulled)
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: Push

    private struct Snapshot {
        var pending: PendingChange
        var change: OutgoingChange
    }

    private struct Key: Hashable {
        var entity: Entity
        var id: UUID
    }

    private func pushAll() async throws -> Int {
        var pushed = 0
        // Ogni voce parte al massimo una volta per sync: una voce modificata durante
        // il proprio push resta in outbox per la sync successiva.
        var sent: Set<Key> = []
        while true {
            let batch = nextBatch(excluding: sent)
            if batch.isEmpty { return pushed }
            sent.formUnion(batch.map { Key(entity: $0.pending.entity, id: $0.pending.id) })
            let response = try await transport.push(PushRequest(deviceID: deviceID, changes: batch.map(\.change)))
            guard response.results.count == batch.count else {
                throw URLError(.badServerResponse)
            }
            for (snapshot, result) in zip(batch, response.results) {
                apply(result, for: snapshot)
            }
            pushed += batch.count
        }
    }

    /// Prende le prime voci dell'outbox entro il limite di numero e di byte; nodi prima
    /// di archi e pagine (vincoli di chiave esterna). La prima voce passa sempre.
    /// Scarta ciò che non esiste più o non può lasciare il dispositivo.
    private func nextBatch(excluding sent: Set<Key>) -> [Snapshot] {
        var batch: [Snapshot] = []
        var bytes = 0
        for pending in store.pendingChanges()
        where pending.rejection == nil && !sent.contains(Key(entity: pending.entity, id: pending.id)) {
            if batch.count == Self.batchSize { break }
            guard let change = outgoing(for: pending) else { continue }
            bytes += change.estimatedBytes
            // Troppo grande per questo push: resta per il prossimo, salvo che sia l'unica voce.
            if bytes > Self.maxBatchBytes, !batch.isEmpty { break }
            batch.append(Snapshot(pending: pending, change: change))
        }
        let order: [Entity: Int] = [.node: 0, .edge: 1, .inkPage: 2]
        return batch.enumerated()
            .sorted { (order[$0.element.pending.entity]!, $0.offset) < (order[$1.element.pending.entity]!, $1.offset) }
            .map(\.element)
    }

    /// Il record attuale da inviare, oppure nil (e la voce lascia l'outbox) se non può partire.
    private func outgoing(for pending: PendingChange) -> OutgoingChange? {
        let payload: OutgoingChange.Payload? = switch pending.entity {
        case .node: store.node(pending.id).flatMap { Privacy.isSensitive($0) ? nil : .node($0) }
        case .edge: store.edge(pending.id).flatMap { Privacy.isSyncable($0, in: store) ? .edge($0) : nil }
        case .inkPage: store.inkPage(pending.id).flatMap { Privacy.isSyncable($0, in: store) ? .inkPage($0) : nil }
        }
        guard let payload else {
            store.removePending(pending.entity, pending.id)
            return nil
        }
        return OutgoingChange(baseVersion: pending.baseVersion, payload: payload)
    }

    private func apply(_ result: PushResult, for snapshot: Snapshot) {
        let entity = snapshot.pending.entity
        let id = snapshot.pending.id
        // Voce sparita durante il push (record diventato sensibile o eliminato):
        // il record locale non va toccato.
        guard let current = store.pendingChange(entity, id) else { return }
        guard result.status != .rejected else {
            // Parcheggiata, non scartata: il contenuto locale resta e il pull non lo sovrascrive.
            if current.revision == snapshot.pending.revision {
                var parked = current
                parked.rejection = result.message ?? result.error ?? "rifiutata"
                store.savePending(parked)
            }
            return
        }
        let serverVersion = result.node?.version ?? result.edge?.version ?? result.inkPage?.version ?? 0
        guard current.revision == snapshot.pending.revision else {
            // Modificato di nuovo durante il push: il contenuto locale resta in outbox.
            // Dopo un merge si riparte dalla versione vecchia, così il server unisce di nuovo
            // e nessuna delle due modifiche va persa.
            if result.status != .merged {
                var current = current
                current.baseVersion = serverVersion
                store.savePending(current)
            }
            return
        }
        if let node = result.node {
            store.saveNode(node)
            retryDependents(of: node.id)
        }
        if let edge = result.edge { store.saveEdge(edge) }
        // In un conflitto sul disegno la pagina del server resta com'è: i tratti locali
        // arrivano con il pull come nuova pagina (copy_id).
        if let page = result.inkPage { store.saveInkPage(page) }
        store.removePending(entity, id)
    }

    /// Archi e pagine rifiutati perché il nodo mancava sul server ripartono quando il nodo arriva.
    private func retryDependents(of nodeID: UUID) {
        for var pending in store.pendingChanges() where pending.rejection != nil {
            let dependent: Bool = switch pending.entity {
            case .edge: store.edge(pending.id).map { $0.sourceID == nodeID || $0.targetID == nodeID } ?? false
            case .inkPage: store.inkPage(pending.id)?.nodeID == nodeID
            case .node: false
            }
            guard dependent else { continue }
            pending.rejection = nil
            store.savePending(pending)
        }
    }

    // MARK: Pull

    private func pullAll() async throws -> Int {
        var pulled = 0
        while true {
            let response = try await transport.pull(PullRequest(cursor: store.cursor, limit: Self.batchSize))
            for change in response.changes { apply(change) }
            pulled += response.changes.count
            store.cursor = max(store.cursor, response.cursor)
            if !response.hasMore || response.changes.isEmpty { return pulled }
        }
    }

    private func apply(_ change: IncomingChange) {
        switch change {
        case .node(let node):
            // Una modifica locale in attesa vince: al prossimo push il server la unirà.
            guard store.pendingChange(.node, node.id) == nil else { return }
            if let local = store.node(node.id) {
                // Un nodo diventato sensibile mentre il suo primo push era in volo resta solo locale.
                if Privacy.isSensitive(local) || local.version > node.version { return }
            }
            store.saveNode(node)
        case .edge(let edge):
            guard store.pendingChange(.edge, edge.id) == nil else { return }
            if let local = store.edge(edge.id), local.version > edge.version { return }
            store.saveEdge(edge)
        case .inkPage(let page):
            guard store.pendingChange(.inkPage, page.id) == nil else { return }
            if let local = store.inkPage(page.id), local.version > page.version { return }
            store.saveInkPage(page)
        case .nodeVersion(let version):
            // Lo storico può arrivare prima del suo nodo: il nodo ha un server_seq più recente.
            store.saveVersion(version)
        case .purged(let entity, let id):
            store.removePending(entity, id)
            switch entity {
            case .node:
                // Anche gli archi solo locali (verso nodi di salute) seguono il nodo.
                for edge in store.allEdges() where edge.sourceID == id || edge.targetID == id {
                    store.removePending(.edge, edge.id)
                    store.deleteEdge(edge.id)
                }
                for page in store.inkPages(of: id) { store.removePending(.inkPage, page.id) }
                store.deleteNode(id)
            case .edge:
                store.deleteEdge(id)
            case .inkPage:
                store.deleteInkPage(id)
            }
        case .unknown:
            break
        }
    }
}
