import Foundation
import Testing
@testable import PitchstoneSync

@MainActor
@Suite("Allegati")
struct AttachmentSyncTests {
    let server = FakeServer()

    /// Un "PDF" finto di `size` byte, diverso per ogni seme.
    func file(_ size: Int, seed: UInt8 = 7) -> Data {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in stride(from: 0, to: size, by: 4096) { bytes[i] = UInt8(truncatingIfNeeded: i / 4096) &+ seed }
        return Data(bytes)
    }

    @discardableResult
    func add(_ data: Data, to device: Device, node: UUID?, name: String = "Dispensa.pdf") throws -> AttachmentRecord {
        let id = UUID()
        try device.files.write(data, for: id)
        return try device.repository.createAttachment(
            id: id, nodeID: node, kind: .pdf, fileName: name, sizeBytes: data.count, sha256: SHA256Digest.hex(data), pageCount: 3)
    }

    @Test("SHA-256: vettori di prova")
    func sha256Vectors() {
        let empty = SHA256Digest.portable(Data()).map { String(format: "%02x", $0) }.joined()
        let abc = SHA256Digest.portable(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        let long = SHA256Digest.portable(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(empty == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(abc == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(long == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(SHA256Digest.hex(Data("abc".utf8)) == abc)
    }

    @Test("un PDF di 100 MB va in parti sotto i 50 MB e torna identico sull'altro dispositivo")
    func largePDFRoundTrip() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "Analisi", area: .studio)
        let data = file(100 * 1024 * 1024)
        let attachment = try add(data, to: a, node: node.id)
        #expect(attachment.partCount == 3)

        _ = await a.engine.sync()
        #expect(a.store.pendingChanges().isEmpty)
        #expect(server.bucket.count == 3)
        #expect(server.largestObject < 50_000_000)
        #expect(server.attachment(attachment.id)?.partCount == 3)

        _ = await b.engine.sync()
        let received = try #require(b.store.attachment(attachment.id))
        #expect(received.isUploaded)
        #expect(!b.files.exists(attachment.id), "il file si scarica quando serve")
        try await b.transfer.ensureLocal(received)
        #expect(try b.files.read(attachment.id) == data)
    }

    @Test("prima i file, poi la riga: offline l'allegato aspetta")
    func uploadBeforeRow() async throws {
        let a = Device("ipad-a", server: server)
        let attachment = try add(file(10_000), to: a, node: nil)
        a.transport.online = false
        _ = await a.engine.sync()
        #expect(server.attachment(attachment.id) == nil)
        #expect(a.store.attachment(attachment.id)?.isUploaded == false)
        #expect(a.store.pendingChanges().map(\.entity) == [.attachment])

        a.transport.online = true
        _ = await a.engine.sync()
        #expect(server.bucket.keys.sorted() == ["\(attachment.storagePath)/part-000"])
        #expect(server.attachment(attachment.id) != nil)
        #expect(a.store.pendingChanges().isEmpty)
    }

    @Test("gli allegati di un nodo di salute restano sul dispositivo")
    func healthAttachmentsStayLocal() async throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .health, title: "Esami del sangue", area: .salute)
        let attachment = try add(file(5_000), to: a, node: node.id)
        #expect(a.store.pendingChanges().isEmpty)
        _ = await a.engine.sync()
        #expect(server.bucket.isEmpty)
        #expect(server.attachment(attachment.id) == nil)
        #expect(a.files.exists(attachment.id))
    }

    @Test("un nodo mai sincronizzato che diventa sensibile porta via anche i suoi allegati")
    func nodeBecomingSensitive() async throws {
        let a = Device("ipad-a", server: server)
        let node = a.repository.createNode(type: .concept, title: "Referto", area: .studio)
        try add(file(5_000), to: a, node: node.id)
        try a.repository.updateNode(node.id) { $0.area = .salute }
        _ = await a.engine.sync()
        #expect(server.bucket.isEmpty)
        #expect(server.nodeCount == 0)
    }

    @Test("un file che non torna identico non viene salvato")
    func corruptedDownload() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let attachment = try add(file(3_000), to: a, node: nil)
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        try server.store(Data("manomesso".utf8), at: "\(attachment.storagePath)/part-000")
        let received = try #require(b.store.attachment(attachment.id))
        await #expect(throws: AttachmentError.corrupted) { try await b.transfer.ensureLocal(received) }
        #expect(!b.files.exists(attachment.id))
    }

