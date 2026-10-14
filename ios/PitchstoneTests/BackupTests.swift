import Foundation
import PitchstoneImport
import PitchstoneStore
import PitchstoneSync
import Testing
@testable import Pitchstone

@MainActor
@Suite("Backup ed esportazione", .serialized)
struct BackupTests {
    let model: NotesModel

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "backup-\(UUID().uuidString)"))
        model = NotesModel(container: try PitchstoneSchema.container(inMemory: true), defaults: defaults, startSync: false,
                           attachmentsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test("il backup di salute si apre solo con la password e contiene solo la salute")
    func encryptedHealthBackup() throws {
        let diary = model.createNode(type: .health, title: "Diario", area: .salute, body: "Pressione 130/85")
        model.createNode(title: "Derivata", body: "Studio")
        let sealed = try HealthBackup.seal(model.healthArchive(), password: "una password lunga")
        #expect(!String(decoding: sealed, as: UTF8.self).contains("Pressione"))
        #expect(throws: HealthBackup.BackupError.self) { try HealthBackup.open(sealed, password: "sbagliata!!") }
        #expect(throws: HealthBackup.BackupError.self) { try HealthBackup.seal(model.healthArchive(), password: "corta") }
        let archive = try HealthBackup.open(sealed, password: "una password lunga")
        #expect(archive.nodes.map(\.id) == [diary.id])

        // Su un iPad vuoto il ripristino rimette il nodo, solo locale.
        let defaults = try #require(UserDefaults(suiteName: "restore-\(UUID().uuidString)"))
        let other = NotesModel(container: try PitchstoneSchema.container(inMemory: true), defaults: defaults, startSync: false,
                               attachmentsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(try other.restoreHealth(archive) == 1)
        #expect(other.node(diary.id)?.bodyMD == "Pressione 130/85")
        #expect(other.store.pendingChanges().isEmpty)
    }

    @Test("il PDF di un nodo è un PDF leggibile")
    func pdfExport() throws {
        let node = model.createNode(title: "Derivata", body: "# Definizione\n\nIl **limite** del rapporto incrementale.")
        let data = model.pdf(of: node)
        #expect(data.prefix(4) == Data("%PDF".utf8))
        #expect(data.count > 1000)
    }

    @Test("l'esportazione Markdown salta la salute se non richiesta")
    func markdownExport() {
        model.createNode(type: .health, title: "Diario", area: .salute, body: "x")
        model.createNode(title: "Derivata", body: "y")
        #expect(VaultExport.files(model.nodes, includeSensitive: false).map(\.name) == ["Derivata.md"])
        #expect(VaultExport.files(model.nodes, includeSensitive: true).count == 2)
    }
}
