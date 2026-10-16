import CommonCrypto
import CryptoKit
import Foundation
import PitchstoneImport
import PitchstoneNotes
import PitchstoneSync
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Backup cifrato dei dati di salute (ADR 0012): AES-GCM con una chiave ricavata
/// dalla password (PBKDF2-SHA256). Il file resta dove l'utente lo salva; senza la
/// password non si apre.
enum HealthBackup {
    static let magic = Data("PSB1".utf8)
    static let iterations: UInt32 = 310_000

    enum BackupError: LocalizedError {
        case wrongPassword, notABackup, shortPassword, tooLarge

        var errorDescription: String? {
            switch self {
            case .wrongPassword: String(localized: "Password sbagliata, o file rovinato.")
            case .notABackup: String(localized: "Il file non è un backup dei dati di salute di Pitchstone.")
            case .shortPassword: String(localized: "Usa una password di almeno 8 caratteri.")
            case .tooLarge: String(localized: "Gli allegati di salute sono troppi per un solo backup (oltre 300 MB): esportane qualcuno a parte e riprova.")
            }
        }
    }

    static func key(password: String, salt: Data) -> SymmetricKey {
        var derived = Data(count: 32)
        let passwordData = Data(password.utf8)
        derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { pw in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.baseAddress?.assumingMemoryBound(to: CChar.self), passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        return SymmetricKey(data: derived)
    }

    /// Il backup si cifra in memoria, tutto insieme: oltre questa soglia l'app rischia di chiudersi.
    static let maxFileBytes = 300 * 1024 * 1024

    static func seal(_ archive: LocalArchive, password: String) throws -> Data {
        guard password.count >= 8 else { throw BackupError.shortPassword }
        guard archive.files.values.reduce(0, { $0 + $1.count }) <= maxFileBytes else { throw BackupError.tooLarge }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let plain = try JSONEncoder().encode(archive)
        let box = try AES.GCM.seal(plain, using: key(password: password, salt: salt))
        guard let combined = box.combined else { throw BackupError.notABackup }
        return magic + salt + combined
    }

    static func open(_ data: Data, password: String) throws -> LocalArchive {
        guard data.count > magic.count + 16 + 28, data.prefix(magic.count) == magic else { throw BackupError.notABackup }
        let salt = data.dropFirst(magic.count).prefix(16)
        let combined = data.dropFirst(magic.count + 16)
        let plain: Data
        do {
            plain = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key(password: password, salt: Data(salt)))
        } catch {
            throw BackupError.wrongPassword
        }
        guard let archive = try? JSONDecoder().decode(LocalArchive.self, from: plain) else { throw BackupError.notABackup }
        return archive
    }
}

extension NotesModel {
    func healthArchive() -> LocalArchive {
        LocalArchive.health(from: store, files: { [files] id in try? files.read(id) }, now: Date())
    }

    /// Ripristina un backup di salute: aggiunge ciò che manca, non tocca il resto.
    @discardableResult
    func restoreHealth(_ archive: LocalArchive) throws -> Int {
        // Anche dopo un errore: quello che è stato salvato si vede.
        defer {
            reload()
            if autoIndex { scheduleIndexing() }
        }
        return try archive.restore(into: store) { [files] id, data in try files.write(data, for: id) }
    }

    /// PDF leggibile di un nodo, dal suo Markdown.
    func pdf(of node: NodeRecord) -> Data {
        let html = HTMLRenderer.document(title: node.title.isEmpty ? String(localized: "Senza titolo") : node.title, markdown: node.bodyMD)
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        // A4 con margini di 2 cm.
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page.insetBy(dx: 56.7, dy: 56.7), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        for index in 0..<max(1, renderer.numberOfPages) {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }
}

/// Un file da salvare con il selettore di sistema.
struct DataFile: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Una cartella di file Markdown, come un vault di Obsidian.
struct MarkdownFolder: FileDocument {
    static let readableContentTypes: [UTType] = [.folder]
    var files: [VaultExport.File]

    init(files: [VaultExport.File]) { self.files = files }

    init(configuration: ReadConfiguration) throws { files = [] }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var children: [String: FileWrapper] = [:]
        for file in files {
            let wrapper = FileWrapper(regularFileWithContents: Data(file.contents.utf8))
            wrapper.preferredFilename = file.name
            children[file.name] = wrapper
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }
}
