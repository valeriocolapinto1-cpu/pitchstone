#if canImport(SwiftData)
import Foundation
import PitchstoneNotes
import PitchstoneStore
import PitchstoneSync
import Testing

/// Gira solo su piattaforme Apple (ci-ios). La logica di sync è testata su Linux
/// con InMemoryStore; qui si verifica che SwiftData rispetti lo stesso contratto.
@MainActor
@Suite("Archivio SwiftData", .serialized)
struct SwiftDataSyncStoreTests {
    let store: SwiftDataSyncStore

    init() throws {
        store = SwiftDataSyncStore(container: try PitchstoneSchema.container(inMemory: true))
    }

    @Test("nodi, archi e storico")
    func records() throws {
        let date = Date()
        var node = NodeRecord(type: .concept, title: "Derivata", area: .studio, tags: ["analisi"],
                              createdAt: date, updatedAt: date, deviceID: "a")
        store.saveNode(node)
        node.title = "Derivata prima"
        store.saveNode(node)
        #expect(store.allNodes() == [node])

        let edge = EdgeRecord(sourceID: node.id, targetID: node.id, kind: .manual, createdAt: date)
        store.saveEdge(edge)
        #expect(store.edge(edge.id) == edge)

        let v1 = NodeVersionRecord(id: UUID(), nodeID: node.id, version: 1, bodyMD: "a", createdAt: date, deviceID: "a")
        let v2 = NodeVersionRecord(id: UUID(), nodeID: node.id, version: 2, bodyMD: "b", createdAt: date, deviceID: "a")
        store.saveVersion(v2)
        store.saveVersion(v1)
        store.saveVersion(v1)
        #expect(store.versions(of: node.id) == [v1, v2])

        store.deleteNode(node.id)
        #expect(store.node(node.id) == nil)
        #expect(store.versions(of: node.id).isEmpty)
    }

    @Test("outbox ordinata")
    func outbox() {
        let first = PendingChange(entity: .node, id: UUID(), baseVersion: nil, revision: 1)
        let second = PendingChange(entity: .edge, id: UUID(), baseVersion: 3, revision: 1)
        store.savePending(first)
        store.savePending(second)
        var updated = first
        updated.revision = 2
        store.savePending(updated)
        #expect(store.pendingChanges() == [updated, second], "l'aggiornamento mantiene la posizione")
        store.removePending(.node, first.id)
        #expect(store.pendingChanges() == [second])
    }

    @Test("cursore persistente")
    func cursor() {
        #expect(store.cursor == 0)
        store.cursor = 42
        #expect(store.cursor == 42)
    }

    @Test("sync completa con SwiftData")
    func endToEndWithRepository() async {
        let repository = Repository(store: store, deviceID: "a")
        let node = repository.createNode(type: .concept, title: "x", area: .studio)
        _ = repository.createNode(type: .health, title: "privato", area: .studio)
        #expect(store.pendingChanges().map(\.id) == [node.id])
    }

    @Test("modifiche in blocco: tutto salvato, anche oltre un blocco di salvataggio")
    func batch() {
        let repository = Repository(store: store, deviceID: "a")
        var ids: [UUID] = []
        store.performBatch {
            for i in 0..<450 { ids.append(repository.createNode(type: .concept, title: "Nodo \(i)", area: .studio).id) }
            for i in 1..<450 { _ = try? repository.createEdge(from: ids[i - 1], to: ids[i], kind: .link) }
            #expect(store.node(ids[10]) != nil, "dentro il blocco si leggono anche le modifiche non salvate")
        }
        #expect(store.allNodes().count == 450)
        #expect(store.allEdges().count == 449)
        #expect(store.pendingChanges().count == 899)
    }

    @Test("allegati e annotazioni dei PDF")
    func attachments() throws {
        let date = Date()
        let node = NodeRecord(type: .concept, title: "Dispensa", area: .studio, createdAt: date, updatedAt: date, deviceID: "a")
        store.saveNode(node)
        var attachment = AttachmentRecord(nodeID: node.id, kind: .pdf, fileName: "Analisi.pdf", sizeBytes: 10, pageCount: 2,
                                          sha256: String(repeating: "a", count: 64), partCount: 1, createdAt: date,
                                          updatedAt: date, deviceID: "a")
        store.saveAttachment(attachment)
        attachment.isUploaded = true
        store.saveAttachment(attachment)
        #expect(store.attachment(attachment.id) == attachment)
        #expect(store.allAttachments() == [attachment])

        let layer = InkPageRecord(nodeID: node.id, pageNo: 0, inkData: Data([1]), attachmentID: attachment.id, pdfPage: 1,
                                  createdAt: date, updatedAt: date, deviceID: "a")
        let page = InkPageRecord(nodeID: node.id, pageNo: 1, createdAt: date, updatedAt: date, deviceID: "a")
        store.saveInkPage(layer)
        store.saveInkPage(page)
        #expect(store.inkPage(layer.id)?.pdfPage == 1)
        store.deleteAttachment(attachment.id)
        #expect(store.attachment(attachment.id) == nil)
        #expect(store.allInkPages().map(\.id) == [page.id], "le annotazioni seguono l'allegato")
    }

    @Test("indice del testo estratto: sostituzione, impronta, voce vuota")
    func textIndex() throws {
        let index = TextIndexStore(container: try PitchstoneSchema.container(inMemory: true))
        let node = UUID(), source = UUID()
        let empty = ExtractedText(nodeID: node, sourceID: source, source: .pdf, text: "")
        index.replace(sourceID: source, fingerprint: "a", with: [
            ExtractedText(nodeID: node, sourceID: source, source: .pdf, page: 0, text: "uno"),
            ExtractedText(nodeID: node, sourceID: source, source: .pdf, page: 1, text: "due"),
        ], placeholder: empty)
        #expect(index.fingerprint(of: source) == "a")
        #expect(index.all().map(\.text) == ["uno", "due"])
        index.replace(sourceID: source, fingerprint: "b", with: [], placeholder: empty)
        #expect(index.fingerprint(of: source) == "b", "anche senza testo la fonte risulta indicizzata")
        #expect(index.all().isEmpty)
        index.remove(sourceID: source)
        #expect(index.fingerprint(of: source) == nil)
    }
}
#endif
