import PitchstoneGraph
import PitchstoneSync
import SwiftUI

/// Il grafo come elenco: per VoiceOver, Controllo interruttori e tastiera, dove la tela
/// SpriteKit non ha elementi. Ogni nodo dice area, tipo e a chi è collegato.
struct GraphListView: View {
    let graph: GraphData
    /// Risultati della ricerca del grafo; nil mostra tutti i nodi.
    let matches: [Int]?
    let onFocus: (UUID) -> Void
    let onOpen: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let neighbors = graph.neighbors()
        let visible = matches ?? Array(graph.nodes.indices)
        NavigationStack {
            List {
                ForEach(AreaLayout.order, id: \.self) { area in
                    let members = visible.filter { graph.nodes[$0].area == area }
                    if !members.isEmpty {
                        Section(area.graphName) {
                            ForEach(members, id: \.self) { i in
                                row(i, neighbors: neighbors[i])
                            }
                        }
                    }
                }
            }
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView("Nessun nodo", systemImage: "circle.hexagongrid")
                }
            }
            .navigationTitle(matches == nil ? Text("Nodi del grafo") : Text("Risultati della ricerca"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }

    private func row(_ i: Int, neighbors: [Int]) -> some View {
        let node = graph.nodes[i]
        let names = neighbors.prefix(5).map { Self.title(graph.nodes[$0]) }
        return Button {
            onOpen(node.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title(node))
                    .foregroundStyle(.primary)
                Text("\(node.type.graphName) · \(node.degree) collegamenti")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !names.isEmpty {
                    Text(names.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityLabel(Text(Self.title(node)))
        .accessibilityValue(Text("\(node.type.graphName), \(node.degree) collegamenti"))
        .accessibilityHint(names.isEmpty ? Text("Apre il nodo") : Text("Collegato a \(names.joined(separator: ", ")). Apre il nodo"))
        .accessibilityAction(named: Text("Mostra nel grafo")) {
            onFocus(node.id)
            dismiss()
        }
    }

    private static func title(_ node: GraphData.Node) -> String {
        node.title.isEmpty ? String(localized: "Senza titolo") : node.title
    }
}
