import Foundation

/// Testo estratto da allegati e pagine a penna (PDF, OCR di foto, scrittura a mano),
/// ricercabile insieme alle note. È un dato derivato: ogni dispositivo lo ricalcola
/// dai file e dai disegni, non si sincronizza.
public struct ExtractedText: Sendable, Equatable, Codable {
    public enum Source: String, Sendable, Codable {
        case pdf, image, handwriting
    }

    public var nodeID: UUID
    /// Allegato o pagina a penna da cui viene il testo.
    public var sourceID: UUID
    public var source: Source
    /// Pagina (da 0) per i PDF.
    public var page: Int?
    public var text: String

    public init(nodeID: UUID, sourceID: UUID, source: Source, page: Int? = nil, text: String) {
        self.nodeID = nodeID
        self.sourceID = sourceID
        self.source = source
        self.page = page
        self.text = text
    }
}

/// Un risultato: dove si trova il testo e un estratto attorno alla parola cercata.
public struct TextHit: Sendable, Equatable {
    public var nodeID: UUID
    public var sourceID: UUID
    public var source: ExtractedText.Source
    public var page: Int?
    public var snippet: String
}

public enum TextSearch {
    /// Confronto senza maiuscole né accenti, spazi compressi.
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Tutte le parole della ricerca devono comparire nel testo, in qualsiasi ordine.
    public static func matches(_ query: String, in text: String) -> Bool {
        let words = normalize(query).split(separator: " ")
        guard !words.isEmpty else { return false }
        let haystack = normalize(text)
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Risultati in ordine: per nodo, poi per pagina. Al più un risultato per pagina.
    public static func search(_ query: String, in texts: [ExtractedText], limit: Int = 200) -> [TextHit] {
        var hits: [TextHit] = []
        for item in texts where matches(query, in: item.text) {
            hits.append(TextHit(nodeID: item.nodeID, sourceID: item.sourceID, source: item.source, page: item.page,
                                snippet: snippet(around: query, in: item.text)))
            if hits.count == limit { break }
        }
        return hits
    }

    /// Una sessantina di caratteri attorno alla prima parola trovata.
    public static func snippet(around query: String, in text: String, radius: Int = 40) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let word = normalize(query).split(separator: " ").first,
              let range = flat.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
        else { return String(flat.prefix(radius * 2)) }
        let start = flat.index(range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    /// Impronta di un contenuto: si ricalcola il testo solo se è cambiata.
    public static func fingerprint(_ data: Data) -> String {
        // FNV-1a a 64 bit: veloce, basta a riconoscere un disegno cambiato.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16) + "-\(data.count)"
    }
}
