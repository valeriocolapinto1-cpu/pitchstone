import Foundation
import Testing
@testable import PitchstoneSync

@MainActor
@Suite("Sync del disegno")
struct InkSyncTests {
    let server = FakeServer()

    @Test("una pagina disegnata su un dispositivo compare sull'altro")
    func pageAppearsOnOtherDevice() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "Appunti", area: .studio)
        let page = try a.repository.createInkPage(in: node.id, background: .grid)
        try a.repository.updateInkPage(page.id) { $0.inkData = Data([1, 2, 3]) }
        #expect(a.store.pendingChanges().map(\.entity) == [.node, .inkPage])

        _ = await a.engine.sync()
        #expect(a.store.pendingChanges().isEmpty)
        _ = await b.engine.sync()
        let received = try #require(b.repository.inkPages(of: node.id).first)
        #expect(received.inkData == Data([1, 2, 3]))
        #expect(received.background == .grid)
        #expect(received.version == 1)
    }

    @Test("conflitto sul disegno: i tratti di entrambi restano, in due pagine")
    func conflictKeepsBothDrawings() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "Appunti", area: .studio)
        let page = try a.repository.createInkPage(in: node.id)
        _ = await a.engine.sync()
        _ = await b.engine.sync()

        try a.repository.updateInkPage(page.id) { $0.inkData = Data("A".utf8) }
        try b.repository.updateInkPage(page.id) { $0.inkData = Data("B".utf8) }
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        _ = await a.engine.sync()

        for device in [a, b] {
            let drawings = device.repository.inkPages(of: node.id).map { String(decoding: $0.inkData, as: UTF8.self) }
            #expect(drawings == ["A", "B"], "pagina originale con A, copia con B in fondo")
            #expect(device.store.pendingChanges().isEmpty)
        }
    }

    @Test("le pagine di un nodo di salute restano sul dispositivo")
    func healthPagesStayLocal() async throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .health, title: "Diario", area: .salute)
        let page = try a.repository.createInkPage(in: node.id)
        try a.repository.updateInkPage(page.id) { $0.inkData = Data([9]) }
        #expect(a.store.pendingChanges().isEmpty)
        _ = await a.engine.sync()
        #expect(server.inkPages(of: node.id).isEmpty)
        #expect(a.repository.inkPages(of: node.id).count == 1)
    }

    @Test("un nodo mai sincronizzato che diventa sensibile porta via anche le sue pagine")
    func pagesLeaveOutboxWithSensitiveNode() throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .concept, title: "x", area: .studio)
        _ = try a.repository.createInkPage(in: node.id)
        try a.repository.updateNode(node.id) { $0.area = .salute }
        #expect(a.store.pendingChanges().isEmpty)
    }

    @Test("i push restano sotto il limite di byte, con almeno una voce")
    func pushBatchesBySize() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "Pesante", area: .studio)
        let big = Data(repeating: 7, count: 1_000_000)
        for _ in 0..<5 {
            let page = try a.repository.createInkPage(in: node.id)
            try a.repository.updateInkPage(page.id) { $0.inkData = big }
        }
        _ = await a.engine.sync()
        #expect(a.store.pendingChanges().isEmpty)
        #expect(server.pushSizes.count >= 3, "5 pagine da 1 MB (1,33 MB in base64) non stanno in un push da 3,5 MB")
        #expect(server.pushSizes.reduce(0, +) == 6)

        // Anche il pull procede a pagine limitate in byte.
        _ = await b.engine.sync()
        #expect(b.repository.inkPages(of: node.id).count == 5)
    }

    @Test("cestino: una pagina eliminata da sola, le pagine seguono il nodo")
    func trash() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "Appunti", area: .studio)
        let first = try a.repository.createInkPage(in: node.id)
        let second = try a.repository.createInkPage(in: node.id)
        let pageNumbers = [first.pageNo, second.pageNo]
        #expect(pageNumbers == [0, 1])
        _ = await a.engine.sync()
        _ = await b.engine.sync()

        try a.repository.trashInkPage(first.id)
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        #expect(b.repository.inkPages(of: node.id).map(\.id) == [second.id])

        try a.repository.trashNode(node.id)
        _ = await a.engine.sync()
        a.clock.now = Date().addingTimeInterval(31 * 86_400)
        a.repository.purgeTrash()
        #expect(a.store.inkPages(of: node.id).isEmpty)
        server.purge(olderThan: a.clock.now.addingTimeInterval(-Repository.trashRetention))
        _ = await b.engine.sync()
        #expect(b.store.node(node.id) == nil)
        #expect(b.store.inkPages(of: node.id).isEmpty)
    }

    @Test("una sync arrivata mentre si disegna: i tratti locali vanno in una nuova pagina")
    func remoteChangeWhileDrawing() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "Appunti", area: .studio)
        let page = try a.repository.createInkPage(in: node.id)
        _ = await a.engine.sync()
        _ = await b.engine.sync()

        // A apre la tela (byte vuoti); B disegna e sincronizza; A riceve i tratti di B.
        let loaded = try #require(a.store.inkPage(page.id)).inkData
        try b.repository.updateInkPage(page.id) { $0.inkData = Data("B".utf8) }
        _ = await b.engine.sync()
        _ = await a.engine.sync()
        #expect(a.store.inkPage(page.id)?.inkData == Data("B".utf8))

        // A salva la tela partita dai byte vecchi.
        let saved = try a.repository.saveDrawing(Data("A".utf8), to: page.id, loadedFrom: loaded)
        #expect(saved.id != page.id)
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        for device in [a, b] {
            let drawings = Set(device.repository.inkPages(of: node.id).map { String(decoding: $0.inkData, as: UTF8.self) })
            #expect(drawings == ["A", "B"])
        }

        // Senza cambi nel frattempo il salvataggio resta sulla stessa pagina.
        let again = try a.repository.saveDrawing(Data("A2".utf8), to: saved.id, loadedFrom: Data("A".utf8))
        #expect(again.id == saved.id)
    }

    @Test("una pagina troppo grande resta in outbox e non blocca la sync")
    func oversizedPageIsParked() async throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .concept, title: "Appunti", area: .studio)
        let page = try a.repository.createInkPage(in: node.id)
        try a.repository.updateInkPage(page.id) { $0.inkData = Data(repeating: 1, count: 3_000_000) }
        let outcome = await a.engine.sync()
        #expect(outcome == .synced(pushed: 1, pulled: 2))
        #expect(server.node(node.id) != nil)
        #expect(a.engine.rejections.map(\.id) == [page.id])
    }

    @Test("cestino delle pagine: ripristino")
    func restorePage() throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .concept, title: "Appunti", area: .studio)
        let page = try a.repository.createInkPage(in: node.id)
        try a.repository.trashInkPage(page.id)
        #expect(a.repository.trashedInkPages(of: node.id).map(\.id) == [page.id])
        try a.repository.restoreInkPage(page.id)
        #expect(a.repository.inkPages(of: node.id).map(\.id) == [page.id])
    }

    @Test("un'entità eliminata sconosciuta non rompe il pull")
    func unknownPurgedEntity() throws {
        let json = #"{"changes":[{"entity":"purged","data":{"entity":"quiz","id":"20000000-0000-4000-8000-000000000101"}}],"cursor":1,"has_more":false}"#
        let decoded = try WireCoding.decoder().decode(PullResponse.self, from: Data(json.utf8))
        guard case .unknown = decoded.changes[0] else { Issue.record("atteso .unknown"); return }
    }

    @Test("il disegno viaggia in base64 nel JSON")
    func wireFormat() throws {
        let page = InkPageRecord(nodeID: UUID(), pageNo: 2, background: .lines, inkData: Data([0, 1, 2, 3, 4]),
                                 createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), deviceID: "a")
        let json = try #require(String(data: try WireCoding.encoder().encode(page), encoding: .utf8))
        #expect(json.contains("\"ink_data\":\"AAECAwQ=\""))
        #expect(json.contains("\"background\":\"lines\""))
        #expect(json.contains("\"deleted_at\":null"))

        let response = """
        {"changes":[{"entity":"ink_page","data":{"id":"20000000-0000-4000-8000-000000000101","node_id":"20000000-0000-4000-8000-000000000001",
          "page_no":0,"background":"grid","ink_data":"AAECAwQ=","version":1,"created_at":"2026-10-13T12:00:00.123456+00:00",
          "updated_at":"2026-10-13T12:00:00+00:00","deleted_at":null,"device_id":"ipad-a","server_seq":5}},
          {"entity":"purged","data":{"entity":"ink_page","id":"20000000-0000-4000-8000-000000000101","purged_at":"2026-10-13T12:00:00+00:00","server_seq":6}}],
         "cursor":6,"has_more":false}
        """
        let decoded = try WireCoding.decoder().decode(PullResponse.self, from: Data(response.utf8))
        guard case .inkPage(let p) = decoded.changes[0] else { Issue.record("attesa una pagina"); return }
        #expect(p.inkData == Data([0, 1, 2, 3, 4]))
        #expect(p.background == .grid)
        guard case .purged(.inkPage, _) = decoded.changes[1] else { Issue.record("atteso purged ink_page"); return }
    }
}
