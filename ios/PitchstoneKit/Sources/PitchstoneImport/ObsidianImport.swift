import Foundation
import PitchstoneSync

/// Una nota del vault: percorso relativo con `/` e testo.
public struct VaultFile: Sendable, Equatable {
    public var path: String
    public var text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

/// Il contenuto letto da una cartella: note Markdown, altri file, file scartati.
public struct VaultContents: Sendable, Equatable {
    public var notes: [VaultFile]
    /// File che non sono note (PDF, immagini...): per ora non vengono importati.
    public var otherFiles: [String]
    public var skipped: [VaultImportPlan.Skipped]

    public init(notes: [VaultFile], otherFiles: [String] = [], skipped: [VaultImportPlan.Skipped] = []) {
        self.notes = notes
        self.otherFiles = otherFiles
        self.skipped = skipped
    }
}

/// Cosa verrà creato importando un vault, prima di toccare l'archivio.
public struct VaultImportPlan: Sendable, Equatable {
    public struct Note: Sendable, Equatable {
        public var path: String
        public var title: String
        public var body: String
        public var area: Area
        public var type: NodeType
        public var tags: [String]
        /// Titoli collegati con `[[...]]`, già risolti: note del vault o nodi esistenti.
        public var links: [String]
    }

    public struct Skipped: Sendable, Equatable {
        public enum Reason: Sendable, Equatable {
            /// Un nodo con questo titolo c'è già: non si duplica, i link puntano a quello.
            case alreadyExists(title: String)
            case tooLarge
            case notText
            /// File non leggibile (permessi, errore del disco...).
            case unreadable
            /// Nota di iCloud non ancora scaricata sull'iPad.
            case notDownloaded
        }

        public var path: String
        public var reason: Reason

        public init(path: String, reason: Reason) {
            self.path = path
            self.reason = reason
        }
    }

    public var notes: [Note]
    public var skipped: [Skipped]
    /// Link verso note che non esistono né nel vault né nell'app: restano `[[...]]`
    /// e il nodo si crea toccandoli, come per un link scritto a mano.
    public var unresolvedLinks: [String]
    /// File non Markdown del vault, non importati in questa versione.
    public var otherFiles: [String]

