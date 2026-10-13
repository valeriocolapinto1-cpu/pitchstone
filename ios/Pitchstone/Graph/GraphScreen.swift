import PitchstoneGraph
import PitchstoneSync
import SpriteKit
import SwiftUI

/// Il grafo con ricerca e filtri. Il layout si calcola in background e solo quando
/// cambia la struttura (nodi, aree, archi); un titolo modificato non lo rimescola.
struct GraphScreen: View {
    @Environment(NotesModel.self) private var notes
    let state: GraphState
    let onOpen: (UUID, Bool) -> Void

    var body: some View {
        let graph = state.graph
        ZStack(alignment: .top) {
            SpriteView(scene: state.scene, preferredFramesPerSecond: 120, options: [.ignoresSiblingOrder])
                .ignoresSafeArea()
                .accessibilityLabel(Text("Grafo dei nodi"))
            controls(graph: graph, matches: state.matches)
        }
        .overlay {
            if graph.isEmpty, !state.computing {
                ContentUnavailableView {
                    Label("Il grafo è vuoto", systemImage: "circle.hexagongrid")
                } description: {
                    Text("Crea qualche nodo e collegalo con [[titolo]] o con la Pencil.")
                }
            }
        }
        .onAppear {
            state.scene.onOpen = onOpen
            state.scene.onLink = { a, b in notes.connect(a, b) }
            state.refresh(from: notes)
        }
        .onChange(of: notes.revision) {
            state.refresh(from: notes)
        }
    }

    // MARK: Ricerca e filtri

    private func controls(graph: GraphData, matches: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca nel grafo", text: Binding(get: { state.filter.query }, set: { state.filter.query = $0 }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { state.focusFirstMatch() }
                if state.filter.isActive {
                    Text("\(matches.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button {
                        state.filter = GraphFilter()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel(Text("Azzera la ricerca"))
                }
                if state.computing { ProgressView() }
                Button {
                    state.scene.fitAll()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel(Text("Mostra tutto il grafo"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AreaLayout.order, id: \.self) { area in
                        chip(area.graphName, color: Color(area.graphColor), on: state.filter.areas.contains(area)) {
                            toggle(area, in: \.areas)
                        }
                    }
                    Divider().frame(height: 20)
                    ForEach(NodeType.allCases, id: \.self) { type in
                        chip(type.graphName, color: .secondary, on: state.filter.types.contains(type)) {
                            toggle(type, in: \.types)
                        }
                    }
                }
            }
            if state.filter.isActive, !state.filter.query.isEmpty, !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches.prefix(6), id: \.self) { i in
                        let node = graph.nodes[i]
                        HStack {
                            // Tocco sul titolo: il grafo si centra sul nodo.
                            Button {
                                state.scene.focus(on: node.id)
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
        if state.filter[keyPath: keyPath].contains(value) {
            state.filter[keyPath: keyPath].remove(value)
        } else {
            state.filter[keyPath: keyPath].insert(value)
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
