#if canImport(SwiftData)
import Foundation
import PitchstoneSync
import SwiftData

/// Implementazione di `SyncStore` su SwiftData. Salva dopo ogni operazione:
/// un crash non deve perdere voci dell'outbox.
@MainActor
public final class SwiftDataSyncStore: SyncStore {
    // Il contesto non tiene in vita il container: va trattenuto qui.
    private let container: ModelContainer
    private let context: ModelContext
    private let defaults: UserDefaults

    /// Vero se l'ultimo salvataggio è fallito (e il contesto è stato annullato): la sync non fa avanzare il cursore.
    public var saveFailed = false
    /// Chiamata a ogni salvataggio fallito, per mostrare l'errore all'utente invece di perderlo in silenzio.
    public var onSaveError: ((Error) -> Void)?

    public init(container: ModelContainer, defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
        context = container.mainContext
        context.autosaveEnabled = false
    }

    /// Epoca della sincronizzazione vista l'ultima volta. Sta nelle preferenze e non nel database: così non serve
    /// cambiare lo schema.
    public var epoch: Int64 {
        get { Int64(defaults.integer(forKey: "syncEpoch")) }
        set { defaults.set(Int(newValue), forKey: "syncEpoch") }
    }

    /// Dentro `performBatch` si salva ogni 200 operazioni invece che a ogni record: le
    /// ricerche di SwiftData scorrono le modifiche non salvate, quindi non devono crescere troppo.
    private var batchDepth = 0
    private var unsavedInBatch = 0
    private static let batchSize = 200

    public func performBatch(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        save()
    }

    private func save() {
        if batchDepth > 0 {
            unsavedInBatch += 1
            guard unsavedInBatch >= Self.batchSize else { return }
        }
        unsavedInBatch = 0
        do {
            try context.save()
        } catch {
            // Il contesto sporco non deve restare in giro: si annulla, e l'errore si vede.
            context.rollback()
            saveFailed = true
            onSaveError?(error)
        }
    }

