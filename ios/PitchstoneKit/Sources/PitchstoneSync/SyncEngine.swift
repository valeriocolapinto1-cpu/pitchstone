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

    /// Prende le prime voci dell'outbox, nodi prima degli archi (vincoli di chiave esterna).
    /// Scarta ciò che non esiste più o non può lasciare il dispositivo.
    private func nextBatch(excluding sent: Set<Key>) -> [Snapshot] {
        var nodes: [Snapshot] = []
        var edges: [Snapshot] = []
        for pending in store.pendingChanges()
        where pending.rejection == nil && !sent.contains(Key(entity: pending.entity, id: pending.id)) {
            if nodes.count + edges.count == Self.batchSize { break }
            switch pending.entity {
            case .node:
                guard let node = store.node(pending.id), !Privacy.isSensitive(node) else {
                    store.removePending(.node, pending.id)
                    continue
                }
                nodes.append(Snapshot(pending: pending, change: OutgoingChange(baseVersion: pending.baseVersion, payload: .node(node))))
            case .edge:
                guard let edge = store.edge(pending.id), Privacy.isSyncable(edge, in: store) else {
                    store.removePending(.edge, pending.id)
                    continue
                }
                edges.append(Snapshot(pending: pending, change: OutgoingChange(baseVersion: pending.baseVersion, payload: .edge(edge))))
            }
        }
        return nodes + edges
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
        let serverVersion = result.node?.version ?? result.edge?.version ?? 0
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
            retryEdges(touching: node.id)
        }
        if let edge = result.edge { store.saveEdge(edge) }
        store.removePending(entity, id)
    }

    /// Un arco rifiutato perché un estremo mancava sul server riparte quando l'estremo arriva.
    private func retryEdges(touching nodeID: UUID) {
        for var pending in store.pendingChanges() where pending.entity == .edge && pending.rejection != nil {
            guard let edge = store.edge(pending.id), edge.sourceID == nodeID || edge.targetID == nodeID else { continue }
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
                store.deleteNode(id)
            case .edge:
                store.deleteEdge(id)
            }
        case .unknown:
            break
        }
    }
}