    @Test("annotazioni sul PDF: sincronizzate, e in un conflitto due strati sulla stessa pagina")
    func pdfAnnotations() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "Fisica", area: .studio)
        let attachment = try add(file(2_000), to: a, node: node.id)
        let layer = try a.repository.createInkPage(in: node.id, pdf: (attachment.id, 2))
        try a.repository.updateInkPage(layer.id) { $0.inkData = Data([1]) }
        #expect(a.repository.inkPages(of: node.id).isEmpty, "le annotazioni non sono pagine del nodo")
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        #expect(b.repository.pdfAnnotations(of: attachment.id, page: 2).map(\.inkData) == [Data([1])])

        try a.repository.updateInkPage(layer.id) { $0.inkData = Data([2]) }
        try b.repository.updateInkPage(layer.id) { $0.inkData = Data([3]) }
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        _ = await a.engine.sync()
        let layers = a.repository.pdfAnnotations(of: attachment.id, page: 2)
        #expect(Set(layers.map(\.inkData)) == [Data([2]), Data([3])])
        #expect(a.repository.pdfAnnotations(of: attachment.id, page: 1).isEmpty)
    }

    @Test("rinomina, cestino e ripristino; dopo 30 giorni via riga, annotazioni e file")
    func trashAndPurge() async throws {
        let a = Device("ipad-a", server: server)
        let b = Device("ipad-b", server: server)
        let node = a.repository.createNode(type: .concept, title: "Chimica", area: .studio)
        let attachment = try add(file(1_000), to: a, node: node.id)
        try a.repository.createInkPage(in: node.id, pdf: (attachment.id, 0))
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        try await b.transfer.ensureLocal(try #require(b.store.attachment(attachment.id)))

        try a.repository.updateAttachment(attachment.id) { $0.fileName = "Chimica organica.pdf" }
        try a.repository.updateAttachment(attachment.id) { $0.deletedAt = Date() }
        _ = await a.engine.sync()
        _ = await b.engine.sync()
        #expect(b.store.attachment(attachment.id)?.fileName == "Chimica organica.pdf")
        #expect(b.repository.attachments(of: node.id).isEmpty)

        server.purge(olderThan: Date().addingTimeInterval(1))
        _ = await b.engine.sync()
        #expect(b.store.attachment(attachment.id) == nil)
        #expect(b.store.allInkPages().isEmpty)
        #expect(!b.files.exists(attachment.id))
        #expect(server.bucket.isEmpty)
    }

    @Test("pulizia locale del cestino: anche il file")
    func localPurge() throws {
        let a = Device("ipad-a", server: server)
        let attachment = try add(file(1_000), to: a, node: nil)
        try a.repository.updateAttachment(attachment.id) { $0.deletedAt = Date().addingTimeInterval(-31 * 24 * 3600) }
        a.repository.purgeTrash { a.files.remove($0) }
        #expect(a.store.attachment(attachment.id) == nil)
        #expect(!a.files.exists(attachment.id))
    }

    @Test("parti: conteggio e limiti")
    func parts() throws {
        #expect(AttachmentParts.count(forSize: 1) == 1)
        #expect(AttachmentParts.count(forSize: AttachmentParts.partSize) == 1)
        #expect(AttachmentParts.count(forSize: AttachmentParts.partSize + 1) == 2)
        #expect(AttachmentParts.split(Data([1, 2, 3, 4, 5]), partSize: 2) == [Data([1, 2]), Data([3, 4]), Data([5])])
        let a = Device("ipad-a", server: server)
        #expect(throws: AttachmentError.tooLarge) {
            try a.repository.createAttachment(nodeID: nil, kind: .pdf, fileName: "enorme.pdf",
                                              sizeBytes: 101 * AttachmentParts.partSize, sha256: String(repeating: "0", count: 64))
        }
    }
}
