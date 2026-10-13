import Foundation
import PitchstoneSync

/// Legge un vault da una cartella: le note `.md`, l'elenco degli altri file.
/// Le cartelle nascoste (`.obsidian`, `.trash`, `.git`) restano fuori.
public enum VaultReader {
    /// Una nota più grande di così non è un appunto: probabilmente un export o un log.
    public static let maxNoteBytes = 2_000_000

    public static func read(at root: URL) throws -> VaultContents {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { throw CocoaError(.fileReadNoSuchFile) }

        var contents = VaultContents(notes: [])
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { continue }
            let path = parts.dropFirst(base.count).joined(separator: "/")

            guard url.pathExtension.lowercased() == "md" else {
                contents.otherFiles.append(path)
                continue
            }
            if (values.fileSize ?? 0) > maxNoteBytes {
                contents.skipped.append(.init(path: path, reason: .tooLarge))
                continue
            }
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
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

    public static func apply(_ plan: VaultImportPlan, to repository: Repository, store: SyncStore) -> Result {
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
        var links = 0
        for (id, note) in created {
            let targets = Set(note.links.compactMap { index[NodeTitle.key($0)] }).subtracting([id])
            repository.syncLinkEdges(from: id, to: targets)
            links += targets.count
        }
        return Result(created: created.map(\.0), links: links)
    }
}
