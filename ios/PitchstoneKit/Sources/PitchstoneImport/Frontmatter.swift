import Foundation

/// Proprietà YAML in testa a una nota Obsidian (`---` ... `---`).
/// Basta il sottoinsieme che Obsidian scrive: `chiave: valore`, `chiave: [a, b]`
/// e le liste con `- voce` sotto la chiave.
struct Frontmatter: Equatable {
    /// Chiave in minuscolo → valori, nell'ordine del file.
    var values: [String: [String]] = [:]
    /// Righe originali delle proprietà che l'app non usa: restano nella nota.
    var otherLines: [String] = []

    /// Divide il testo in proprietà e corpo. Senza frontmatter valido il testo resta intero.
    static func split(_ text: String) -> (Frontmatter, body: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) })
        else { return (Frontmatter(), text) }
        let front = parse(Array(lines[1..<end]))
        var body = lines[(end + 1)...].joined(separator: "\n")
        // La riga vuota dopo le proprietà non serve nel corpo.
        while body.hasPrefix("\n") { body.removeFirst() }
        return (front, body)
    }

    func strings(_ keys: String...) -> [String] {
        keys.flatMap { values[$0] ?? [] }
    }

    static let knownKeys: Set<String> = ["tags", "tag", "aliases", "alias", "area", "type", "tipo"]

    private static func parse(_ lines: [String]) -> Frontmatter {
        var result = Frontmatter()
        var currentKey: String?
        var currentLines: [String] = []

        func flush() {
            guard let key = currentKey else { return }
            if !knownKeys.contains(key) { result.otherLines += currentLines }
            currentKey = nil
            currentLines = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if currentKey != nil { currentLines.append(line) }
                continue
            }
            let indented = line.first == " " || line.first == "\t"
            if (indented || trimmed.hasPrefix("- ")) && currentKey != nil {
                currentLines.append(line)
                if trimmed.hasPrefix("- ") || trimmed == "-" {
                    let item = unquote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                    if !item.isEmpty, let key = currentKey { result.values[key, default: []].append(item) }
                }
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            currentKey = key
            currentLines = [line]
            if value.hasPrefix("[") && value.hasSuffix("]") {
                let items = value.dropFirst().dropLast().split(separator: ",")
                    .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
                result.values[key, default: []] += items
            } else if !value.isEmpty {
                result.values[key, default: []].append(unquote(value))
            }
        }
        flush()
        return result
    }

    private static func unquote(_ value: String) -> String {
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