    public var linkCount: Int { notes.reduce(0) { $0 + $1.links.count } }
}

/// Traduce un vault Obsidian in nodi: titolo dal nome del file, proprietà YAML,
/// tag, alias e link `[[cartella/Nota#Sezione|testo]]` riscritti come `[[Titolo|testo]]`.
public enum ObsidianImport {
    public static func plan(_ contents: VaultContents, defaultArea: Area, existingTitles: [String]) -> VaultImportPlan {
        var existing: [String: String] = [:]
        for title in existingTitles where !title.isEmpty {
            existing[NodeTitle.key(title)] = existing[NodeTitle.key(title)] ?? title
        }

        // Ordine stabile: prima le note meno annidate, come fa Obsidian per i nomi uguali.
        let files = contents.notes.sorted { ($0.depth, $0.path) < ($1.depth, $1.path) }
        let parsed = files.map { file -> Parsed in
            let text = file.text.replacingOccurrences(of: "\r\n", with: "\n")
            let (front, body) = Frontmatter.split(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
            return Parsed(file: file, front: front, body: body)
        }

        // Titoli: il nome del file; i doppioni nel vault prendono la cartella tra parentesi.
        // Se il titolo c'è già nell'app la nota non si crea (reimportare non duplica).
        var used = Set<String>()
        var titles: [String] = []
        var existingMatch: [String?] = []
        for item in parsed {
            let name = item.file.name
            var title = name
            if used.contains(NodeTitle.key(title)) {
                let folder = item.file.folders.last ?? "vault"
                title = "\(name) (\(folder))"
                var n = 2
                while used.contains(NodeTitle.key(title)) {
                    title = "\(name) (\(folder)) \(n)"
                    n += 1
                }
            }
            used.insert(NodeTitle.key(title))
            let match = existing[NodeTitle.key(title)]
            titles.append(match ?? title)
            existingMatch.append(match)
        }

        let resolver = Resolver(parsed: parsed, titles: titles, existing: existing)
        var notes: [VaultImportPlan.Note] = []
        var skipped = contents.skipped
        var unresolved = Set<String>()

        for (i, item) in parsed.enumerated() {
            if let match = existingMatch[i] {
                skipped.append(.init(path: item.file.path, reason: .alreadyExists(title: match)))
                continue
            }
            var links: [String] = []
            let folder = item.file.folders.joined(separator: "/")
            var body = MarkdownScan.transformText(item.body) { text in
                rewriteLinks(text, from: folder, resolver: resolver, links: &links, unresolved: &unresolved)
            }
            var tags: [String] = []
            for tag in item.front.strings("tags", "tag").flatMap(splitTags) + inlineTags(item.body) {
                let clean = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
                if !clean.isEmpty, !tags.contains(where: { NodeTitle.key($0) == NodeTitle.key(clean) }) { tags.append(clean) }
            }
            let declaredArea = item.front.strings("area").lazy.compactMap(area(named:)).first
            let declaredType = item.front.strings("type", "tipo").lazy.compactMap(nodeType).first
            // Restano nella nota le proprietà che l'app non ha assorbito: alias, date,
            // aree e tipi sconosciuti...
            var absorbed: Set<String> = ["tags", "tag"]
            if declaredArea != nil { absorbed.insert("area") }
            if declaredType != nil { absorbed.formUnion(["type", "tipo"]) }
            let kept = item.front.lines(excluding: absorbed)
            if !kept.isEmpty {
                // Il recinto è più lungo di qualsiasi sequenza di backtick nelle proprietà.
                let fence = String(repeating: "`", count: max(3, longestBacktickRun(kept) + 1))
                body += (body.isEmpty ? "" : "\n\n") + fence + "yaml\n" + kept.joined(separator: "\n") + "\n" + fence + "\n"
            }
            notes.append(.init(
                path: item.file.path, title: titles[i], body: body,
                area: isHealth(item, tags: tags) ? .salute : declaredArea ?? folderArea(item) ?? defaultArea,
                type: declaredType ?? .concept,
                tags: tags, links: links))
        }

        return VaultImportPlan(
            notes: notes, skipped: skipped,
            unresolvedLinks: unresolved.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            otherFiles: contents.otherFiles.sorted())
    }

    // MARK: Link

    private static func rewriteLinks(_ text: String, from folder: String, resolver: Resolver, links: inout [String], unresolved: inout Set<String>) -> String {
        guard text.contains("[[") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            let inner = rest[open.upperBound..<close.lowerBound]
            var prefix = rest[..<open.lowerBound]
            let embed = prefix.hasSuffix("!")
            guard !inner.isEmpty, !inner.contains("["), !inner.contains("]") else {
                result += rest[..<close.upperBound]
                rest = rest[close.upperBound...]
                continue
            }
            // Nelle tabelle Obsidian scrive `\|` per non spezzare la cella.
            let escapedPipe = inner.contains("\\|")
            let separator = escapedPipe ? "\\|" : "|"
            let parts = inner.components(separatedBy: separator)
            let alias = parts.count > 1 ? parts[1...].joined(separator: separator).trimmingCharacters(in: .whitespaces) : nil
            let target = parts[0].trimmingCharacters(in: .whitespaces)
            // Un titolo può contenere # (`C#`): prima si prova il bersaglio intero.
            let whole = resolver.resolve(target, from: folder)
            let (page, section) = whole != nil ? (target, nil) : splitSection(target)
            let resolved = whole ?? (page.isEmpty ? nil : resolver.resolve(page, from: folder))

            if embed, resolved == nil, isAttachment(page) {
                // Allegati (PDF, immagini): il testo resta com'è finché non si importano anche loro.
                result += rest[..<close.upperBound]
                rest = rest[close.upperBound...]
                continue
            }
            if embed { prefix = prefix.dropLast() }
            result += prefix

            if page.isEmpty {
                // Link a una sezione della stessa nota: resta il testo.
                result += alias ?? section ?? ""
            } else if let title = resolved {
                if !links.contains(where: { NodeTitle.key($0) == NodeTitle.key(title) }) { links.append(title) }
                let label = alias ?? section.map { "\(displayName(page)) > \($0)" }
                    ?? (NodeTitle.key(displayName(page)) == NodeTitle.key(title) ? nil : displayName(page))
                result += label.map { "[[\(title)\(separator)\($0)]]" } ?? "[[\(title)]]"
            } else {
                unresolved.insert(displayName(page))
                let label = alias ?? section.map { "\(displayName(page)) > \($0)" }
                result += label.map { "[[\(displayName(page))\(separator)\($0)]]" } ?? "[[\(displayName(page))]]"
            }
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    /// `Nota#Sezione` o `Nota#^blocco`.
    private static func splitSection(_ target: String) -> (page: String, section: String?) {
        guard let hash = target.firstIndex(of: "#") else { return (target, nil) }
        let section = target[target.index(after: hash)...].trimmingCharacters(in: .whitespaces)
        return (target[..<hash].trimmingCharacters(in: .whitespaces), section.isEmpty ? nil : section)
    }

    /// Il nome della nota senza cartelle e senza `.md`.
    private static func displayName(_ page: String) -> String {
        let name = page.split(separator: "/").last.map(String.init) ?? page
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    private static func isAttachment(_ page: String) -> Bool {
        guard let dot = page.lastIndex(of: ".") else { return false }
        let ext = page[page.index(after: dot)...]
        return !ext.isEmpty && ext.count <= 5 && ext.allSatisfy { $0.isLetter || $0.isNumber } && ext.lowercased() != "md"
    }

    // MARK: Tag

    private static func splitTags(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0) }
    }

    /// `#tag` nel testo, fuori dal codice: preceduto da uno spazio o a inizio riga,
    /// con almeno un carattere che non sia una cifra (come in Obsidian).
    static func inlineTags(_ markdown: String) -> [String] {
        var tags: [String] = []
        _ = MarkdownScan.transformText(markdown) { text in
            let chars = Array(text)
            var i = 0
            while i < chars.count {
                defer { i += 1 }
                guard chars[i] == "#", i == 0 || chars[i - 1].isWhitespace else { continue }
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || "_-/".contains(chars[j]) { j += 1 }
                let tag = String(chars[(i + 1)..<j])
                if tag.contains(where: { !$0.isNumber }) { tags.append(tag) }
                i = j - 1
            }
            return text
        }
        return tags
    }

    // MARK: Area e tipo

    /// Prudenza: una nota che sembra di salute resta sul dispositivo, qualunque area dichiari.
    /// Tag `salute` o `health`, anche annidati (`salute/visite`), o una cartella Salute a
    /// qualsiasi livello.
    private static func isHealth(_ item: Parsed, tags: [String]) -> Bool {
        let healthTag = tags.contains { tag in
            let key = NodeTitle.key(tag)
            return ["salute", "health"].contains { key == $0 || key.hasPrefix($0 + "/") }
        }
        let typeIsHealth = item.front.strings("type", "tipo").contains { nodeType($0) == .health }
        return healthTag || typeIsHealth || item.file.folders.contains { area(named: $0) == .salute }
    }

    /// La prima cartella, se ha il nome di un'area.
    private static func folderArea(_ item: Parsed) -> Area? {
        item.file.folders.first.flatMap(area(named:))
    }

    private static func longestBacktickRun(_ lines: [String]) -> Int {
        var longest = 0
        for line in lines {
            var run = 0
            for char in line {
                run = char == "`" ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return longest
    }

    private static func area(named name: String) -> Area? {
        let key = NodeTitle.key(name)
        if let area = Area(rawValue: key) { return area }
        let english: [String: Area] = [
            "study": .studio, "projects": .progetti, "project": .progetti, "work": .lavoro,
            "people": .persone, "interests": .interessi, "health": .salute,
        ]
        return english[key]
    }

    private static func nodeType(_ name: String) -> NodeType? {
        let key = NodeTitle.key(name)
        if let type = NodeType(rawValue: key) { return type }
        let italian: [String: NodeType] = [
            "concetto": .concept, "concetti": .concept, "idee": .idea, "progetto": .project, "progetti": .project,
            "esame": .exam, "esami": .exam, "persona": .person, "persone": .person, "salute": .health,
        ]
        return italian[key]
    }
}

struct Parsed {
    var file: VaultFile
    var front: Frontmatter
    var body: String
}

/// Risolve il bersaglio di un link come Obsidian: percorso, poi nome del file
/// (prima nella stessa cartella, poi il meno annidato), poi alias; infine i nodi
/// già presenti nell'app.
struct Resolver {
    private var byPath: [String: String] = [:]
    private var byName: [String: [(folder: String, title: String)]] = [:]
    private var byAlias: [String: String] = [:]
    private var paths: [(key: String, title: String)] = []
    private let existing: [String: String]

    init(parsed: [Parsed], titles: [String], existing: [String: String]) {
        self.existing = existing
        for (item, title) in zip(parsed, titles) {
            let path = NodeTitle.key(item.file.pathWithoutExtension)
            byPath[path] = title
            paths.append((path, title))
            byName[NodeTitle.key(item.file.name), default: []].append((NodeTitle.key(item.file.folders.joined(separator: "/")), title))
            for alias in item.front.strings("aliases", "alias") {
                byAlias[NodeTitle.key(alias)] = byAlias[NodeTitle.key(alias)] ?? title
            }
        }
    }

    func resolve(_ page: String, from folder: String) -> String? {
        var target = page.hasPrefix("/") ? String(page.dropFirst()) : page
        if target.lowercased().hasSuffix(".md") { target = String(target.dropLast(3)) }
        let key = NodeTitle.key(target)
        if target.contains("/") {
            if let title = byPath[key] { return title }
            return paths.first { $0.key.hasSuffix("/" + key) }?.title
        }
        if let candidates = byName[key] {
            // Le note sono già in ordine di profondità.
            return (candidates.first { $0.folder == NodeTitle.key(folder) } ?? candidates[0]).title
        }
        return byAlias[key] ?? existing[key]
    }
}

extension VaultFile {
    var components: [String] { path.split(separator: "/").map(String.init) }
    var folders: [String] { Array(components.dropLast()) }
    var depth: Int { components.count }
    var name: String {
        let file = components.last ?? path
        return file.lowercased().hasSuffix(".md") ? String(file.dropLast(3)) : file
    }
    var pathWithoutExtension: String { path.lowercased().hasSuffix(".md") ? String(path.dropLast(3)) : path }
}
