import Foundation
import PitchstoneNotes
import PitchstoneSync

/// Da dove viene un frammento: il corpo di un nodo, una pagina di un PDF,
/// una foto o una pagina scritta a mano. Una citazione riapre questo punto.
public struct SourceRef: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case node, pdf, image, handwriting
    }

    public var nodeID: UUID
    public var kind: Kind
    /// Allegato (PDF, immagine) o pagina a penna.
    public var sourceID: UUID?
    /// Pagina del PDF, da 0.
    public var page: Int?

    public init(nodeID: UUID, kind: Kind = .node, sourceID: UUID? = nil, page: Int? = nil) {
        self.nodeID = nodeID
        self.kind = kind
        self.sourceID = sourceID
        self.page = page
    }
}

/// Un pezzo di testo abbastanza corto da entrare in un prompt.
public struct Chunk: Sendable, Equatable, Identifiable {
    public var id: String
    public var ref: SourceRef
    /// Titolo del nodo, con la pagina per i PDF: compare nelle fonti numerate.
    public var title: String
    public var text: String

    public init(id: String, ref: SourceRef, title: String, text: String) {
        self.id = id
        self.ref = ref
        self.title = title
        self.text = text
    }
}

public enum Chunker {
    /// Lunghezza indicativa di un frammento, in caratteri.
    public static let targetLength = 700

    /// Testo che la chat può leggere: nodi attivi e non sensibili, con il testo
    /// estratto dai loro allegati e dalle pagine a penna. I nodi di salute non
    /// entrano mai: nessun loro frammento esiste, quindi nessun prompt li contiene.
    /// `excluding`: nodi sospettati di contenere dati di salute, in attesa della scelta dell'utente.
    public static func corpus(nodes: [NodeRecord], extracted: [ExtractedText], excluding: Set<UUID> = []) -> [Chunk] {
        // Le chat salvate non sono fonti: il modello citerebbe le sue risposte di prima.
        let allowed = nodes.filter {
            $0.deletedAt == nil && !Privacy.isSensitive($0) && !$0.tags.contains(ChatTranscript.tag)
                && !excluding.contains($0.id)
        }
        let byNode = Dictionary(grouping: extracted, by: \.nodeID)
        return allowed.flatMap { chunks(of: $0, extracted: byNode[$0.id] ?? []) }
    }

    public static func chunks(of node: NodeRecord, extracted: [ExtractedText] = []) -> [Chunk] {
        let title = node.title.isEmpty ? "Senza titolo" : node.title
        var result: [Chunk] = []
        let body = node.bodyMD.trimmingCharacters(in: .whitespacesAndNewlines)
        // Un nodo senza testo vale comunque per il titolo.
        let parts = body.isEmpty ? [title] : split(body)
        for (n, part) in parts.enumerated() {
            result.append(Chunk(id: "\(node.id.uuidString)|node|\(n)", ref: SourceRef(nodeID: node.id), title: title, text: part))
        }
        for item in extracted {
            let kind: SourceRef.Kind = switch item.source {
            case .pdf: .pdf
            case .image: .image
            case .handwriting: .handwriting
            }
            let label = item.page.map { "\(title) · p. \($0 + 1)" } ?? title
            for (n, part) in split(item.text).enumerated() {
                let id = "\(node.id.uuidString)|\(kind.rawValue)|\(item.sourceID.uuidString)|\(item.page ?? -1)|\(n)"
                result.append(Chunk(
                    id: id, ref: SourceRef(nodeID: node.id, kind: kind, sourceID: item.sourceID, page: item.page),
                    title: label, text: part))
            }
        }
        return result
    }

    /// Paragrafi uniti fino a circa `target` caratteri; un paragrafo troppo lungo
    /// si taglia tra le frasi, o tra le parole se una frase non finisce mai.
    public static func split(_ text: String, target: Int = targetLength) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var result: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { result.append(current) }
            current = ""
        }
        for paragraph in paragraphs {
            for piece in cut(paragraph, limit: target * 3 / 2) {
                if !current.isEmpty, current.count + piece.count + 2 > target { flush() }
                current = current.isEmpty ? piece : current + "\n\n" + piece
            }
        }
        flush()
        return result
    }

    private static func cut(_ paragraph: String, limit: Int) -> [String] {
        guard paragraph.count > limit else { return [paragraph] }
        var pieces: [String] = []
        var current = ""
        for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
            if !current.isEmpty, current.count + word.count + 1 > limit {
                pieces.append(current)
                current = ""
            }
            current = current.isEmpty ? String(word) : current + " " + word
            // Fine frase oltre metà del limite: buon punto per tagliare.
            if current.count > limit / 2, let last = word.last, ".!?".contains(last) {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        // Una "parola" più lunga del limite (un URL, una formula) si spezza a forza.
        return pieces.flatMap { piece -> [String] in
            guard piece.count > limit * 2 else { return [piece] }
            var rest = Substring(piece)
            var parts: [String] = []
            while !rest.isEmpty {
                parts.append(String(rest.prefix(limit)))
                rest = rest.dropFirst(limit)
            }
            return parts
        }
    }
}