    private func nodeEntity(_ id: UUID) -> NodeEntity? {
        var d = FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func edgeEntity(_ id: UUID) -> EdgeEntity? {
        var d = FetchDescriptor<EdgeEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func outboxEntity(_ entity: Entity, _ id: UUID) -> OutboxEntity? {
        let key = OutboxEntity.key(entity, id)
        var d = FetchDescriptor<OutboxEntity>(predicate: #Predicate { $0.outboxKey == key })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: Nodi e archi

    public func node(_ id: UUID) -> NodeRecord? { nodeEntity(id)?.record }
    public func edge(_ id: UUID) -> EdgeRecord? { edgeEntity(id)?.record }

    public func allNodes() -> [NodeRecord] {
        let d = FetchDescriptor<NodeEntity>(sortBy: [SortDescriptor(\.createdAt)])
        return ((try? context.fetch(d)) ?? []).compactMap(\.record)
    }

    public func allEdges() -> [EdgeRecord] {
        let d = FetchDescriptor<EdgeEntity>(sortBy: [SortDescriptor(\.createdAt)])
        return ((try? context.fetch(d)) ?? []).compactMap(\.record)
    }

    public func saveNode(_ node: NodeRecord) {
        if let existing = nodeEntity(node.id) {
            existing.update(from: node)
        } else {
            context.insert(NodeEntity(node))
        }
        save()
    }

    public func saveEdge(_ edge: EdgeRecord) {
        if let existing = edgeEntity(edge.id) {
            existing.update(from: edge)
        } else {
            context.insert(EdgeEntity(edge))
        }
        save()
    }

    // Niente `context.delete(model:where:)`: la cancellazione in blocco lascia nel
    // contesto oggetti senza riga, che poi fanno crashare la lettura.
    public func deleteNode(_ id: UUID) {
        if let entity = nodeEntity(id) { context.delete(entity) }
        let history = FetchDescriptor<NodeVersionEntity>(predicate: #Predicate { $0.nodeID == id })
        for version in (try? context.fetch(history)) ?? [] { context.delete(version) }
        let pages = FetchDescriptor<InkPageEntity>(predicate: #Predicate { $0.nodeID == id })
        for page in (try? context.fetch(pages)) ?? [] { context.delete(page) }
        save()
    }

    public func deleteEdge(_ id: UUID) {
        if let entity = edgeEntity(id) { context.delete(entity) }
        save()
    }

    // MARK: Disegno

    private func inkPageEntity(_ id: UUID) -> InkPageEntity? {
        var d = FetchDescriptor<InkPageEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    public func inkPage(_ id: UUID) -> InkPageRecord? { inkPageEntity(id)?.record }

    public func inkPages(of nodeID: UUID) -> [InkPageRecord] {
        let d = FetchDescriptor<InkPageEntity>(
            predicate: #Predicate { $0.nodeID == nodeID },
            sortBy: [SortDescriptor(\.pageNo), SortDescriptor(\.createdAt)])
        return ((try? context.fetch(d)) ?? []).map(\.record)
    }

    public func allInkPages() -> [InkPageRecord] {
        let d = FetchDescriptor<InkPageEntity>(sortBy: [SortDescriptor(\.createdAt)])
        return ((try? context.fetch(d)) ?? []).map(\.record)
    }

    public func saveInkPage(_ page: InkPageRecord) {
        if let existing = inkPageEntity(page.id) {
            existing.update(from: page)
        } else {
            context.insert(InkPageEntity(page))
        }
        save()
    }

    public func deleteInkPage(_ id: UUID) {
        if let entity = inkPageEntity(id) { context.delete(entity) }
        save()
    }

    // MARK: Allegati

    private func attachmentEntity(_ id: UUID) -> AttachmentEntity? {
        var d = FetchDescriptor<AttachmentEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    public func attachment(_ id: UUID) -> AttachmentRecord? { attachmentEntity(id)?.record }

    public func allAttachments() -> [AttachmentRecord] {
        let d = FetchDescriptor<AttachmentEntity>(sortBy: [SortDescriptor(\.createdAt)])
        return ((try? context.fetch(d)) ?? []).compactMap(\.record)
    }

    public func saveAttachment(_ attachment: AttachmentRecord) {
        if let existing = attachmentEntity(attachment.id) {
            existing.update(from: attachment)
        } else {
            context.insert(AttachmentEntity(attachment))
        }
        save()
    }

    public func deleteAttachment(_ id: UUID) {
        if let entity = attachmentEntity(id) { context.delete(entity) }
        let attachmentID: UUID? = id
        let pages = FetchDescriptor<InkPageEntity>(predicate: #Predicate { $0.attachmentID == attachmentID })
        for page in (try? context.fetch(pages)) ?? [] { context.delete(page) }
        save()
    }

    // MARK: Storico

    public func versions(of nodeID: UUID) -> [NodeVersionRecord] {
        let d = FetchDescriptor<NodeVersionEntity>(
            predicate: #Predicate { $0.nodeID == nodeID }, sortBy: [SortDescriptor(\.version)])
        return ((try? context.fetch(d)) ?? []).map(\.record)
    }

    public func saveVersion(_ version: NodeVersionRecord) {
        let nodeID = version.nodeID
        let number = version.version
        let id = version.id
        let existing = FetchDescriptor<NodeVersionEntity>(
            predicate: #Predicate { $0.id == id || ($0.nodeID == nodeID && $0.version == number) })
        for old in (try? context.fetch(existing)) ?? [] { context.delete(old) }
        // Salvataggio prima dell'inserimento: l'id è unico e potrebbe coincidere.
        save()
        context.insert(NodeVersionEntity(version))
        save()
    }

    // MARK: Outbox

    public func pendingChanges() -> [PendingChange] {
        let d = FetchDescriptor<OutboxEntity>(sortBy: [SortDescriptor(\.sequence)])
        return ((try? context.fetch(d)) ?? []).compactMap(\.change)
    }

    public func pendingChange(_ entity: Entity, _ id: UUID) -> PendingChange? {
        outboxEntity(entity, id)?.change
    }

    public func savePending(_ change: PendingChange) {
        if let existing = outboxEntity(change.entity, change.id) {
            existing.baseVersion = change.baseVersion
            existing.revision = change.revision
            existing.rejection = change.rejection
        } else {
            var d = FetchDescriptor<OutboxEntity>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
            d.fetchLimit = 1
            let last = (try? context.fetch(d).first?.sequence) ?? 0
            context.insert(OutboxEntity(change, sequence: last + 1))
        }
        save()
    }

    public func removePending(_ entity: Entity, _ id: UUID) {
        if let existing = outboxEntity(entity, id) {
            context.delete(existing)
            save()
        }
    }

    // MARK: Cursore

    public var cursor: Int64 {
        get {
            (try? context.fetch(FetchDescriptor<SyncStateEntity>()).first?.cursor) ?? 0
        }
        set {
            if let state = try? context.fetch(FetchDescriptor<SyncStateEntity>()).first {
                state.cursor = newValue
            } else {
                context.insert(SyncStateEntity(cursor: newValue))
            }
            save()
        }
    }
}
#endif
