import Foundation
import PitchstoneNotes
import PitchstoneStore
import PitchstoneSync

/// Testo ricercabile da PDF, foto e scrittura a mano (ADR 0008). Calcolato sul
/// dispositivo, mai sincronizzato: ogni iPad lo ricava dai file e dai disegni.
extension NotesModel {
    /// Un'indicizzazione alla volta; una modifica arrivata nel frattempo ne fa partire un'altra.
    func scheduleIndexing() {
        guard indexing == nil else {
            indexAgain = true
            return
        }
        indexing = Task { [weak self] in
            // Lascia finire le modifiche in corso (per esempio un import di più file).
            try? await Task.sleep(for: .seconds(2))
            await self?.reindexText()
            guard let self else { return }
            indexing = nil
            if indexAgain {
                indexAgain = false
                scheduleIndexing()
            }
        }
    }

    /// Estrae il testo delle fonti nuove o cambiate e toglie quello delle fonti sparite.
    /// Se non cambia nulla non ricarica niente: dopo ogni modifica costa poco.
    func reindexText() async {
        let known = textIndex.fingerprints()
        var present = Set<UUID>()
        var updated = false
        for attachment in store.allAttachments() where attachment.deletedAt == nil {
            guard let nodeID = attachment.nodeID, files.exists(attachment.id) else { continue }
            present.insert(attachment.id)
            guard known[attachment.id] != attachment.sha256 else { continue }
            let url = files.url(for: attachment.id)
            let kind = attachment.kind
            let id = attachment.id
            let texts = await Task.detached(priority: .utility) { () -> [ExtractedText] in
                switch kind {
                case .pdf:
                    TextExtractor.pdfPages(at: url).map {
                        ExtractedText(nodeID: nodeID, sourceID: id, source: .pdf, page: $0.page, text: $0.text)
                    }
                case .image:
                    [ExtractedText(nodeID: nodeID, sourceID: id, source: .image, text: TextExtractor.image(at: url))]
                        .filter { !$0.text.isEmpty }
                case .markdown:
                    []
                }
            }.value
            textIndex.replace(sourceID: id, fingerprint: attachment.sha256, with: texts,
                              placeholder: ExtractedText(nodeID: nodeID, sourceID: id, source: .pdf, text: ""))
            updated = true
        }
        let trashedAttachments = Set(store.allAttachments().filter { $0.deletedAt != nil }.map(\.id))
        for page in store.allInkPages() where page.deletedAt == nil && !page.inkData.isEmpty {
            // Le annotazioni di un allegato nel cestino non sono più ricercabili.
            if let attachment = page.attachmentID, trashedAttachments.contains(attachment) { continue }
            present.insert(page.id)
            // Impronta economica: cambia a ogni modifica della pagina, locale o dalla sync.
            let fingerprint = "\(page.version)-\(page.updatedAt.timeIntervalSince1970)-\(page.inkData.count)"
            guard known[page.id] != fingerprint else { continue }
            let data = page.inkData
            let text = await Task.detached(priority: .utility) { TextExtractor.handwriting(data) }.value
            let entry = ExtractedText(nodeID: page.nodeID, sourceID: page.id, source: .handwriting, page: page.pdfPage, text: text)
            textIndex.replace(sourceID: page.id, fingerprint: fingerprint, with: text.isEmpty ? [] : [entry],
                              placeholder: ExtractedText(nodeID: page.nodeID, sourceID: page.id, source: .handwriting, text: ""))
            updated = true
        }
        for gone in Set(known.keys).subtracting(present) {
            textIndex.remove(sourceID: gone)
            updated = true
        }
        // Ricarica (e aggiorna la revisione) solo se qualcosa è cambiato: elenco e grafo
        // vedono subito il testo nuovo.
        if updated {
            reload()
            // Un allegato aspettava il suo testo per partire.
            scheduleSync()
        }
    }

    /// Il primo risultato per ogni nodo, per l'elenco e la ricerca.
    func textMatches(_ query: String) -> [UUID: TextHit] {
        var result: [UUID: TextHit] = [:]
        for hit in TextSearch.search(query, in: extractedTexts) where result[hit.nodeID] == nil {
            result[hit.nodeID] = hit
        }
        return result
    }

    /// Tutto il testo estratto di un nodo, per la ricerca nel grafo.
    func extractedTextByNode() -> [UUID: String] {
        var result: [UUID: String] = [:]
        for text in extractedTexts { result[text.nodeID, default: ""] += "\n" + text.text }
        return result
    }
}
