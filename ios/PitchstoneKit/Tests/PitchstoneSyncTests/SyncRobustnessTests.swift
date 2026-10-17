import Foundation
import Testing
@testable import PitchstoneSync

/// Trasporto che passa tutto al server finto ma può cambiare la risposta di push o di pull.
final class TamperingTransport: SyncTransport, @unchecked Sendable {
    let inner: FakeTransport
    var pushResponse: (@Sendable (PushRequest, PushResponse) -> PushResponse)?
    var pullResponse: (@Sendable (PullRequest, PullResponse) -> PullResponse)?
    private let lock = NSLock()
    private var _pullCursors: [Int64] = []
    var pullCursors: [Int64] { lock.withLock { _pullCursors } }

    init(_ inner: FakeTransport) { self.inner = inner }

    func push(_ request: PushRequest) async throws -> PushResponse {
        let response = try await inner.push(request)
        return pushResponse?(request, response) ?? response
    }

    func pull(_ request: PullRequest) async throws -> PullResponse {
        lock.withLock { _pullCursors.append(request.cursor) }
        let response = try await inner.pull(request)
        return pullResponse?(request, response) ?? response
    }
}

@MainActor
@Suite("Robustezza della sync")
struct SyncRobustnessTests {
    let server = FakeServer()

    nonisolated static func entity(of payload: OutgoingChange.Payload) -> Entity {
        switch payload {
        case .node: .node
        case .edge: .edge
        case .inkPage: .inkPage
        case .attachment: .attachment
        }
    }

    func engine(_ device: Device, _ transport: SyncTransport) -> SyncEngine {
        SyncEngine(store: device.store, transport: transport, deviceID: "ipad-a")
    }

