import PitchstoneGraph
import PitchstoneSync
import SpriteKit
import SwiftUI
import UIKit

/// Il grafo con ricerca e filtri. Il layout si calcola in background e solo quando
/// cambia la struttura (nodi, aree, archi); un titolo modificato non lo rimescola.
struct GraphScreen: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    let state: GraphState
    let onOpen: (UUID, Bool) -> Void
    @FocusState private var searchFocused: Bool
    @State private var showingList = false
    /// Nodo scelto nell'elenco: si apre quando l'elenco è chiuso, perché un foglio non ne apre un altro.
    @State private var pendingOpen: UUID?

    var body: some View {
        let graph = state.graph
        ZStack(alignment: .top) {
            // La tela non ha elementi per VoiceOver: il grafo si esplora con l'elenco dei nodi.
            SpriteView(scene: state.scene, preferredFramesPerSecond: 120, options: [.ignoresSiblingOrder])
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityLabel(Text("Grafo dei nodi"))
                .accessibilityValue(Text("\(graph.nodes.count) nodi, \(graph.edges.count) collegamenti"))
                .accessibilityHint(Text("Apri l'elenco dei nodi per esplorarli uno per uno."))
                .accessibilityAction(named: Text("Elenco dei nodi")) { showingList = true }
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
            state.scene.applyAppearance(traits)
            state.refresh(from: notes)
        }
        .onChange(of: notes.revision) {
            state.refresh(from: notes)
        }
        // Tema scuro, contrasto elevato e testo più grande valgono anche dentro la scena.
        .onChange(of: colorScheme) { state.scene.applyAppearance(traits) }
        .onChange(of: contrast) { state.scene.applyAppearance(traits) }
        .onChange(of: typeSize) { state.scene.applyAppearance(traits) }
        .onChange(of: state.searchFocusRequest) { searchFocused = true }
        .sheet(isPresented: $showingList, onDismiss: {
            if let id = pendingOpen {
                pendingOpen = nil
                onOpen(id, false)
            }
        }) {
            GraphListView(graph: graph, matches: state.filter.isActive ? state.matches : nil) { id in
                state.scene.focus(on: id)
            } onOpen: { id in
                pendingOpen = id
                showingList = false
            }
        }
    }

    private var traits: UITraitCollection {
        UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light),
            UITraitCollection(accessibilityContrast: contrast == .increased ? .high : .normal),
            UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize)),
        ])
    }

    // MARK: Ricerca e filtri

    private func controls(graph: GraphData, matches: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Cerca nel grafo", text: Binding(get: { state.filter.query }, set: { state.filter.query = $0 }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
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
                Button {
                    showingList = true
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel(Text("Elenco dei nodi"))
                .disabled(graph.isEmpty)
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
                                        .accessibilityHidden(true)
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
                // Con il contrasto elevato i filtri spenti hanno comunque un bordo visibile.
                .background(on ? AnyShapeStyle(color.opacity(highContrast ? 0.4 : 0.25)) : AnyShapeStyle(.quaternary.opacity(0.4)), in: Capsule())
                .overlay(Capsule().strokeBorder(on ? color : (highContrast ? .secondary : .clear), lineWidth: highContrast ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var highContrast: Bool { contrast == .increased }

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
