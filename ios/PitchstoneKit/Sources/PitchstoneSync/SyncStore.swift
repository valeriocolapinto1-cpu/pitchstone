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
    /// Elimina definitivamente il nodo e il suo storico.
    func deleteNode(_ id: UUID)
    func deleteEdge(_ id: UUID)

    func versions(of nodeID: UUID) -> [NodeVersionRecord]
    func saveVersion(_ version: NodeVersionRecord)

    /// Outbox in ordine di inserimento.
    func pendingChanges() -> [PendingChange]
    func pendingChange(_ entity: Entity, _ id: UUID) -> PendingChange?
    /// Inserisce o aggiorna la voce mantenendo la sua posizione originale.
    func savePending(_ change: PendingChange)
    func removePending(_ entity: Entity, _ id: UUID)

    /// Ultimo server_seq ricevuto.
    var cursor: Int64 { get set }
}

@MainActor
public final class InMemoryStore: SyncStore {
    private var nodes: [UUID: NodeRecord] = [:]
    private var edges: [UUID: EdgeRecord] = [:]
    private var history: [UUID: [NodeVersionRecord]] = [:]
    private var outbox: [PendingChange] = []
    public var cursor: Int64 = 0

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

    public func pendingChange(_ entity: Entity, _ id: UUID) -> PendingChange? {
        outbox.first { $0.entity == entity && $0.id == id }
    }

    public func savePending(_ change: PendingChange) {
        if let index = outbox.firstIndex(where: { $0.entity == change.entity && $0.id == change.id }) {
            outbox[index] = change
        } else {
            outbox.append(change)
        }
    }

    public func removePending(_ entity: Entity, _ id: UUID) {
        outbox.removeAll { $0.entity == entity && $0.id == id }
    }
}
