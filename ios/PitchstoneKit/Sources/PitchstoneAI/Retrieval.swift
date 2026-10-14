import Foundation
import PitchstoneNotes

/// Vettore di un testo per la ricerca semantica. Sull'iPad è NaturalLanguage,
/// gratuito e offline; nei test un finto embedder deterministico.
public protocol TextEmbedder: Sendable {
    func vector(for text: String) -> [Float]?
}

/// Ricerca dei frammenti più vicini a una domanda: somiglianza dei vettori
/// (se c'è un embedder) più parole in comune, così funziona anche senza vettori
/// e i nomi propri o le sigle, che gli embedding confondono, pesano comunque.
public struct SemanticIndex: Sendable {
    public private(set) var chunks: [Chunk]
    /// Vettori per impronta del testo: un testo uguale non si ricalcola.
    public private(set) var vectors: [String: [Float]]
    private let normalized: [String]

    /// `previous` presta i vettori già calcolati per i testi che non sono cambiati.
    public init(chunks: [Chunk], embedder: TextEmbedder?, previous: SemanticIndex? = nil) {
        self.chunks = chunks
        normalized = chunks.map { TextSearch.normalize($0.title + " " + $0.text) }
        var vectors: [String: [Float]] = [:]
        if let embedder {
            for chunk in chunks {
                let key = Self.key(chunk)
                if vectors[key] != nil { continue }
                if let old = previous?.vectors[key] {
                    vectors[key] = old
                } else if let vector = embedder.vector(for: chunk.title + "\n" + chunk.text) {
                    vectors[key] = vector
                }
            }
        }
        self.vectors = vectors
    }

    static func key(_ chunk: Chunk) -> String {
        TextSearch.fingerprint(Data((chunk.title + "\n" + chunk.text).utf8))
    }

    /// Frammenti in ordine di pertinenza. Con `focus` (la chat di un nodo) i
    /// frammenti di quel nodo vengono prima, anche se la domanda non li nomina.
    public func search(_ query: String, embedder: TextEmbedder?, limit: Int = 30, focus: UUID? = nil) -> [Chunk] {
        let words = Self.keywords(query)
        let queryVector = vectors.isEmpty ? nil : embedder?.vector(for: query)
        var scored: [(index: Int, score: Double)] = []
        for (index, chunk) in chunks.enumerated() {
            var lexical = 0.0
            if !words.isEmpty {
                let found = words.filter { normalized[index].contains($0) }.count
                lexical = Double(found) / Double(words.count)
            }
            var semantic = 0.0
            if let queryVector, let vector = vectors[Self.key(chunk)] {
                semantic = max(0, Self.cosine(queryVector, vector))
            }
            var score = queryVector == nil ? lexical : 0.6 * semantic + 0.4 * lexical
            if chunk.ref.nodeID == focus { score += 1 }
            if score > 0.05 { scored.append((index, score)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(limit).map { chunks[$0.index] }
    }

    /// Parole significative: senza accenti né maiuscole, senza parole vuote.
    static func keywords(_ text: String) -> [String] {
        let words = TextSearch.normalize(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return Double(dot / (na.squareRoot() * nb.squareRoot()))
    }

    static let stopwords: Set<String> = [
        "che", "chi", "cosa", "come", "con", "del", "della", "dei", "delle", "degli", "dal", "dalla", "nel", "nella",
        "nei", "per", "tra", "fra", "una", "uno", "gli", "le", "non", "sono", "era", "essere", "questo", "questa",
        "quello", "quella", "anche", "piu", "quale", "quali", "quando", "dove", "perche", "mi", "spiega", "spiegami",
        "dimmi", "cos", "the", "and", "what", "how", "why", "is", "are", "of", "to", "in",
    ]
}
