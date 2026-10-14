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
    func reindexText() async {
        var present = Set<UUID>()
        for attachment in store.allAttachments() where attachment.deletedAt == nil {
            guard let nodeID = attachment.nodeID, files.exists(attachment.id) else { continue }
            present.insert(attachment.id)
            guard textIndex.fingerprint(of: attachment.id) != attachment.sha256 else { continue }
            let url = files.url(for: attachment.id)
            let kind = attachment.kind
            let id = attachment.id
            let texts: [ExtractedText] = await Task.detached(priority: .utility) {
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
        }
        for page in store.allInkPages() where page.deletedAt == nil && !page.inkData.isEmpty {
            present.insert(page.id)
            let fingerprint = TextSearch.fingerprint(page.inkData)
            guard textIndex.fingerprint(of: page.id) != fingerprint else { continue }
            let data = page.inkData
            let text = await Task.detached(priority: .utility) { TextExtractor.handwriting(data) }.value
            let entry = ExtractedText(nodeID: page.nodeID, sourceID: page.id, source: .handwriting, page: page.pdfPage, text: text)
            textIndex.replace(sourceID: page.id, fingerprint: fingerprint, with: text.isEmpty ? [] : [entry],
                              placeholder: ExtractedText(nodeID: page.nodeID, sourceID: page.id, source: .handwriting, text: ""))
        }
        for gone in textIndex.sourceIDs().subtracting(present) { textIndex.remove(sourceID: gone) }
        // Ricarica (e aggiorna la revisione): elenco e grafo vedono subito il testo nuovo.
        reload()
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
