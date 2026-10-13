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

    /// Modifiche rifiutate dal server nell'ultima sincronizzazione.
    public private(set) var rejections: [Rejection] = []

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
        rejections = []
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

    private func pushAll() async throws -> Int {
        var pushed = 0
        while true {
            let batch = nextBatch()
            if batch.isEmpty { return pushed }
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
    private func nextBatch() -> [Snapshot] {
        var nodes: [Snapshot] = []
        var edges: [Snapshot] = []
        for pending in store.pendingChanges() {
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
        guard result.status != .rejected else {
            rejections.append(Rejection(entity: entity, id: id, reason: result.message ?? result.error ?? "rifiutata"))
            store.removePending(entity, id)
            return
        }
        let serverVersion = result.node?.version ?? result.edge?.version ?? 0
        guard let current = store.pendingChange(entity, id), current.revision == snapshot.pending.revision else {
            // Modificato di nuovo durante il push: il contenuto locale resta in outbox.
            // Dopo un merge si riparte dalla versione vecchia, così il server unisce di nuovo
            // e nessuna delle due modifiche va persa.
            if var current = store.pendingChange(entity, id), result.status != .merged {
                current.baseVersion = serverVersion
                store.savePending(current)
            }
            return
        }
        if let node = result.node { store.saveNode(node) }
        if let edge = result.edge { store.saveEdge(edge) }
        store.removePending(entity, id)
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
            if let local = store.node(node.id), local.version > node.version { return }
            store.saveNode(node)
        case .edge(let edge):
            guard store.pendingChange(.edge, edge.id) == nil else { return }
            if let local = store.edge(edge.id), local.version > edge.version { return }
            store.saveEdge(edge)
        case .nodeVersion(let version):
            if store.node(version.nodeID) != nil { store.saveVersion(version) }
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
