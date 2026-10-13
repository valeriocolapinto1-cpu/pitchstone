import Foundation

public enum RepositoryError: Error, Equatable {
    case notFound
    /// Un nodo già sincronizzato non può diventare sensibile: la sua storia è
    /// sul server. Va creato un nuovo nodo di salute (ADR 0002).
    case syncedNodeCannotBecomeSensitive
    case edgeEndpointMissing
}

/// Modifiche locali: salva nell'archivio e mette in outbox ciò che può andare al server.
@MainActor
public final class Repository {
    public static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    private let store: SyncStore
    private let deviceID: String
    private let now: () -> Date

    public init(store: SyncStore, deviceID: String, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.deviceID = deviceID
        self.now = now
    }

    // MARK: Nodi

    @discardableResult
    public func createNode(
        type: NodeType, title: String, body: String = "", area: Area, tags: [String] = []
    ) -> NodeRecord {
        let date = now()
        let node = NodeRecord(
            type: type, title: title, bodyMD: body, area: area, tags: tags,
            createdAt: date, updatedAt: date, deviceID: deviceID)
        store.saveNode(node)
        if !Privacy.isSensitive(node) { enqueue(.node, node.id, version: node.version) }
        return node
    }

    @discardableResult
    public func updateNode(_ id: UUID, _ change: (inout NodeRecord) -> Void) throws -> NodeRecord {
        guard let old = store.node(id) else { throw RepositoryError.notFound }
        var node = old
        change(&node)
        node.id = old.id
        node.version = old.version
        node.createdAt = old.createdAt
        node.updatedAt = now()
        node.deviceID = deviceID

        if Privacy.isSensitive(node) && !Privacy.isSensitive(old) {
            if old.version > 0 { throw RepositoryError.syncedNodeCannotBecomeSensitive }
            // Mai arrivato al server: basta toglierlo dall'outbox, insieme ai suoi archi.
            store.removePending(.node, id)
            for edge in store.allEdges() where edge.sourceID == id || edge.targetID == id {
                if edge.version == 0 { store.removePending(.edge, edge.id) }
            }
            for page in store.inkPages(of: id) where page.version == 0 {
                store.removePending(.inkPage, page.id)
            }
        }
        store.saveNode(node)
        if !Privacy.isSensitive(node) { enqueue(.node, id, version: old.version) }
        return node
    }

    public func trashNode(_ id: UUID) throws {
        try updateNode(id) { $0.deletedAt = now() }
    }

    public func restoreNode(_ id: UUID) throws {
        try updateNode(id) { $0.deletedAt = nil }
    }

    // MARK: Storico

    /// Versioni accettate dal server, dalla più vecchia alla più recente.
    public func history(of id: UUID) -> [NodeVersionRecord] {
        store.versions(of: id)
    }

    /// Riporta il corpo di un nodo a una versione dello storico. È una modifica
    /// normale: crea una nuova versione, quelle successive restano nello storico.
    @discardableResult
    public func restoreVersion(_ version: Int, of id: UUID) throws -> NodeRecord {
        guard let old = store.versions(of: id).first(where: { $0.version == version }) else {
            throw RepositoryError.notFound
        }
        return try updateNode(id) { $0.bodyMD = old.bodyMD }
    }

    // MARK: Archi

    @discardableResult
    public func createEdge(from source: UUID, to target: UUID, kind: EdgeKind, label: String? = nil) throws -> EdgeRecord {
        guard store.node(source) != nil, store.node(target) != nil else { throw RepositoryError.edgeEndpointMissing }
        let edge = EdgeRecord(sourceID: source, targetID: target, kind: kind, label: label, createdAt: now())
        store.saveEdge(edge)
        if Privacy.isSyncable(edge, in: store) { enqueue(.edge, edge.id, version: 0) }
        return edge
    }

