import CryptoKit
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

    @Test("il formato 2 autentica l'intestazione; il formato 1 si apre ancora; iterazioni assurde si rifiutano")
    func backupFormats() throws {
        model.createNode(type: .health, title: "Diario", area: .salute, body: "Pressione 130/85")
        let password = "una password lunga"
        let sealed = try HealthBackup.seal(model.healthArchive(), password: password)
        #expect(sealed.prefix(4) == HealthBackup.magic)

        // Un byte cambiato nelle iterazioni (ma ancora valide) o nel sale: l'apertura fallisce.
        var tamperedSalt = sealed
        tamperedSalt[10] ^= 0x01
        #expect(throws: HealthBackup.BackupError.self) { try HealthBackup.open(tamperedSalt, password: password) }
        var absurd = sealed
        absurd.replaceSubrange(4..<8, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: HealthBackup.BackupError.self) { try HealthBackup.open(absurd, password: password) }

        // Backup del formato 1, scritto come lo scriveva la versione precedente.
        let salt = Data((0..<16).map { UInt8($0) })
        let plain = try JSONEncoder().encode(model.healthArchive())
        let box = try AES.GCM.seal(plain, using: HealthBackup.key(password: password, salt: salt, iterations: HealthBackup.iterationsV1))
        let legacy = HealthBackup.magicV1 + salt + (try #require(box.combined))
        #expect(try HealthBackup.open(legacy, password: password).nodes.count == 1)
        #expect(throws: HealthBackup.BackupError.self) { try HealthBackup.open(Data("PSB9".utf8) + Data(count: 100), password: password) }
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
