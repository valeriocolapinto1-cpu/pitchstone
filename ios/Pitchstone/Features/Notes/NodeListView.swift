import PitchstoneNotes
import PitchstoneSync
import SwiftUI

/// Nodi raggruppati per area, con ricerca e creazione.
struct NodeListView: View {
    @Environment(NotesModel.self) private var notes
    @Binding var selection: UUID?
    @State private var query = ""

    var body: some View {
        List(selection: $selection) {
            ForEach(Area.allCases, id: \.self) { area in
                let nodes = filtered.filter { $0.area == area }
                if !nodes.isEmpty {
                    Section(area.label) {
                        ForEach(nodes) { node in
                            NodeRow(node: node, hit: textHits[node.id])
                                .tag(node.id)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        if selection == node.id { selection = nil }
                                        notes.trash(node.id)
                                    } label: {
                                        Label("Cestino", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
        }
        .overlay {
            if notes.activeNodes.isEmpty {
                ContentUnavailableView {
                    Label("Ancora nessun nodo", systemImage: "circle.hexagongrid")
                } description: {
                    Text("Crea il primo nodo con il pulsante +.")
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: Text("Cerca nei nodi"))
        .navigationTitle("Pitchstone")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(NodeType.allCases, id: \.self) { type in
                        Button {
                            create(type)
                        } label: {
                            Label(type.label, systemImage: type.symbol)
                        }
                    }
                } label: {
                    Label("Nuovo nodo", systemImage: "plus")
                } primaryAction: {
                    create(.concept)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private var filtered: [NodeRecord] {
        let nodes = notes.activeNodes.sorted { $0.updatedAt > $1.updatedAt }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nodes }
        let hits = textHits
        return nodes.filter {
            $0.title.localizedStandardContains(q) || $0.bodyMD.localizedStandardContains(q)
                || $0.tags.contains { $0.localizedStandardContains(q) } || hits[$0.id] != nil
        }
    }

    /// Risultati nel testo di PDF, foto e scrittura a mano.
    private var textHits: [UUID: TextHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? [:] : notes.textMatches(q)
    }

    private func create(_ type: NodeType) {
        let area: Area = type == .health ? .salute : (type == .person ? .persone : .studio)
        selection = notes.createNode(type: type, area: area).id
    }
}

private struct NodeRow: View {
    let node: NodeRecord
    var hit: TextHit?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.type.symbol)
                .foregroundStyle(node.isSensitive ? AnyShapeStyle(.pink) : AnyShapeStyle(.tint))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title.isEmpty ? String(localized: "Senza titolo") : node.title)
                    .lineLimit(1)
                    .foregroundStyle(node.title.isEmpty ? .secondary : .primary)
                if let hit {
                    Label {
                        Text(hit.snippet).lineLimit(2)
                    } icon: {
                        Image(systemName: hit.source == .handwriting ? "pencil.and.scribble" : hit.source == .image ? "photo" : "doc.richtext")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let preview = node.preview {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if node.isSensitive {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Solo su questo iPad"))
            }
        }
    }
}

extension NodeRecord {
    var isSensitive: Bool { Privacy.isSensitive(self) }

    /// Prima riga di testo del corpo, senza sintassi Markdown di inizio riga.
    var preview: String? {
        bodyMD.split(separator: "\n")
            .lazy
            .map(Self.stripLinePrefix)
            .first { !$0.isEmpty }
    }

    private static func stripLinePrefix(_ line: Substring) -> String {
        var rest = line.drop { "#> \t".contains($0) }
        for marker in ["- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "+ "] where rest.hasPrefix(marker) {
            rest = rest.dropFirst(marker.count)
            break
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }.count
        if digits > 0, rest.dropFirst(digits).hasPrefix(". ") { rest = rest.dropFirst(digits + 2) }
        return rest.trimmingCharacters(in: .whitespaces)
    }
}

extension NodeType {
    var label: LocalizedStringKey {
        switch self {
        case .concept: "Concetto"
        case .idea: "Idea"
        case .project: "Progetto"
        case .exam: "Esame"
        case .person: "Persona"
        case .health: "Salute"
        }
    }

    var symbol: String {
        switch self {
        case .concept: "lightbulb"
        case .idea: "sparkles"
        case .project: "folder"
        case .exam: "graduationcap"
        case .person: "person"
        case .health: "heart.text.square"
        }
    }
}

extension Area {
    var label: LocalizedStringKey {
        switch self {
        case .studio: "Studio"
        case .progetti: "Progetti"
        case .lavoro: "Lavoro e clienti"
        case .persone: "Persone"
        case .interessi: "Interessi"
        case .salute: "Salute e allenamento"
        }
    }
}