    /// Allinea gli archi di tipo `link` di un nodo ai suoi link `[[...]]`: crea quelli
    /// nuovi, ripristina quelli tornati, mette nel cestino quelli spariti dal testo.
    /// Gli archi manuali e quelli dell'AI non vengono toccati.
    public func syncLinkEdges(from nodeID: UUID, to targets: Set<UUID>) {
        guard store.node(nodeID) != nil else { return }
        let wanted = targets.subtracting([nodeID]).filter { store.node($0) != nil }
        // Tutti gli archi link del nodo per destinazione: possono esserci doppioni,
        // per esempio creati da due dispositivi prima di sincronizzarsi.
        var existing: [UUID: [EdgeRecord]] = [:]
        for edge in store.allEdges() where edge.sourceID == nodeID && edge.kind == .link {
            existing[edge.targetID, default: []].append(edge)
        }
        for target in wanted {
            let edges = existing[target] ?? []
            let active = edges.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt }
            if let keep = active.first {
                // Un solo arco attivo per destinazione: gli altri vanno nel cestino.
                for duplicate in active where duplicate.id != keep.id { try? trashEdge(duplicate.id) }
            } else if let trashed = edges.max(by: { ($0.deletedAt ?? .distantPast) < ($1.deletedAt ?? .distantPast) }) {
                var restored = trashed
                restored.deletedAt = nil
                store.saveEdge(restored)
                if Privacy.isSyncable(restored, in: store) { enqueue(.edge, trashed.id, version: trashed.version) }
            } else {
                _ = try? createEdge(from: nodeID, to: target, kind: .link)
            }
        }
        for (target, edges) in existing where !wanted.contains(target) {
            for edge in edges where edge.deletedAt == nil { try? trashEdge(edge.id) }
        }
    }

    public func trashEdge(_ id: UUID) throws {
        guard var edge = store.edge(id) else { throw RepositoryError.notFound }
        edge.deletedAt = now()
        store.saveEdge(edge)
        if Privacy.isSyncable(edge, in: store) { enqueue(.edge, id, version: edge.version) }
    }

    // MARK: Disegno

    /// Pagine di disegno del nodo, escluse quelle nel cestino.
    public func inkPages(of nodeID: UUID) -> [InkPageRecord] {
        store.inkPages(of: nodeID).filter { $0.deletedAt == nil }
    }

    @discardableResult
    public func createInkPage(in nodeID: UUID, background: InkBackground = .blank) throws -> InkPageRecord {
        guard store.node(nodeID) != nil else { throw RepositoryError.notFound }
        let date = now()
        let next = (store.inkPages(of: nodeID).map(\.pageNo).max() ?? -1) + 1
        let page = InkPageRecord(nodeID: nodeID, pageNo: next, background: background,
                                 createdAt: date, updatedAt: date, deviceID: deviceID)
        store.saveInkPage(page)
        if Privacy.isSyncable(page, in: store) { enqueue(.inkPage, page.id, version: 0) }
        return page
    }

    @discardableResult
    public func updateInkPage(_ id: UUID, _ change: (inout InkPageRecord) -> Void) throws -> InkPageRecord {
        guard let old = store.inkPage(id) else { throw RepositoryError.notFound }
        var page = old
        change(&page)
        page.id = old.id
        page.nodeID = old.nodeID
        page.version = old.version
        page.createdAt = old.createdAt
        page.updatedAt = now()
        page.deviceID = deviceID
        store.saveInkPage(page)
        if Privacy.isSyncable(page, in: store) { enqueue(.inkPage, id, version: old.version) }
        return page
    }

    public func trashInkPage(_ id: UUID) throws {
        try updateInkPage(id) { $0.deletedAt = now() }
    }

    public func restoreInkPage(_ id: UUID) throws {
        try updateInkPage(id) { $0.deletedAt = nil }
    }

    /// Pagine del nodo nel cestino, la più recente per prima.
    public func trashedInkPages(of nodeID: UUID) -> [InkPageRecord] {
        store.inkPages(of: nodeID).filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Salva il disegno di una tela partita dai byte `loadedFrom`. Se nel frattempo la
    /// pagina è cambiata (una sync ha portato i tratti di un altro dispositivo), i
    /// tratti della tela vanno in una nuova pagina dello stesso nodo, come fa il
    /// server in un conflitto: nessuno dei due disegni sovrascrive l'altro.
    /// Ritorna la pagina in cui è finito il disegno.
    @discardableResult
    public func saveDrawing(_ data: Data, to id: UUID, loadedFrom: Data) throws -> InkPageRecord {
        guard let current = store.inkPage(id) else { throw RepositoryError.notFound }
        if current.inkData == loadedFrom || current.inkData == data {
            return try updateInkPage(id) { $0.inkData = data }
        }
        let copy = try createInkPage(in: current.nodeID, background: current.background)
        return try updateInkPage(copy.id) { $0.inkData = data }
    }

    // MARK: Cestino

    public func trashedNodes() -> [NodeRecord] {
        store.allNodes().filter { $0.deletedAt != nil }
    }

    /// Elimina definitivamente ciò che è nel cestino da più di 30 giorni,
    /// con gli archi collegati. Il server fa lo stesso per i dati sincronizzati.
    @discardableResult
    public func purgeTrash() -> Int {
        let cutoff = now().addingTimeInterval(-Self.trashRetention)
        let expired = Set(store.allNodes().filter { ($0.deletedAt ?? .distantFuture) < cutoff }.map(\.id))
        for edge in store.allEdges()
        where (edge.deletedAt ?? .distantFuture) < cutoff || expired.contains(edge.sourceID) || expired.contains(edge.targetID) {
            store.removePending(.edge, edge.id)
            store.deleteEdge(edge.id)
        }
        for page in store.allInkPages() where (page.deletedAt ?? .distantFuture) < cutoff || expired.contains(page.nodeID) {
            store.removePending(.inkPage, page.id)
            store.deleteInkPage(page.id)
        }
        for id in expired {
            store.removePending(.node, id)
            store.deleteNode(id)
        }
        return expired.count
    }

    // MARK: Outbox

    private func enqueue(_ entity: Entity, _ id: UUID, version: Int) {
        if var pending = store.pendingChange(entity, id) {
            pending.revision += 1
            pending.rejection = nil
            store.savePending(pending)
        } else {
            store.savePending(PendingChange(entity: entity, id: id, baseVersion: version > 0 ? version : nil, revision: 1))
        }
    }
}
