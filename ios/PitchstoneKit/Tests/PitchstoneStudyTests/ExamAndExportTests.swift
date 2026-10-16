import Foundation
import PitchstoneImport
import PitchstoneNotes
import PitchstoneSync
import Testing
@testable import PitchstoneStudy

private let date = Date(timeIntervalSince1970: 1_800_000_000)

private func node(_ title: String, type: NodeType = .concept, area: Area = .studio, tags: [String] = [], body: String = "") -> NodeRecord {
    NodeRecord(type: type, title: title, bodyMD: body, area: area, tags: tags, createdAt: date, updatedAt: date, deviceID: "t")
}

@Suite struct ExamTests {
    @Test func tagsRoundTrip() {
        let info = ExamInfo(date: DateComponents(year: 2027, month: 1, day: 20), status: .studying)
        let tags = info.applied(to: ["esame", "data:2026-01-01", "stato:pianificato"])
        #expect(tags == ["esame", "data:2027-01-20", "stato:studio"])
        #expect(ExamInfo.parse(tags) == info)
        #expect(ExamInfo.parse(["data:2027-13-01"]).date == nil)
        #expect(ExamInfo.parse(["data:2027-02-31"]).date == nil)
        #expect(ExamInfo.parse(["data:2028-02-29"]).date == DateComponents(year: 2028, month: 2, day: 29))
    }

    @Test func calendarOrdersByDateWithLinkedNodes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        let late = node("Fisica", type: .exam, tags: ["data:2027-02-10"])
        let early = node("Analisi 1", type: .exam, tags: ["data:2027-01-20"])
        let undated = node("Chimica", type: .exam)
        let topic = node("Derivata")
        let edge = EdgeRecord(sourceID: topic.id, targetID: early.id, kind: .manual, createdAt: date)
        let entries = ExamEntry.calendar(nodes: [late, early, undated, topic], edges: [edge], calendar: cal)
        #expect(entries.map(\.node.title) == ["Analisi 1", "Fisica", "Chimica"])
        #expect(entries[0].linked == [topic.id])
        let now = cal.date(from: DateComponents(year: 2027, month: 1, day: 10, hour: 22))!
        #expect(entries[0].info.daysLeft(from: now, calendar: cal) == 10)
    }
}

@Suite struct ExportTests {
    @Test func markdownHasFrontmatterAndBody() {
        let n = node("Derivata", tags: ["analisi", "teorema di base"], body: "Il [[Limiti|limite]] del rapporto.")
        let text = VaultExport.markdown(n)
        #expect(text.hasPrefix("---\ntype: concept\narea: studio\ntags: [analisi, \"teorema di base\"]\n"))
        #expect(text.hasSuffix("---\n\nIl [[Limiti|limite]] del rapporto.\n"))
    }

    @Test func yamlEscapesBackslashAndQuotes() {
        let text = VaultExport.markdown(node("X", tags: ["a\\b \"c\""]))
        #expect(text.contains("tags: [\"a\\\\b \\\"c\\\"\"]"))
    }

    @Test func filesAreReadableAndSkipHealth() {
        let files = VaultExport.files([
            node("A/B: c?"), node("A/B: c?"), node(""), node("Diario", type: .health, area: .salute),
        ], includeSensitive: false)
        #expect(files.map(\.name) == ["A B c.md", "A B c 2.md", "Senza titolo.md"])
        #expect(VaultExport.files([node("Diario", area: .salute)], includeSensitive: true).count == 1)
    }

    @Test func htmlEscapesAndRendersBlocks() {
        let html = HTMLRenderer.document(title: "A < B", markdown: "# Titolo\n\n**forte** e [[Nodo]]\n\n- [x] fatto\n\n```\n<x>\n```")
        #expect(html.contains("<title>A &lt; B</title>"))
        #expect(html.contains("<h2>Titolo</h2>"))
        #expect(html.contains("<strong>forte</strong>"))
        #expect(html.contains("<span class=\"wiki\">Nodo</span>"))
        #expect(html.contains("☑ "))
        #expect(html.contains("&lt;x&gt;"))
    }
}

@MainActor
@Suite struct HealthArchiveTests {
    @Test func archiveHoldsOnlyHealthAndRestoresWithoutOverwriting() throws {
        let store = InMemoryStore()
        let repository = Repository(store: store, deviceID: "t")
        let diary = repository.createNode(type: .health, title: "Diario", body: "Pressione", area: .salute)
        let normal = repository.createNode(type: .concept, title: "Derivata", area: .studio)
        _ = try repository.createEdge(from: diary.id, to: normal.id, kind: .manual)
        _ = try repository.createInkPage(in: diary.id)
        let file = try repository.createAttachment(nodeID: diary.id, kind: .image, fileName: "referto.jpg", sizeBytes: 3, sha256: "x")

        let archive = LocalArchive.health(from: store, files: { $0 == file.id ? Data([1, 2, 3]) : nil }, now: date)
        #expect(archive.nodes.map(\.id) == [diary.id])
        #expect(archive.edges.count == 1)
        #expect(archive.inkPages.count == 1)
        #expect(archive.files[file.id] == Data([1, 2, 3]))

        let data = try JSONEncoder().encode(archive)
        let decoded = try JSONDecoder().decode(LocalArchive.self, from: data)
        let fresh = InMemoryStore()
        fresh.saveNode(normal)
        var written: [UUID: Data] = [:]
        #expect(try decoded.restore(into: fresh) { written[$0] = $1 } == 1)
        #expect(fresh.node(diary.id)?.bodyMD == "Pressione")
        #expect(fresh.allEdges().count == 1)
        #expect(written[file.id] == Data([1, 2, 3]))
        #expect(fresh.pendingChanges().isEmpty)
        // Una seconda volta non aggiunge niente.
        #expect(try decoded.restore(into: fresh) { _, _ in } == 0)

        var tampered = decoded
        tampered.nodes.append(normal)
        #expect(throws: RepositoryError.invalidArchive) { try tampered.restore(into: InMemoryStore()) { _, _ in } }
    }

    @Test func missingFilesAreReportedAndNotRestored() throws {
        let store = InMemoryStore()
        let repository = Repository(store: store, deviceID: "t")
        let diary = repository.createNode(type: .health, title: "Diario", area: .salute)
        let file = try repository.createAttachment(nodeID: diary.id, kind: .pdf, fileName: "a.pdf", sizeBytes: 3, sha256: "x")
        let archive = LocalArchive.health(from: store, files: { _ in nil }, now: date)
        #expect(archive.missingFiles == [file.id])
        let fresh = InMemoryStore()
        #expect(try archive.restore(into: fresh) { _, _ in } == 1)
        #expect(fresh.attachment(file.id) == nil)
    }

    @Test func failedFileWriteChangesNothing() throws {
        let store = InMemoryStore()
        let repository = Repository(store: store, deviceID: "t")
        let diary = repository.createNode(type: .health, title: "Diario", area: .salute)
        _ = try repository.createAttachment(nodeID: diary.id, kind: .pdf, fileName: "a.pdf", sizeBytes: 3, sha256: "x")
        let archive = LocalArchive.health(from: store, files: { _ in Data([1]) }, now: date)
        struct Full: Error {}
        let fresh = InMemoryStore()
        #expect(throws: Full.self) { try archive.restore(into: fresh) { _, _ in throw Full() } }
        #expect(fresh.allNodes().isEmpty)
    }
}
