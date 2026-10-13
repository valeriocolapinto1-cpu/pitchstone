import Foundation
import Testing
@testable import PitchstoneSync

@MainActor
@Suite("Sync tra dispositivi")
struct SyncEngineTests {
    let server = FakeServer()

    @Test("un nodo creato su un dispositivo compare sull'altro")
    func nodeAppearsOnOtherDevice() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "Derivata", body: "Limite del rapporto", area: .studio)
        let other = a.repository.createNode(type: .concept, title: "Integrale", area: .studio)
        let edge = try a.repository.createEdge(from: node.id, to: other.id, kind: .manual, label: "inversa")

        #expect(await a.engine.sync() == .synced(pushed: 3, pulled: 5))
        #expect(a.store.pendingChanges().isEmpty)
        #expect(a.store.node(node.id)?.version == 1)

        _ = await b.engine.sync()
        #expect(b.store.node(node.id)?.title == "Derivata")
        #expect(b.store.node(node.id)?.bodyMD == "Limite del rapporto")
        #expect(b.store.edge(edge.id)?.label == "inversa")
        #expect(b.store.versions(of: node.id).map(\.version) == [1])
    }

    @Test("le modifiche offline partono al ritorno della connessione")
    func offlineChangesSyncWhenOnline() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .idea, title: "Bozza", area: .progetti)
        _ = await a.engine.sync()

        a.transport.online = false
        try a.repository.updateNode(node.id) { $0.bodyMD = "scritto in aereo" }
        try a.repository.updateNode(node.id) { $0.title = "Idea" }
        let offline = a.repository.createNode(type: .concept, title: "Nuovo offline", area: .studio)

        guard case .failed = await a.engine.sync() else {
            Issue.record("la sync offline deve fallire")
            return
        }
        #expect(a.store.pendingChanges().count == 2, "una sola voce per nodo, le modifiche si fondono")
        #expect(server.node(node.id)?.bodyMD == "")

        a.transport.online = true
        _ = await a.engine.sync()
        #expect(a.store.pendingChanges().isEmpty)
        #expect(server.node(node.id)?.bodyMD == "scritto in aereo")
        #expect(server.node(node.id)?.title == "Idea")
        #expect(server.node(node.id)?.version == 2)

        _ = await b.engine.sync()
        #expect(b.store.node(offline.id)?.title == "Nuovo offline")
        #expect(b.store.node(node.id)?.bodyMD == "scritto in aereo")
    }

    @Test("conflitto con due versioni: nessuna modifica persa")
    func conflictKeepsBothVersions() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "Serie", body: "base", area: .studio, tags: ["analisi"])
        _ = await a.engine.sync()
        _ = await b.engine.sync()

        // Entrambi modificano la versione 1 senza vedersi.
        try a.repository.updateNode(node.id) { $0.bodyMD = "testo di A" }
        try b.repository.updateNode(node.id) {
            $0.bodyMD = "testo di B"
            $0.tags.append("esame")
        }
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        _ = await a.engine.sync()

        for device in [a, b] {
            let merged = try #require(device.store.node(node.id))
            #expect(merged.version == 3)
            #expect(merged.bodyMD.hasPrefix("testo di A"))
            #expect(merged.bodyMD.hasSuffix("testo di B"))
            #expect(merged.tags == ["analisi", "esame"])
            #expect(device.store.versions(of: node.id).map(\.version) == [1, 2, 3])
            #expect(device.store.pendingChanges().isEmpty)
        }
        #expect(a.store.versions(of: node.id)[1].bodyMD == "testo di A")
    }

    @Test("il pull non sovrascrive una modifica locale non ancora inviata")
    func pullKeepsPendingLocalEdit() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "T", body: "v1", area: .studio)
        _ = await a.engine.sync()
        _ = await b.engine.sync()

        try a.repository.updateNode(node.id) { $0.bodyMD = "da A" }
        _ = await a.engine.sync()

        // B modifica offline, poi riceve la versione di A prima di riuscire a inviare.
        try b.repository.updateNode(node.id) { $0.bodyMD = "da B" }
        let pending = try #require(b.store.pendingChange(.node, node.id))
        b.store.removePending(.node, node.id)
        _ = await b.engine.sync() // solo pull, senza outbox
        b.store.savePending(pending)
        try b.repository.updateNode(node.id) { $0.bodyMD = "da B" }
        #expect(b.store.node(node.id)?.bodyMD == "da B")

        _ = await b.engine.sync()
        let merged = try #require(server.node(node.id))
        #expect(merged.bodyMD.contains("da A"))
        #expect(merged.bodyMD.contains("da B"))
    }

    @Test("una modifica durante il push resta in outbox e non perde il merge")
    func editDuringPush() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "T", body: "v1", area: .studio)
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        try b.repository.updateNode(node.id) { $0.bodyMD = "da B" }
        _ = await b.engine.sync()

        try a.repository.updateNode(node.id) { $0.bodyMD = "da A" }
        let repository = a.repository
        a.transport.afterPush = { @MainActor in
            _ = try? repository.updateNode(node.id) { $0.bodyMD = "da A, seconda stesura" }
        }
        _ = await a.engine.sync()
        a.transport.afterPush = nil
        #expect(a.store.pendingChange(.node, node.id) != nil)
        #expect(a.store.node(node.id)?.bodyMD == "da A, seconda stesura")

        _ = await a.engine.sync()
        let final = try #require(server.node(node.id))
        #expect(final.bodyMD.contains("da B"))
        #expect(final.bodyMD.contains("da A, seconda stesura"))
        #expect(a.store.pendingChanges().isEmpty)
    }

    @Test("i nodi di salute e i loro archi non lasciano il dispositivo")
    func healthStaysLocal() async throws {
        let a = Device("ipad-a", server: server)
        let health = a.repository.createNode(type: .health, title: "Pressione", area: .studio)
        let sensitiveArea = a.repository.createNode(type: .concept, title: "Dieta", area: .salute)
        let normal = a.repository.createNode(type: .concept, title: "Biologia", area: .studio)
        _ = try a.repository.createEdge(from: normal.id, to: health.id, kind: .manual)
        _ = try a.repository.createEdge(from: sensitiveArea.id, to: normal.id, kind: .manual)

        #expect(a.store.pendingChanges().map(\.id) == [normal.id])
        _ = await a.engine.sync()
        #expect(server.nodeCount == 1)
        #expect(server.node(health.id) == nil)
        #expect(a.store.node(health.id) != nil, "il nodo di salute resta in locale")
    }

    @Test("un nodo già sincronizzato non può diventare di salute")
    func syncedNodeCannotBecomeHealth() async throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .concept, title: "x", area: .studio)
        #expect(throws: Never.self) {
            // Mai sincronizzato: può diventare sensibile ed esce dall'outbox.
            try a.repository.updateNode(node.id) { $0.area = .salute }
        }
        #expect(a.store.pendingChanges().isEmpty)
        try a.repository.updateNode(node.id) { $0.area = .studio }
        _ = await a.engine.sync()
        #expect(throws: RepositoryError.syncedNodeCannotBecomeSensitive) {
            try a.repository.updateNode(node.id) { $0.type = .health }
        }
        #expect(a.store.node(node.id)?.type == .concept)
    }

    @Test("una modifica rifiutata resta parcheggiata e riparte quando il nodo arriva")
    func rejectedChangeIsParked() async throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .concept, title: "ok", area: .studio)
        // Nodo locale senza voce in outbox: il server non lo conosce e rifiuta l'arco.
        let ghost = NodeRecord(type: .concept, title: "fantasma", area: .studio,
                               createdAt: Date(), updatedAt: Date(), deviceID: "x")
        a.store.saveNode(ghost)
        let edge = try a.repository.createEdge(from: node.id, to: ghost.id, kind: .manual)

        _ = await a.engine.sync()
        #expect(a.engine.rejections.map(\.id) == [edge.id])
        #expect(server.node(node.id) != nil, "il rifiuto non blocca le altre modifiche")

        // Una nuova sync non lo reinvia e non dimentica il rifiuto.
        _ = await a.engine.sync()
        #expect(a.engine.rejections.map(\.id) == [edge.id])
        #expect(a.store.edge(edge.id) != nil)

        // Quando il nodo mancante arriva sul server, l'arco riparte.
        try a.repository.updateNode(ghost.id) { $0.title = "non più fantasma" }
        _ = await a.engine.sync()
        #expect(a.engine.rejections.isEmpty)
        #expect(a.store.pendingChanges().isEmpty)
        #expect(a.store.edge(edge.id)?.version == 1)
    }

    @Test("un nodo reso sensibile durante il primo push non viene sovrascritto")
    func sensitiveDuringFirstPush() async throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .concept, title: "x", body: "pubblico", area: .studio)
        let repository = a.repository
        a.transport.beforePush = { @MainActor in
            _ = try? repository.updateNode(node.id) {
                $0.area = .salute
                $0.bodyMD = "diagnosi"
            }
        }
        _ = await a.engine.sync()
        a.transport.beforePush = nil
        _ = await a.engine.sync()

        let local = try #require(a.store.node(node.id))
        #expect(local.area == .salute)
        #expect(local.bodyMD == "diagnosi")
        #expect(server.node(node.id)?.bodyMD == "pubblico", "il testo sensibile non lascia il dispositivo")
    }

    @Test("un dispositivo nuovo riceve tutto lo storico")
    func freshDeviceGetsFullHistory() async throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .concept, title: "T", body: "v1", area: .studio)
        _ = await a.engine.sync()
        try a.repository.updateNode(node.id) { $0.bodyMD = "v2" }
        _ = await a.engine.sync()
        try a.repository.updateNode(node.id) { $0.bodyMD = "v3" }
        _ = await a.engine.sync()

        let b = Device("ipad-b", server: server)
        _ = await b.engine.sync()
        #expect(b.store.versions(of: node.id).map(\.bodyMD) == ["v1", "v2", "v3"])
    }

    @Test("conflitto sul solo titolo: il corpo non si duplica")
    func titleOnlyConflict() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "T", body: "base", area: .studio)
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        try a.repository.updateNode(node.id) { $0.bodyMD = "nuovo da A" }
        try b.repository.updateNode(node.id) { $0.title = "Titolo di B" }
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        #expect(server.node(node.id)?.bodyMD == "nuovo da A")
        #expect(server.node(node.id)?.title == "Titolo di B")
    }

    @Test("cestino: ripristino sincronizzato, eliminazione definitiva dopo 30 giorni")
    func trashLifecycle() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "Vecchio", area: .studio)
        let keep = a.repository.createNode(type: .concept, title: "Tenuto", area: .studio)
        let edge = try a.repository.createEdge(from: keep.id, to: node.id, kind: .link)
        _ = await a.engine.sync()
        _ = await b.engine.sync()

        try a.repository.trashNode(node.id)
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        #expect(b.store.node(node.id)?.deletedAt != nil, "il cestino si sincronizza")

        try b.repository.restoreNode(node.id)
        _ = await b.engine.sync()
        _ = await a.engine.sync()
        #expect(a.store.node(node.id)?.deletedAt == nil, "il ripristino si sincronizza")

        try a.repository.trashNode(node.id)
        _ = await a.engine.sync()
        _ = await b.engine.sync()

        // 29 giorni: ancora nel cestino.
        a.clock.now = Date().addingTimeInterval(29 * 86_400)
        #expect(a.repository.purgeTrash() == 0)
        #expect(a.repository.trashedNodes().map(\.id) == [node.id])

        // 31 giorni: eliminato, insieme all'arco. Il server fa lo stesso e B lo riceve.
        a.clock.now = Date().addingTimeInterval(31 * 86_400)
        #expect(a.repository.purgeTrash() == 1)
        #expect(a.store.node(node.id) == nil)
        #expect(a.store.edge(edge.id) == nil)
        server.purge(olderThan: a.clock.now.addingTimeInterval(-Repository.trashRetention))
        _ = await b.engine.sync()
        #expect(b.store.node(node.id) == nil)
        #expect(b.store.edge(edge.id) == nil)
        #expect(b.store.node(keep.id) != nil)
    }

    @Test("pull a pagine")
    func pagedPull() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        for i in 0..<(SyncEngine.batchSize + 20) {
            a.repository.createNode(type: .concept, title: "n\(i)", area: .studio)
        }
        _ = await a.engine.sync()
        let outcome = await b.engine.sync()
        #expect(outcome == .synced(pushed: 0, pulled: 2 * (SyncEngine.batchSize + 20)))
        #expect(b.store.allNodes().count == SyncEngine.batchSize + 20)
    }
}
