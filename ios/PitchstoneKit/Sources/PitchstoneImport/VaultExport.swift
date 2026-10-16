import Foundation
import PitchstoneSync

/// Esportazione in Markdown compatibile con Obsidian: un file per nodo con il
/// frontmatter (tipo, area, tag, date) e il corpo così com'è, `[[link]]` compresi.
public enum VaultExport {
    public struct File: Sendable, Equatable {
        public var name: String
        public var contents: String
    }

    public static func markdown(_ node: NodeRecord) -> String {
        var lines = ["---"]
        lines.append("type: \(node.type.rawValue)")
        lines.append("area: \(node.area.rawValue)")
        if !node.tags.isEmpty {
            lines.append("tags: [" + node.tags.map(yamlString).joined(separator: ", ") + "]")
        }
        let iso = ISO8601DateFormatter()
        lines.append("created: \(iso.string(from: node.createdAt))")
        lines.append("updated: \(iso.string(from: node.updatedAt))")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + node.bodyMD + (node.bodyMD.hasSuffix("\n") ? "" : "\n")
    }

    /// Un file per nodo attivo. I nodi di salute restano fuori se `includeSensitive` è falso.
    /// Titoli uguali o vuoti diventano nomi distinti, senza caratteri vietati nei file.
    public static func files(_ nodes: [NodeRecord], includeSensitive: Bool) -> [File] {
        var used = Set<String>()
        var result: [File] = []
        for node in nodes.sorted(by: { $0.createdAt < $1.createdAt })
        where node.deletedAt == nil && (includeSensitive || !Privacy.isSensitive(node)) {
            let base = fileName(node.title)
            var name = base
            var n = 2
            while !used.insert(name.lowercased()).inserted {
                name = "\(base) \(n)"
                n += 1
            }
            result.append(File(name: name + ".md", contents: markdown(node)))
        }
        return result
    }

    public static func fileName(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.controlCharacters).union(.newlines)
        let cleaned = title.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? "Senza titolo" : String(trimmed.prefix(120))
    }

    private static func yamlString(_ text: String) -> String {
        text.allSatisfy { $0.isLetter || $0.isNumber || "-_/".contains($0) }
            ? text
            : "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
