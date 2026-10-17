import Foundation

/// Archivio locale usato da repository e sync. In produzione è SwiftData
/// (PitchstoneStore); nei test e nelle anteprime è `InMemoryStore`.
@MainActor
public protocol SyncStore: AnyObject {
    func node(_ id: UUID) -> NodeRecord?
    func edge(_ id: UUID) -> EdgeRecord?
    func allNodes() -> [NodeRecord]
    func allEdges() -> [EdgeRecord]
    func saveNode(_ node: NodeRecord)
    func saveEdge(_ edge: EdgeRecord)
    /// Elimina definitivamente il nodo, il suo storico e le sue pagine di disegno.
    func deleteNode(_ id: UUID)
    func deleteEdge(_ id: UUID)

    func versions(of nodeID: UUID) -> [NodeVersionRecord]
    func saveVersion(_ version: NodeVersionRecord)

    func inkPage(_ id: UUID) -> InkPageRecord?
    /// Pagine del nodo (anche quelle nel cestino), in ordine di `pageNo`.
    func inkPages(of nodeID: UUID) -> [InkPageRecord]
    func allInkPages() -> [InkPageRecord]
    func saveInkPage(_ page: InkPageRecord)
    func deleteInkPage(_ id: UUID)

    func attachment(_ id: UUID) -> AttachmentRecord?
    func allAttachments() -> [AttachmentRecord]
    func saveAttachment(_ attachment: AttachmentRecord)
    /// Elimina la riga e le annotazioni del PDF (non il file locale).
    func deleteAttachment(_ id: UUID)

    /// Outbox in ordine di inserimento.
    func pendingChanges() -> [PendingChange]
    func pendingChange(_ entity: Entity, _ id: UUID) -> PendingChange?
    /// Inserisce o aggiorna la voce mantenendo la sua posizione originale.
    func savePending(_ change: PendingChange)
    func removePending(_ entity: Entity, _ id: UUID)

    /// Ultimo server_seq ricevuto.
    var cursor: Int64 { get set }
    /// Epoca della sincronizzazione vista l'ultima volta (0 = ancora sconosciuta).
    var epoch: Int64 { get set }
    /// Vero se l'ultimo salvataggio su disco è fallito e il contesto è stato annullato: la sync non deve
    /// far avanzare il cursore su modifiche che non sono state salvate.
    var saveFailed: Bool { get set }

    /// Esegue molte modifiche come un'unica transazione (per esempio un import):
    /// un solo salvataggio alla fine invece di uno per record.
    func performBatch(_ body: () -> Void)
}

extension SyncStore {
    public func performBatch(_ body: () -> Void) { body() }
}

@MainActor
public final class InMemoryStore: SyncStore {
    private var nodes: [UUID: NodeRecord] = [:]
    private var edges: [UUID: EdgeRecord] = [:]
    private var history: [UUID: [NodeVersionRecord]] = [:]
    private var pages: [UUID: InkPageRecord] = [:]
    private var attachments: [UUID: AttachmentRecord] = [:]
    private var outbox: [PendingChange] = []
    public var cursor: Int64 = 0
    public var epoch: Int64 = 0
    public var saveFailed = false

    public init() {}

    public func node(_ id: UUID) -> NodeRecord? { nodes[id] }
    public func edge(_ id: UUID) -> EdgeRecord? { edges[id] }
    public func allNodes() -> [NodeRecord] { nodes.values.sorted { $0.createdAt < $1.createdAt } }
    public func allEdges() -> [EdgeRecord] { edges.values.sorted { $0.createdAt < $1.createdAt } }
    public func saveNode(_ node: NodeRecord) { nodes[node.id] = node }
    public func saveEdge(_ edge: EdgeRecord) { edges[edge.id] = edge }

    public func deleteNode(_ id: UUID) {
        nodes[id] = nil
        history[id] = nil
        pages = pages.filter { $0.value.nodeID != id }
    }

    public func inkPage(_ id: UUID) -> InkPageRecord? { pages[id] }

    public func inkPages(of nodeID: UUID) -> [InkPageRecord] {
        pages.values.filter { $0.nodeID == nodeID }.sorted { ($0.pageNo, $0.createdAt) < ($1.pageNo, $1.createdAt) }
    }

    public func allInkPages() -> [InkPageRecord] { pages.values.sorted { $0.createdAt < $1.createdAt } }
    public func saveInkPage(_ page: InkPageRecord) { pages[page.id] = page }
    public func deleteInkPage(_ id: UUID) { pages[id] = nil }

    public func attachment(_ id: UUID) -> AttachmentRecord? { attachments[id] }
    public func allAttachments() -> [AttachmentRecord] { attachments.values.sorted { $0.createdAt < $1.createdAt } }
    public func saveAttachment(_ attachment: AttachmentRecord) { attachments[attachment.id] = attachment }

    public func deleteAttachment(_ id: UUID) {
        attachments[id] = nil
        pages = pages.filter { $0.value.attachmentID != id }
    }

    public func deleteEdge(_ id: UUID) { edges[id] = nil }

    public func versions(of nodeID: UUID) -> [NodeVersionRecord] {
        (history[nodeID] ?? []).sorted { $0.version < $1.version }
    }

    public func saveVersion(_ version: NodeVersionRecord) {
        var list = history[version.nodeID] ?? []
        list.removeAll { $0.id == version.id || $0.version == version.version }
        list.append(version)
        history[version.nodeID] = list
    }

    public func pendingChanges() -> [PendingChange] { outbox }

    /// Chiavi presenti nell'outbox: con migliaia di voci (un import) le ricerche
    /// di voci assenti, le più frequenti, non scorrono tutto l'array.
    private var outboxKeys = Set<String>()

    private static func key(_ entity: Entity, _ id: UUID) -> String { "\(entity.rawValue)/\(id)" }

    public func pendingChange(_ entity: Entity, _ id: UUID) -> PendingChange? {
        guard outboxKeys.contains(Self.key(entity, id)) else { return nil }
        return outbox.first { $0.entity == entity && $0.id == id }
    }

    public func savePending(_ change: PendingChange) {
        if outboxKeys.contains(Self.key(change.entity, change.id)),
           let index = outbox.firstIndex(where: { $0.entity == change.entity && $0.id == change.id }) {
            outbox[index] = change
        } else {
            outbox.append(change)
            outboxKeys.insert(Self.key(change.entity, change.id))
        }
    }

    public func removePending(_ entity: Entity, _ id: UUID) {
        guard outboxKeys.remove(Self.key(entity, id)) != nil else { return }
        outbox.removeAll { $0.entity == entity && $0.id == id }
    }
}
