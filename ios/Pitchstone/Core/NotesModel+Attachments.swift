import Foundation
import PDFKit
import PitchstoneStore
import PitchstoneSync
import UniformTypeIdentifiers

enum AttachmentImportError: LocalizedError {
    case unsupported
    case unreadablePDF

    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Si possono allegare PDF e immagini.")
        case .unreadablePDF: String(localized: "Il PDF non si apre: forse è danneggiato o protetto.")
        }
    }
}

extension AttachmentError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingLocalFile: String(localized: "Il file non è su questo dispositivo.")
        case .corrupted: String(localized: "Il file è vuoto o rovinato.")
        case .tooLarge: String(localized: "Il file supera i 500 MB.")
        }
    }
}

/// Allegati (ADR 0007): il file sta nell'archivio dell'app; con la sync configurata
/// va anche nel bucket privato, diviso in parti.
extension NotesModel {
    func attachments(of nodeID: UUID) -> [AttachmentRecord] {
        _ = inkRevision
        return repository.attachments(of: nodeID)
    }

    func attachment(_ id: UUID) -> AttachmentRecord? {
        _ = inkRevision
        return store.attachment(id)
    }

    /// Copia il file nell'archivio dell'app e lo collega al nodo.
    @discardableResult
    func attach(fileAt url: URL, to nodeID: UUID) throws -> AttachmentRecord {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)
        let kind: AttachmentKind
        if type?.conforms(to: .pdf) == true {
            kind = .pdf
        } else if type?.conforms(to: .image) == true {
            kind = .image
        } else {
            throw AttachmentImportError.unsupported
        }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var pageCount: Int?
        if kind == .pdf {
            guard let document = PDFDocument(data: data) else { throw AttachmentImportError.unreadablePDF }
            pageCount = document.pageCount
        }
        let id = UUID()
        try files.write(data, for: id)
        do {
            let attachment = try repository.createAttachment(
                id: id, nodeID: nodeID, kind: kind, fileName: url.lastPathComponent, sizeBytes: data.count,
                sha256: SHA256Digest.hex(data), pageCount: pageCount)
            changed()
            return attachment
        } catch {
            files.remove(id)
            throw error
        }
    }

    /// Un documento importato diventa un nodo con il nome del file, nell'area scelta.
    @discardableResult
    func importDocument(at url: URL, area: Area) throws -> UUID {
        let node = createNode(title: url.deletingPathExtension().lastPathComponent, area: area)
        do {
            try attach(fileAt: url, to: node.id)
        } catch {
            trash(node.id)
            throw error
        }
        return node.id
    }

    /// Il file sul dispositivo, scaricandolo dal bucket se serve.
    func localFile(for attachment: AttachmentRecord) async throws -> URL {
        if files.exists(attachment.id) { return files.url(for: attachment.id) }
        guard let transfer else { throw AttachmentError.missingLocalFile }
        return try await transfer.ensureLocal(attachment)
    }

    func trashAttachment(_ id: UUID) {
        perform { try repository.updateAttachment(id) { $0.deletedAt = Date() } }
    }

    // MARK: Annotazioni

    func pdfAnnotationLayers(_ attachmentID: UUID, page: Int) -> [InkPageRecord] {
        repository.pdfAnnotations(of: attachmentID, page: page)
    }

    /// Salva i tratti di una pagina del PDF. Senza strato se ne crea uno; se lo strato
    /// è cambiato nel frattempo (sync) i tratti vanno in un nuovo strato. Ritorna lo strato usato.
    func savePDFAnnotation(_ data: Data, attachment: AttachmentRecord, page: Int, layer: UUID?, loadedFrom: Data) -> UUID? {
        guard let nodeID = attachment.nodeID else { return nil }
        do {
            let id: UUID
            if let layer {
                id = try repository.saveDrawing(data, to: layer, loadedFrom: loadedFrom).id
            } else {
                let created = try repository.createInkPage(in: nodeID, pdf: (attachment.id, page))
                id = try repository.updateInkPage(created.id) { $0.inkData = data }.id
            }
            changed()
            return id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Dopo un conflitto una pagina può avere più strati: si uniscono nel primo.
    func mergePDFLayers(_ layers: [InkPageRecord], into merged: Data) -> UUID? {
        guard let first = layers.first else { return nil }
        perform {
            try repository.updateInkPage(first.id) { $0.inkData = merged }
            for other in layers.dropFirst() { try repository.trashInkPage(other.id) }
        }
        return first.id
    }

    /// Un nodo nuovo con il testo selezionato nel PDF, collegato al nodo del PDF.
    @discardableResult
    func createNode(fromQuote quote: String, attachment: AttachmentRecord, page: Int) -> UUID {
        let text = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let title = firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
        let source = attachment.nodeID.flatMap(node)?.title ?? attachment.fileName
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        let area = attachment.nodeID.flatMap(node)?.area ?? .studio
        let created = createNode(title: title, area: area)
        update(created.id) {
            $0.bodyMD = "\(quoted)\n\nDa [[\(source)]], pagina \(page + 1)."
        }
        return created.id
    }
}
