import Foundation
import PitchstoneSync

/// Legge un vault da una cartella: le note `.md`, l'elenco degli altri file.
/// Le cartelle nascoste (`.obsidian`, `.trash`, `.git`) restano fuori.
public enum VaultReader {
    /// Una nota più grande di così non è un appunto: probabilmente un export o un log.
    public static let maxNoteBytes = 2_000_000

    public static func read(at root: URL) throws -> VaultContents {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        // Senza .skipsHiddenFiles: le note di iCloud non scaricate sono file nascosti
        // (`.Nota.md.icloud`) e vanno segnalate, non ignorate in silenzio.
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants])
        else { throw CocoaError(.fileReadNoSuchFile) }

        var contents = VaultContents(notes: [])
        for case let url as URL in enumerator {
            let parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { continue }
            let relative = Array(parts.dropFirst(base.count))
            let path = relative.joined(separator: "/")
            let values = try? url.resourceValues(forKeys: Set(keys))

            if let name = relative.last, name.hasPrefix(".") {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                } else if name.lowercased().hasSuffix(".md.icloud") {
                    let original = (relative.dropLast() + [String(name.dropFirst().dropLast(".icloud".count))]).joined(separator: "/")
                    contents.skipped.append(.init(path: original, reason: .notDownloaded))
                }
                continue
            }
            guard let values else {
                contents.skipped.append(.init(path: path, reason: .unreadable))
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard url.pathExtension.lowercased() == "md" else {
                contents.otherFiles.append(path)
                continue
            }
            if (values.fileSize ?? 0) > maxNoteBytes {
                contents.skipped.append(.init(path: path, reason: .tooLarge))
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                contents.skipped.append(.init(path: path, reason: .unreadable))
                continue
            }
            guard let text = String(data: data, encoding: .utf8) else {
                contents.skipped.append(.init(path: path, reason: .notText))
                continue
            }
            contents.notes.append(VaultFile(path: path, text: text))
        }
        contents.notes.sort { $0.path < $1.path }
        return contents
    }
}

/// Crea nell'archivio i nodi e gli archi di un piano d'import.
@MainActor
public enum VaultImporter {
    public struct Result: Sendable, Equatable {
        public var created: [UUID]
        public var links: Int
    }

    /// I nodi nuovi non hanno archi: si creano direttamente, senza rileggere tutti gli
    /// archi dell'archivio per ogni nota. Tutto in un'unica transazione.
    public static func apply(_ plan: VaultImportPlan, to repository: Repository, store: SyncStore) -> Result {
        var result = Result(created: [], links: 0)
        store.performBatch {
            var index: [String: UUID] = [:]
            for node in store.allNodes() where node.deletedAt == nil && !node.title.isEmpty {
                index[NodeTitle.key(node.title)] = index[NodeTitle.key(node.title)] ?? node.id
            }
            var created: [(UUID, VaultImportPlan.Note)] = []
            for note in plan.notes {
                let node = repository.createNode(type: note.type, title: note.title, body: note.body, area: note.area, tags: note.tags)
                index[NodeTitle.key(note.title)] = node.id
                created.append((node.id, note))
            }
            // Gli archi dopo tutti i nodi: un link può puntare a una nota che viene dopo.
            for (id, note) in created {
                var targets = Set<UUID>()
                for title in note.links {
                    guard let target = index[NodeTitle.key(title)], target != id, targets.insert(target).inserted else { continue }
                    if (try? repository.createEdge(from: id, to: target, kind: .link)) != nil { result.links += 1 }
                }
            }
            result.created = created.map(\.0)
        }
        return result
    }
}
