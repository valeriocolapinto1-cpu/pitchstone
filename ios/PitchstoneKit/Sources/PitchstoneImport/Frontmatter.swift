import Foundation

/// Proprietà YAML in testa a una nota Obsidian (`---` ... `---`).
/// Basta il sottoinsieme che Obsidian scrive: `chiave: valore`, `chiave: [a, b]`
/// e le liste con `- voce` sotto la chiave. Se il blocco contiene altro non è
/// frontmatter (per esempio una nota che inizia con una riga orizzontale) e resta testo.
struct Frontmatter: Equatable {
    struct Entry: Equatable {
        var key: String
        var values: [String]
        /// Righe originali, per rimetterle nella nota se l'app non usa la proprietà.
        var lines: [String]
    }

    var entries: [Entry] = []

    func strings(_ keys: String...) -> [String] {
        entries.filter { keys.contains($0.key) }.flatMap(\.values)
    }

    /// Righe originali delle proprietà con queste chiavi, nell'ordine del file.
    func lines(excluding keys: Set<String>) -> [String] {
        entries.filter { !keys.contains($0.key) }.flatMap(\.lines)
    }

    /// Divide il testo in proprietà e corpo. Senza frontmatter valido il testo resta intero.
    static func split(_ text: String) -> (Frontmatter, body: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) }),
              let front = parse(Array(lines[1..<end]))
        else { return (Frontmatter(), text) }
        var body = lines[(end + 1)...].joined(separator: "\n")
        // La riga vuota dopo le proprietà non serve nel corpo.
        while body.hasPrefix("\n") { body.removeFirst() }
        return (front, body)
    }

    private static func parse(_ lines: [String]) -> Frontmatter? {
        var result = Frontmatter()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if !result.entries.isEmpty { result.entries[result.entries.count - 1].lines.append(line) }
                continue
            }
            let indented = line.first == " " || line.first == "\t"
            if indented || trimmed.hasPrefix("-") {
                // Continuazione della proprietà precedente: voce di lista o valore su più righe.
                guard !result.entries.isEmpty else { return nil }
                result.entries[result.entries.count - 1].lines.append(line)
                if trimmed.hasPrefix("- ") || trimmed == "-" {
                    let item = unquote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                    if !item.isEmpty { result.entries[result.entries.count - 1].values.append(item) }
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            var values: [String] = []
            if value.hasPrefix("[") && value.hasSuffix("]") {
                values = splitFlowList(String(value.dropFirst().dropLast()))
            } else if !value.isEmpty {
                values = [unquote(value)]
            }
            result.entries.append(Entry(key: key, values: values, lines: [line]))
        }
        return result
    }

    /// `a, "b, c", 'd'` → [a, b, c, d]: le virgole tra virgolette non separano.
    static func splitFlowList(_ list: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for char in list {
            if let open = quote {
                if char == open { quote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "," {
                items.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        items.append(current)
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
