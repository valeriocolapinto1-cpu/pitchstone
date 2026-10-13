import PitchstoneGraph
import PitchstoneSync
import SpriteKit
import SwiftUI

/// Il grafo con ricerca e filtri. Il layout si calcola in background e solo quando
/// cambia la struttura (nodi, aree, archi); un titolo modificato non lo rimescola.
struct GraphScreen: View {
    @Environment(NotesModel.self) private var notes
    let onOpen: (UUID, Bool) -> Void

    @State private var scene = GraphScene(size: CGSize(width: 1024, height: 768))
    @State private var positions: [UUID: CGPoint] = [:]
    @State private var filter = GraphFilter()
    @State private var computing = false

    var body: some View {
        let graph = GraphData(nodes: notes.nodes, edges: notes.edges)
        let matches = filter.isActive ? filter.matches(in: graph) : []
        ZStack(alignment: .top) {
            SpriteView(scene: scene, preferredFramesPerSecond: 120, options: [.ignoresSiblingOrder])
                .ignoresSafeArea()
                .accessibilityLabel(Text("Grafo dei nodi"))
            controls(graph: graph, matches: matches)
        }
        .overlay {
            if graph.isEmpty {
                ContentUnavailableView {
                    Label("Il grafo è vuoto", systemImage: "circle.hexagongrid")
                } description: {
                    Text("Crea qualche nodo e collegalo con [[titolo]] o con la Pencil.")
                }
            }
        }
        .onAppear {
            scene.onOpen = onOpen
            scene.onLink = { a, b in notes.connect(a, b) }
        }
        .task(id: graph.structureKey) { await relayout(graph) }
        .onChange(of: graph) { _, updated in
            // Stessa struttura (per esempio un titolo cambiato): stesse posizioni, dati nuovi.
            showIfLaidOut(updated)
        }
        .onChange(of: filter) { _, updated in
            scene.highlight(updated.isActive ? updated.matches(in: graph) : nil)
        }
    }

    private func relayout(_ graph: GraphData) async {
        computing = true
        defer { computing = false }
        let previous = positions
        let config: GraphLayout.Config = previous.isEmpty ? GraphLayout.Config() : .incremental
        let result = await Task.detached(priority: .userInitiated) {
            GraphLayout(config: config).positions(for: graph, previous: previous)
        }.value
        guard !Task.isCancelled else { return }
        var byID: [UUID: CGPoint] = [:]
        for (i, node) in graph.nodes.enumerated() { byID[node.id] = result[i] }
        positions = byID
        scene.show(graph, positions: result)
        scene.highlight(filter.isActive ? filter.matches(in: graph) : nil)
    }

    private func showIfLaidOut(_ graph: GraphData) {
        let ordered = graph.nodes.compactMap { positions[$0.id] }
        guard ordered.count == graph.nodes.count else { return }
        scene.show(graph, positions: ordered)
        scene.highlight(filter.isActive ? filter.matches(in: graph) : nil)
    }

    // MARK: Ricerca e filtri

    private func controls(graph: GraphData, matches: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca nel grafo", text: $filter.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        if let first = matches.first { scene.focus(on: graph.nodes[first].id) }
                    }
                if filter.isActive {
                    Text("\(matches.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button {
                        filter = GraphFilter()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel(Text("Azzera la ricerca"))
                }
                if computing { ProgressView() }
                Button {
                    scene.fitAll()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel(Text("Mostra tutto il grafo"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AreaLayout.order, id: \.self) { area in
                        chip(area.graphName, color: Color(area.graphColor), on: filter.areas.contains(area)) {
                            toggle(area, in: \.areas)
                        }
                    }
                    Divider().frame(height: 20)
                    ForEach(NodeType.allCases, id: \.self) { type in
                        chip(type.graphName, color: .secondary, on: filter.types.contains(type)) {
                            toggle(type, in: \.types)
                        }
                    }
                }
            }
            if filter.isActive, !filter.query.isEmpty, !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches.prefix(6), id: \.self) { i in
                        let node = graph.nodes[i]
                        HStack {
                            // Tocco sul titolo: il grafo si centra sul nodo.
                            Button {
                                scene.focus(on: node.id)
                            } label: {
                                HStack {
                                    Circle().fill(Color(node.graphColor)).frame(width: 8, height: 8)
                                    Text(node.title.isEmpty ? String(localized: "Senza titolo") : node.title)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button("Apri") { onOpen(node.id, false) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 560)
        .padding()
    }

    private func chip(_ title: String, color: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(on ? AnyShapeStyle(color.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.4)), in: Capsule())
                .overlay(Capsule().strokeBorder(on ? color : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggle<T: Hashable>(_ value: T, in keyPath: WritableKeyPath<GraphFilter, Set<T>>) {
        if filter[keyPath: keyPath].contains(value) {
            filter[keyPath: keyPath].remove(value)
        } else {
            filter[keyPath: keyPath].insert(value)
        }
    }
}

extension NodeType {
    var graphName: String {
        switch self {
        case .concept: String(localized: "Concetti")
        case .idea: String(localized: "Idee")
        case .project: String(localized: "Progetti")
        case .exam: String(localized: "Esami")
        case .person: String(localized: "Persone")
        case .health: String(localized: "Salute")
        }
    }
}