    @Test("uno stato sconosciuto del server lascia la voce in outbox, senza rifiuto, e la riprova")
    func unknownStatusStaysPending() async throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .concept, title: "uno", area: .studio)
        let tampering = TamperingTransport(a.transport)
        tampering.pushResponse = { _, response in
            PushResponse(results: response.results.map {
                PushResult(entity: $0.entity, id: $0.id, status: .unknown)
            })
        }
        let sync = engine(a, tampering)
        _ = await sync.sync()
        #expect(a.store.pendingChange(.node, node.id) != nil)
        #expect(a.store.pendingChange(.node, node.id)?.rejection == nil)
        #expect(a.store.node(node.id)?.version == 0, "il record locale non viene toccato")

        tampering.pushResponse = nil
        _ = await sync.sync()
        #expect(a.store.pendingChanges().isEmpty)
    }

    @Test("i risultati si abbinano per id, non per posizione")
    func resultsAreMatchedByID() async throws {
        let a = Device("ipad-a", server: server)
        let first = a.repository.createNode(type: .concept, title: "primo", area: .studio)
        let second = a.repository.createNode(type: .concept, title: "secondo", area: .studio)
        let tampering = TamperingTransport(a.transport)
        tampering.pushResponse = { _, response in PushResponse(results: response.results.reversed()) }
        _ = await engine(a, tampering).sync()
        #expect(a.store.node(first.id)?.title == "primo")
        #expect(a.store.node(second.id)?.title == "secondo")
        #expect(a.store.node(first.id)?.version == 1)
        #expect(a.store.node(second.id)?.version == 1)
        #expect(a.store.pendingChanges().isEmpty)
    }

    @Test("un risultato con un id che non è di nessuna voce non si applica a nessuna")
    func foreignIDsAreIgnored() async throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .concept, title: "uno", area: .studio)
        let tampering = TamperingTransport(a.transport)
        let stranger = UUID()
        tampering.pushResponse = { _, response in
            PushResponse(results: response.results.map {
                var result = $0
                result.id = stranger
                result.node?.id = stranger
                return result
            })
        }
        _ = await engine(a, tampering).sync()
        #expect(a.store.node(stranger) == nil)
        #expect(a.store.pendingChange(.node, node.id) != nil, "la voce resta in outbox")
    }

    @Test("con più voci di un lotto i nodi partono comunque prima degli archi")
    func wholeQueueIsOrderedBeforeTheCut() async throws {
        let a = Device("ipad-a", server: server)
        let base = a.repository.createNode(type: .concept, title: "base", area: .studio)
        let other = a.repository.createNode(type: .concept, title: "altro", area: .studio)
        _ = await a.engine.sync()
        for _ in 0...SyncEngine.batchSize {
            _ = try a.repository.createEdge(from: base.id, to: other.id, kind: .manual)
        }
        // Un nodo nuovo, in coda all'outbox dopo più archi di quanti ne entrino in un lotto.
        let late = a.repository.createNode(type: .concept, title: "ultimo", area: .studio)
        let tampering = TamperingTransport(a.transport)
        let recorder = Recorder()
        tampering.pushResponse = { request, response in
            recorder.record(request.changes.map { Self.entity(of: $0.payload) })
            return response
        }
        _ = await engine(a, tampering).sync()
        let firstBatch = recorder.batches.first ?? []
        #expect(firstBatch.first == .node, "il nodo parte nel primo lotto, prima degli archi")
        #expect(server.node(late.id) != nil)
        #expect(a.store.pendingChanges().isEmpty)
    }

    @Test("un'epoca nuova fa ripartire il pull da zero; la prima volta si ricorda e basta")
    func epochChangeRestartsThePull() async throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .concept, title: "uno", area: .studio)
        _ = await a.engine.sync()
        let cursor = a.store.cursor
        #expect(cursor > 0)

        let tampering = TamperingTransport(a.transport)
        tampering.pullResponse = { _, response in
            PullResponse(changes: response.changes, cursor: response.cursor, hasMore: response.hasMore, epoch: 1)
        }
        let sync = engine(a, tampering)
        _ = await sync.sync()
        #expect(a.store.epoch == 1)
        #expect(tampering.pullCursors.allSatisfy { $0 == cursor }, "la prima epoca non azzera nulla")

        // Il server viene ripristinato: epoca 2. Il cursore torna a zero e il pull riparte.
        tampering.pullResponse = { _, response in
            PullResponse(changes: response.changes, cursor: response.cursor, hasMore: response.hasMore, epoch: 2)
        }
        let before = tampering.pullCursors.count
        _ = await sync.sync()
        #expect(a.store.epoch == 2)
        let seen = Array(tampering.pullCursors.dropFirst(before))
        #expect(seen.first == cursor, "il primo pull parte dal cursore vecchio")
        #expect(seen.dropFirst().first == 0, "e poi riparte da zero")
        #expect(a.store.node(node.id) != nil)

        // Stessa epoca: niente di nuovo.
        let again = tampering.pullCursors.count
        _ = await sync.sync()
        #expect(tampering.pullCursors.dropFirst(again).allSatisfy { $0 >= cursor })
    }

    @Test("un rifiuto per genitore mancante si riprova poche volte, con attese crescenti")
    func parkedChangesRetryWithBackoff() async throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .concept, title: "ok", area: .studio)
        let ghost = NodeRecord(type: .concept, title: "fantasma", area: .studio, createdAt: Date(), updatedAt: Date(), deviceID: "x")
        a.store.saveNode(ghost)
        let edge = try a.repository.createEdge(from: node.id, to: ghost.id, kind: .manual)
        _ = await a.engine.sync()
        #expect(a.engine.rejections.map(\.id) == [edge.id])
        let afterFirst = server.pushSizes.count

        // Seconda sync: la voce riparte da sola (primo tentativo automatico) e viene rifiutata di nuovo.
        _ = await a.engine.sync()
        #expect(server.pushSizes.count == afterFirst + 1)
        #expect(a.engine.rejections.map(\.id) == [edge.id])

        // Subito dopo l'attesa non è ancora passata: non si reinvia.
        _ = await a.engine.sync()
        _ = await a.engine.sync()
        #expect(server.pushSizes.count == afterFirst + 1)
        #expect(a.engine.rejections.map(\.id) == [edge.id])
    }

    @Test("un rifiuto che non si risolve da solo aspetta l'utente")
    func permanentRejectionsAreNotRetried() async throws {
        let a = Device("ipad-a", server: server)
        server.rejectNodes = true
        _ = a.repository.createNode(type: .concept, title: "uno", area: .studio)
        _ = await a.engine.sync()
        let afterFirst = server.pushSizes.count
        _ = await a.engine.sync()
        _ = await a.engine.sync()
        #expect(server.pushSizes.count == afterFirst)
        #expect(a.engine.rejections.count == 1)
    }

    // MARK: Caricamento a parti

    func file(_ size: Int, seed: UInt8 = 7) -> Data {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in stride(from: 0, to: size, by: 4096) { bytes[i] = UInt8(truncatingIfNeeded: i / 4096) &+ seed }
        return Data(bytes)
    }

    @Test("un caricamento interrotto riprende dalle parti che mancano")
    func uploadResumesFromTheLastPart() async throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .concept, title: "Analisi", area: .studio)
        let data = file(100 * 1024 * 1024)
        let id = UUID()
        try a.files.write(data, for: id)
        let attachment = try a.repository.createAttachment(
            id: id, nodeID: node.id, kind: .pdf, fileName: "Dispensa.pdf", sizeBytes: data.count, sha256: SHA256Digest.hex(data), pageCount: 3)
        #expect(attachment.partCount == 3)

        // La rete cade dopo la prima parte.
        a.transport.putLimit = 1
        _ = await a.engine.sync()
        #expect(a.transport.putCount == 1)
        #expect(server.attachment(attachment.id) == nil, "la riga non parte finché mancano parti")
        #expect(a.files.uploadedParts(of: id, sha256: attachment.sha256) == [0])

        // Torna la rete: si caricano solo le parti 1 e 2.
        a.transport.putLimit = nil
        _ = await a.engine.sync()
        #expect(a.transport.putCount == 3, "una sola parte rimandata due volte sarebbe 4")
        #expect(server.bucket.count == 3)
        #expect(server.attachment(attachment.id) != nil)
        #expect(a.files.uploadedParts(of: id, sha256: attachment.sha256).isEmpty, "finito: il segno si toglie")
        #expect(a.store.pendingChanges().isEmpty)
    }

    @Test("un segno di un altro contenuto non vale")
    func staleMarkersAreIgnored() {
        let files = MemoryFiles()
        let id = UUID()
        files.markUploaded(part: 0, of: id, sha256: "aaaa")
        #expect(files.uploadedParts(of: id, sha256: "bbbb").isEmpty)
        #expect(files.uploadedParts(of: id, sha256: "aaaa") == [0])
    }

    @Test("su disco il segno sta accanto al file e sparisce con lui")
    func directoryMarkers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = DirectoryAttachmentFiles(directory: directory)
        let id = UUID()
        try files.write(Data([1, 2, 3]), for: id)
        files.markUploaded(part: 2, of: id, sha256: "abc")
        files.markUploaded(part: 0, of: id, sha256: "abc")
        #expect(files.uploadedParts(of: id, sha256: "abc") == [0, 2])
        #expect(files.uploadedParts(of: id, sha256: "xyz").isEmpty)
        files.remove(id)
        #expect(files.uploadedParts(of: id, sha256: "abc").isEmpty)
        #expect(!files.exists(id))
        try? FileManager.default.removeItem(at: directory)
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _batches: [[Entity]] = []
    var batches: [[Entity]] { lock.withLock { _batches } }
    func record(_ batch: [Entity]) { lock.withLock { _batches.append(batch) } }
}
