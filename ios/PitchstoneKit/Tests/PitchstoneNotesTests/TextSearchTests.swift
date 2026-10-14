import Foundation
import Testing
@testable import PitchstoneNotes

@Suite("Ricerca nel testo estratto")
struct TextSearchTests {
    let node = UUID()
    let pdf = UUID()

    @Test("parole in qualsiasi ordine, senza maiuscole né accenti")
    func matches() {
        #expect(TextSearch.matches("lagrange teorema", in: "Il Teorema di LAGRANGE afferma che…"))
        #expect(TextSearch.matches("perché", in: "PERCHE il limite esiste"))
        #expect(!TextSearch.matches("lagrange cauchy", in: "teorema di Lagrange"))
        #expect(!TextSearch.matches("   ", in: "qualsiasi testo"))
    }

    @Test("risultati con pagina ed estratto attorno alla parola")
    func search() {
        let texts = [
            ExtractedText(nodeID: node, sourceID: pdf, source: .pdf, page: 0, text: "Introduzione al corso di analisi."),
            ExtractedText(nodeID: node, sourceID: pdf, source: .pdf, page: 4,
                          text: String(repeating: "testo ", count: 20) + "Il teorema di Lagrange vale per funzioni derivabili " + String(repeating: "altro ", count: 20)),
            ExtractedText(nodeID: node, sourceID: UUID(), source: .handwriting, text: "lagrange a mano"),
        ]
        let hits = TextSearch.search("lagrange", in: texts)
        #expect(hits.map(\.page) == [4, nil])
        #expect(hits[0].snippet.contains("teorema di Lagrange"))
        #expect(hits[0].snippet.hasPrefix("…") && hits[0].snippet.hasSuffix("…"))
        #expect(hits[1].source == .handwriting)
        #expect(TextSearch.search("lagrange", in: texts, limit: 1).count == 1)
    }

    @Test("l'impronta cambia con il contenuto")
    func fingerprint() {
        #expect(TextSearch.fingerprint(Data([1, 2, 3])) == TextSearch.fingerprint(Data([1, 2, 3])))
        #expect(TextSearch.fingerprint(Data([1, 2, 3])) != TextSearch.fingerprint(Data([1, 2, 4])))
        #expect(TextSearch.fingerprint(Data()) != TextSearch.fingerprint(Data([0])))
    }
}
