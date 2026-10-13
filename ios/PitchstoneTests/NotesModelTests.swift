import Foundation
import PencilKit
import PitchstoneNotes
import PitchstoneStore
import PitchstoneSync
import SwiftUI
import Testing
@testable import Pitchstone

@MainActor
@Suite("Modello dell'app", .serialized)
struct NotesModelTests {
    let model: NotesModel

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        model = NotesModel(container: try PitchstoneSchema.container(inMemory: true), defaults: defaults, startSync: false)
    }

    @Test("creazione, modifica e outbox")
    func createAndUpdate() throws {
        let node = model.createNode(title: "Derivata", body: "limite")
        #expect(model.activeNodes.map(\.id) == [node.id])
        #expect(model.update(node.id) { $0.bodyMD = "limite del rapporto" })
        #expect(model.node(node.id)?.bodyMD == "limite del rapporto")
        #expect(model.store.pendingChanges().count == 1, "le modifiche si fondono in una voce")
    }

    @Test("i link [[...]] trovano il nodo ignorando maiuscole e accenti, o lo creano")
    func wikiLinkResolution() {
        let node = model.createNode(title: "Perché la derivata")
        #expect(model.openOrCreate(titled: "perche LA derivata", area: .studio) == node.id)
        let created = model.openOrCreate(titled: " Integrale ", area: .progetti)
        #expect(created != node.id)
        #expect(model.node(created)?.title == "Integrale")
        #expect(model.node(created)?.area == .progetti)
    }

    @Test("un nodo di salute resta fuori dall'outbox")
    func healthStaysLocal() {
        let node = model.createNode(type: .health, title: "Pressione", area: .salute)
        #expect(model.node(node.id)?.isSensitive == true)
        #expect(model.store.pendingChanges().isEmpty)
    }

    @Test("cestino con giorni rimasti e ripristino")
    func trash() throws {
        let node = model.createNode(title: "Vecchio")
        model.trash(node.id)
        #expect(model.activeNodes.isEmpty)
        let trashed = try #require(model.trashedNodes.first)
        let deleted = try #require(trashed.deletedAt)
        #expect(model.daysLeftInTrash(trashed, now: deleted) == 30)
        #expect(model.daysLeftInTrash(trashed, now: deleted.addingTimeInterval(29.5 * 86_400)) == 1)
        model.restore(node.id)
        #expect(model.activeNodes.map(\.id) == [node.id])
    }

    @Test("ripristino di una versione dello storico")
    func restoreVersion() {
        let node = model.createNode(title: "T", body: "nuovo")
        // Lo storico arriva dal server: qui lo simuliamo direttamente nell'archivio.
        model.store.saveVersion(NodeVersionRecord(id: UUID(), nodeID: node.id, version: 1, bodyMD: "vecchio", createdAt: Date(), deviceID: "ipad-b"))
        model.restoreVersion(1, of: node.id)
        #expect(model.node(node.id)?.bodyMD == "vecchio")
        model.restoreVersion(7, of: node.id)
        #expect(model.errorMessage != nil)
    }

    @Test("pagine di disegno: creazione, tratti, sfondo, cestino")
    func inkPages() throws {
        let node = model.createNode(title: "Appunti")
        let page = try #require(model.createInkPage(in: node.id, background: .grid))
        let drawing = PKDrawing(strokes: [PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: [
                PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
                PKStrokePoint(location: CGPoint(x: 50, y: 50), timeOffset: 0.1, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
            ], creationDate: Date()))])
        model.updateInkPage(page.id) { $0.inkData = InkCodec.data(from: drawing) }
        let stored = try #require(model.inkPages(of: node.id).first)
        #expect(try InkCodec.drawing(from: stored.inkData).strokes.count == 1)
        #expect(stored.background == .grid)
        #expect(model.store.pendingChanges().map(\.entity) == [.node, .inkPage])
        model.trashInkPage(page.id)
        #expect(model.inkPages(of: node.id).isEmpty)
    }

    @Test("senza indirizzo e token la sync non parte")
    func syncNotConfigured() {
        #expect(model.syncStatus == .notConfigured)
    }
}

@Suite("Testo e link dell'anteprima")
struct MarkdownTextTests {
    @Test("stili inline diventano intenti di presentazione")
    func styles() {
        let text = MarkdownText.attributed([InlineRun("forte", style: [.bold, .italic]), InlineRun(" x")])
        let first = text.runs.first
        #expect(first?.inlinePresentationIntent == [.stronglyEmphasized, .emphasized])
        #expect(String(text.characters) == "forte x")
    }

    @Test("link tra nodi: andata e ritorno, anche con spazi e accenti")
    func nodeLinks() throws {
        let url = try #require(MarkdownText.nodeURL("Serie di Taylor è & co"))
        #expect(MarkdownText.nodeTitle(from: url) == "Serie di Taylor è & co")
        #expect(MarkdownText.nodeTitle(from: try #require(URL(string: "https://example.org"))) == nil)
        let text = MarkdownText.attributed([InlineRun("Taylor", link: .wiki("Serie di Taylor"))])
        #expect(text.runs.first?.link == MarkdownText.nodeURL("Serie di Taylor"))
    }

    @Test("tag: spazi, cancelletti e duplicati")
    func tags() {
        #expect(NodeDetailView.parseTags(" analisi, #esame,, Analisi , fisica ") == ["analisi", "esame", "fisica"])
    }

    @Test("anteprima della prima riga")
    func preview() {
        let node = NodeRecord(type: .concept, title: "x", bodyMD: "\n# Titolo\n- punto", area: .studio,
                              createdAt: Date(), updatedAt: Date(), deviceID: "a")
        #expect(node.preview == "Titolo")
    }
}
