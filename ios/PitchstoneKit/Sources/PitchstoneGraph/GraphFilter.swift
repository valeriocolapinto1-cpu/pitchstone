import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import PitchstoneSync

/// Ricerca con filtri sul grafo: testo (titolo, corpo, tag), aree e tipi.
/// La ricerca semantica arriva con gli embedding della fase 5.
public struct GraphFilter: Sendable, Equatable {
    public var query: String
    /// Vuoto: tutte le aree.
    public var areas: Set<Area>
    /// Vuoto: tutti i tipi.
    public var types: Set<NodeType>

    public init(query: String = "", areas: Set<Area> = [], types: Set<NodeType> = []) {
        self.query = query
        self.areas = areas
        self.types = types
    }

    public var isActive: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || !areas.isEmpty || !types.isEmpty
    }

    /// Indici dei nodi che corrispondono, ordinati per rilevanza: prima il titolo, poi i tag, poi il corpo.
    public func matches(in graph: GraphData) -> [Int] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var scored: [(Int, Int)] = []
        for (i, node) in graph.nodes.enumerated() {
            if !areas.isEmpty, !areas.contains(node.area) { continue }
            if !types.isEmpty, !types.contains(node.type) { continue }
            guard !terms.isEmpty else {
                scored.append((i, 0))
                continue
            }
            var score = 0
            var all = true
            for term in terms {
                if Self.contains(node.title, term) {
                    score += 10
                } else if node.tags.contains(where: { Self.contains($0, term) }) {
                    score += 5
                } else if Self.contains(node.body, term) {
                    score += 1
                } else {
                    all = false
                    break
                }
            }
            if all { scored.append((i, score)) }
        }
        // Punteggio, poi nodi più collegati, poi ordine stabile.
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            let da = graph.nodes[a.0].degree, db = graph.nodes[b.0].degree
            if da != db { return da > db }
            return a.0 < b.0
        }.map(\.0)
    }

    static func contains(_ text: String, _ term: String) -> Bool {
        text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
