import Foundation

/// Backup locale dei dati di salute (fase 8): nodi sensibili, i loro archi, le pagine a
/// penna e gli allegati con i file. L'app lo cifra con una password prima di salvarlo.
public struct LocalArchive: Codable, Sendable, Equatable {
    public static let format = "pitchstone-salute"
    public var format: String
    public var version: Int
    public var createdAt: Date
    public var nodes: [NodeRecord]
    public var edges: [EdgeRecord]
    public var inkPages: [InkPageRecord]
    public var attachments: [AttachmentRecord]
    /// Contenuto dei file degli allegati, per id.
    public var files: [UUID: Data]

    /// I dati di salute presenti nell'archivio locale, e solo quelli.
    @MainActor
    public static func health(from store: SyncStore, files: (UUID) -> Data?, now: Date) -> LocalArchive {
        let nodes = store.allNodes().filter(Privacy.isSensitive)
        let ids = Set(nodes.map(\.id))
        let edges = store.allEdges().filter { ids.contains($0.sourceID) || ids.contains($0.targetID) }
        let pages = store.allInkPages().filter { ids.contains($0.nodeID) }
        let attachments = store.allAttachments().filter { $0.nodeID.map(ids.contains) ?? false }
        var data: [UUID: Data] = [:]
        for attachment in attachments { data[attachment.id] = files(attachment.id) }
        return LocalArchive(
            format: format, version: 1, createdAt: now, nodes: nodes, edges: edges, inkPages: pages,
            attachments: attachments, files: data)
    }

    /// Ripristino: aggiunge ciò che manca, non sovrascrive ciò che c'è. Ritorna i nodi aggiunti.
    /// Un archivio con nodi non sensibili non si ripristina: non deve finire in sync per errore.
    @MainActor
    public func restore(into store: SyncStore, writeFile: (UUID, Data) throws -> Void) throws -> Int {
        guard format == Self.format, nodes.allSatisfy(Privacy.isSensitive) else { throw RepositoryError.invalidArchive }
        var added = 0
        for node in nodes where store.node(node.id) == nil {
            store.saveNode(node)
            added += 1
        }
        for edge in edges where store.edge(edge.id) == nil && store.node(edge.sourceID) != nil && store.node(edge.targetID) != nil {
            store.saveEdge(edge)
        }
        for page in inkPages where store.inkPage(page.id) == nil && store.node(page.nodeID) != nil {
            store.saveInkPage(page)
        }
        for attachment in attachments where store.attachment(attachment.id) == nil {
            if let data = files[attachment.id] { try writeFile(attachment.id, data) }
            store.saveAttachment(attachment)
        }
        return added
    }
}
