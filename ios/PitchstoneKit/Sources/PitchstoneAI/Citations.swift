import Foundation

/// Una fonte citata nella risposta: il numero scritto dal modello e il punto
/// degli appunti da riaprire.
public struct Citation: Sendable, Equatable, Hashable, Codable {
    public var number: Int
    public var ref: SourceRef
    public var title: String

    public init(number: Int, ref: SourceRef, title: String) {
        self.number = number
        self.ref = ref
        self.title = title
    }
}

public enum Citations {
    public static let scheme = "pitchstone-source"

    /// Numeri tra parentesi quadre: `[2]`, `[1, 3]`, `[1][4]`. I numeri senza
    /// fonte corrispondente (inventati dal modello) si ignorano.
    public static func extract(from answer: String, sources: [Chunk]) -> [Citation] {
        var seen = Set<Int>()
        var result: [Citation] = []
        for number in numbers(in: answer) where number >= 1 && number <= sources.count && seen.insert(number).inserted {
            let chunk = sources[number - 1]
            result.append(Citation(number: number, ref: chunk.ref, title: chunk.title))
        }
        return result
    }

    /// La risposta con ogni `[n]` valido trasformato in un link Markdown verso la fonte.
    public static func linked(_ answer: String, citations: [Citation]) -> String {
        let byNumber = Dictionary(citations.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var output = ""
        var index = answer.startIndex
        while index < answer.endIndex {
            if answer[index] == "[", let (numbers, end) = group(in: answer, at: index),
               numbers.allSatisfy({ byNumber[$0] != nil }) {
                // `\[1\]` e non `[1]`: un testo `[[...]]` diventerebbe un link tra nodi.
                output += numbers.map { "[\\[\($0)\\]](\(url(for: byNumber[$0]!.ref).absoluteString))" }.joined()
                index = end
            } else {
                output.append(answer[index])
                index = answer.index(after: index)
            }
        }
        return output
    }

    public static func url(for ref: SourceRef) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ref.kind.rawValue
        var items = [URLQueryItem(name: "node", value: ref.nodeID.uuidString)]
        if let source = ref.sourceID { items.append(URLQueryItem(name: "source", value: source.uuidString)) }
        if let page = ref.page { items.append(URLQueryItem(name: "page", value: String(page))) }
        components.queryItems = items
        return components.url!
    }

    public static func ref(from url: URL) -> SourceRef? {
        guard url.scheme == scheme, let host = url.host, let kind = SourceRef.Kind(rawValue: host),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let node = items.first(where: { $0.name == "node" })?.value.flatMap(UUID.init(uuidString:))
        else { return nil }
        let source = items.first { $0.name == "source" }?.value.flatMap(UUID.init(uuidString:))
        let page = items.first { $0.name == "page" }?.value.flatMap { Int($0) }
        return SourceRef(nodeID: node, kind: kind, sourceID: source, page: page)
    }

    static func numbers(in text: String) -> [Int] {
        var result: [Int] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "[", let (numbers, end) = group(in: text, at: index) {
                result += numbers
                index = end
            } else {
                index = text.index(after: index)
            }
        }
        return result
    }

    /// `[1]` o `[1, 2]` che inizia in `start`: i numeri e la posizione dopo `]`.
    private static func group(in text: String, at start: String.Index) -> ([Int], String.Index)? {
        guard let close = text[start...].firstIndex(of: "]") else { return nil }
        let inside = text[text.index(after: start)..<close]
        guard !inside.isEmpty, inside.count <= 20,
              inside.allSatisfy({ $0.isNumber || $0 == "," || $0 == " " }) else { return nil }
        let numbers = inside.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !numbers.isEmpty else { return nil }
        return (numbers, text.index(after: close))
    }
}
