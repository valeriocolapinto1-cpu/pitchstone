import Foundation

/// Differenze riga per riga tra due versioni di un nodo, per lo storico.
public enum DiffLine: Hashable, Sendable {
    case same(String)
    case added(String)
    case removed(String)
}

public enum LineDiff {
    /// Oltre questa dimensione (righe × righe) il confronto diventa "tutto tolto, tutto aggiunto",
    /// per non bloccare l'interfaccia su note enormi.
    public static let maxCells = 4_000_000

    public static func diff(_ old: String, _ new: String) -> [DiffLine] {
        let a = lines(old)
        let b = lines(new)
        // Prefisso e suffisso comuni fuori dalla tabella: le modifiche sono quasi sempre locali.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])

        var result = a[..<prefix].map(DiffLine.same)
        result += middle(midA, midB)
        result += a[(a.count - suffix)...].map(DiffLine.same)
        return result
    }

    public static func summary(_ diff: [DiffLine]) -> (added: Int, removed: Int) {
        diff.reduce(into: (0, 0)) { acc, line in
            switch line {
            case .added: acc.0 += 1
            case .removed: acc.1 += 1
            case .same: break
            }
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Sottosequenza comune più lunga, poi lettura all'indietro della tabella.
    private static func middle(_ a: [String], _ b: [String]) -> [DiffLine] {
        if a.isEmpty { return b.map(DiffLine.added) }
        if b.isEmpty { return a.map(DiffLine.removed) }
        guard a.count * b.count <= maxCells else { return a.map(DiffLine.removed) + b.map(DiffLine.added) }

        let width = b.count + 1
        var table = [Int](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i * width + j] = a[i] == b[j]
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var result: [DiffLine] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result.append(.same(a[i]))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                result.append(.removed(a[i]))
                i += 1
            } else {
                result.append(.added(b[j]))
                j += 1
            }
        }
        result += a[i...].map(DiffLine.removed)
        result += b[j...].map(DiffLine.added)
        return result
    }
}
