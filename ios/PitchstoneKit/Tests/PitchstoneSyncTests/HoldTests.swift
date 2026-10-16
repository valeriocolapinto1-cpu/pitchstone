import Foundation
import Testing
@testable import PitchstoneSync

@MainActor
private final class Held {
    var ids: Set<UUID>
    init(ids: Set<UUID>) { self.ids = ids }
}

@MainActor
@Suite("Nodi trattenuti")
struct HoldTests {
    let server = FakeServer()

    @Test("un nodo trattenuto e i suoi archi restano in outbox finché non viene liberato")
    func heldNodesStayLocal() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let diary = a.repository.createNode(type: .idea, title: "Diario", body: "pressione 140/90", area: .studio)
        let other = a.repository.createNode(type: .concept, title: "Altro", area: .studio)
        _ = try a.repository.createEdge(from: diary.id, to: other.id, kind: .manual)
        let held = Held(ids: [diary.id])
        a.engine.holds = { held.ids.contains($0.id) }

        _ = await a.engine.sync()
        _ = await b.engine.sync()
        #expect(b.store.node(diary.id) == nil)
        #expect(b.store.node(other.id) != nil)
        #expect(b.store.allEdges().isEmpty)
        #expect(a.store.pendingChange(.node, diary.id) != nil)
        #expect(a.store.pendingChange(.node, diary.id)?.rejection == nil)

        held.ids = []
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        #expect(b.store.node(diary.id)?.bodyMD == "pressione 140/90")
        #expect(b.store.allEdges().count == 1)
    }
}

@MainActor
@Suite("Contenuto spostato nei dati di salute")
struct MoveContentTests {
    @Test("pagine e allegati mai caricati passano al nodo nuovo e lasciano l'outbox")
    func movesLocalContent() throws {
        let store = InMemoryStore()
        let repository = Repository(store: store, deviceID: "t")
        let original = repository.createNode(type: .idea, title: "Diario", area: .studio)
        let health = repository.createNode(type: .idea, title: "Diario", area: .salute)
        let page = try repository.createInkPage(in: original.id)
        let local = try repository.createAttachment(
            nodeID: original.id, kind: .pdf, fileName: "referto.pdf", sizeBytes: 10, sha256: "a")
        var uploaded = try repository.createAttachment(
            nodeID: original.id, kind: .pdf, fileName: "dispensa.pdf", sizeBytes: 10, sha256: "b")
        uploaded.isUploaded = true
        uploaded.version = 1
        store.saveAttachment(uploaded)
        let note = try repository.createInkPage(in: original.id, pdf: (uploaded.id, 0))

        repository.moveLocalContent(from: original.id, to: health.id)

        #expect(store.inkPage(page.id)?.nodeID == health.id)
        #expect(store.attachment(local.id)?.nodeID == health.id)
        #expect(store.attachment(uploaded.id)?.nodeID == original.id)
        #expect(store.inkPage(note.id)?.nodeID == health.id)
        #expect(store.inkPage(note.id)?.attachmentID == nil)
        #expect(store.pendingChange(.inkPage, page.id) == nil)
        #expect(store.pendingChange(.attachment, local.id) == nil)
    }
}
