import CommonCrypto
import CryptoKit
import Foundation
import PitchstoneImport
import PitchstoneNotes
import PitchstoneSync
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Backup cifrato dei dati di salute (ADR 0012): AES-GCM con una chiave ricavata
/// dalla password (PBKDF2-SHA256). Il file resta dove l'utente lo salva; senza la
/// password non si apre.
enum HealthBackup {
    /// Formato 1 (solo lettura): `PSB1` + sale + AES-GCM, 310 000 iterazioni, senza dati autenticati.
    static let magicV1 = Data("PSB1".utf8)
    /// Formato 2: `PSB2` + iterazioni (UInt32 big-endian) + sale + AES-GCM. Intestazione, iterazioni e sale
    /// sono dati autenticati (AAD): modificarli fa fallire l'apertura.
    static let magic = Data("PSB2".utf8)
    static let iterationsV1: UInt32 = 310_000
    static let iterations: UInt32 = 600_000
    /// Un file con più iterazioni di così è rovinato o ostile: l'app non resta ore a derivare la chiave.
    static let maxIterations: UInt32 = 10_000_000
    static let saltLength = 16

    enum BackupError: LocalizedError {
        case wrongPassword, notABackup, shortPassword, tooLarge, keyDerivation

        var errorDescription: String? {
            switch self {
            case .wrongPassword: String(localized: "Password sbagliata, o file rovinato.")
            case .notABackup: String(localized: "Il file non è un backup dei dati di salute di Pitchstone.")
            case .shortPassword: String(localized: "Usa una password di almeno 8 caratteri.")
            case .tooLarge: String(localized: "Gli allegati di salute sono troppi per un solo backup (oltre 300 MB): esportane qualcuno a parte e riprova.")
            case .keyDerivation: String(localized: "Non sono riuscito a ricavare la chiave dalla password. Riprova.")
            }
        }
    }

    static func key(password: String, salt: Data, iterations: UInt32 = HealthBackup.iterations) throws -> SymmetricKey {
        var derived = Data(count: 32)
        let passwordData = Data(password.utf8)
        var status = Int32(kCCParamError)
        derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { pw in
                    status = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.baseAddress?.assumingMemoryBound(to: CChar.self), passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        // Una chiave di soli zeri (derivazione fallita) non deve mai cifrare niente.
        guard status == Int32(kCCSuccess) else { throw BackupError.keyDerivation }
        return SymmetricKey(data: derived)
    }

    /// Il backup si cifra in memoria, tutto insieme: oltre questa soglia l'app rischia di chiudersi.
    static let maxFileBytes = 300 * 1024 * 1024

    private static func header(iterations: UInt32, salt: Data) -> Data {
        var bigEndian = iterations.bigEndian
        return magic + Data(bytes: &bigEndian, count: 4) + salt
    }

    static func seal(_ archive: LocalArchive, password: String) throws -> Data {
        guard password.count >= 8 else { throw BackupError.shortPassword }
        guard archive.files.values.reduce(0, { $0 + $1.count }) <= maxFileBytes else { throw BackupError.tooLarge }
        var salt = Data(count: saltLength)
        let generated = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        guard generated == errSecSuccess else { throw BackupError.keyDerivation }
        let plain = try JSONEncoder().encode(archive)
        let head = header(iterations: iterations, salt: salt)
        let box = try AES.GCM.seal(plain, using: key(password: password, salt: salt), authenticating: head)
        guard let combined = box.combined else { throw BackupError.notABackup }
        return head + combined
    }

    static func open(_ data: Data, password: String) throws -> LocalArchive {
        // Tetto prima di toccare il contenuto: dimensione dei dati più intestazione e tag.
        guard data.count <= maxFileBytes * 2 else { throw BackupError.tooLarge }
        let plain: Data
        if data.prefix(magic.count) == magic {
            let headLength = magic.count + 4 + saltLength
            guard data.count > headLength + 28 else { throw BackupError.notABackup }
            let head = Data(data.prefix(headLength))
            let iterationBytes = head.dropFirst(magic.count).prefix(4)
            let count = iterationBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard count >= iterationsV1, count <= maxIterations else { throw BackupError.notABackup }
            let salt = Data(head.suffix(saltLength))
            let combined = Data(data.dropFirst(headLength))
            do {
                plain = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key(password: password, salt: salt, iterations: count), authenticating: head)
            } catch let error as BackupError {
                throw error
            } catch {
                throw BackupError.wrongPassword
            }
        } else if data.prefix(magicV1.count) == magicV1 {
            guard data.count > magicV1.count + saltLength + 28 else { throw BackupError.notABackup }
            let salt = Data(data.dropFirst(magicV1.count).prefix(saltLength))
            let combined = Data(data.dropFirst(magicV1.count + saltLength))
            do {
                plain = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key(password: password, salt: salt, iterations: iterationsV1))
            } catch let error as BackupError {
                throw error
            } catch {
                throw BackupError.wrongPassword
            }
        } else {
            throw BackupError.notABackup
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
