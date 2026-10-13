import Foundation
import Observation
import PitchstoneGraph
import PitchstoneSync

/// Stato del grafo che sopravvive al passaggio elenco ↔ grafo: scena, posizioni,
/// ricerca e calcolo del layout. Vive nella finestra principale (RootView).
@MainActor
@Observable
final class GraphState {
    @ObservationIgnored let scene = GraphScene(size: CGSize(width: 1024, height: 768))
    private(set) var computing = false
    private(set) var matches: [Int] = []
    private var storedFilter = GraphFilter()
    var filter: GraphFilter {
        get { storedFilter }
        set {
            guard newValue != storedFilter else { return }
            storedFilter = newValue
            applyFilter()
        }
    }

    @ObservationIgnored private var positions: [UUID: CGPoint] = [:]
    @ObservationIgnored private var layoutTask: Task<Void, Never>?
    @ObservationIgnored private var laidOutKey: Int?
    @ObservationIgnored private var cachedRevision = -1
    private(set) var graph = GraphData(nodes: [], edges: [])

    /// Dati del grafo ricostruiti una sola volta per modifica dell'archivio.
    func refresh(from notes: NotesModel) {
        guard notes.revision != cachedRevision else { return }
        cachedRevision = notes.revision
        graph = GraphData(nodes: notes.nodes, edges: notes.edges)
        if graph.structureKey != laidOutKey {
            relayout()
        } else {
            // Stessa struttura (per esempio un testo salvato): stesse posizioni, dati nuovi.
            showCurrent()
        }
    }

    func focusFirstMatch() {
        if let first = matches.first { scene.focus(on: graph.nodes[first].id) }
    }

    private func relayout() {
        layoutTask?.cancel()
        let graph = self.graph
        let previous = positions
        let config: GraphLayout.Config = previous.isEmpty ? GraphLayout.Config() : .incremental
        computing = true
        layoutTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                GraphLayout(config: config).positions(for: graph, previous: previous, shouldStop: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            // Superato da un calcolo più recente: quello aggiornerà la scena.
            guard let self, !Task.isCancelled, result.count == graph.nodes.count else { return }
            var byID: [UUID: CGPoint] = [:]
            for (i, node) in graph.nodes.enumerated() { byID[node.id] = result[i] }
            positions = byID
            laidOutKey = graph.structureKey
            computing = false
            showCurrent()
        }
    }

    private func showCurrent() {
        let ordered = graph.nodes.compactMap { positions[$0.id] }
        guard ordered.count == graph.nodes.count else { return }
        scene.show(graph, positions: ordered)
        applyFilter()
    }

    private func applyFilter() {
        matches = filter.isActive ? filter.matches(in: graph) : []
        scene.highlight(filter.isActive ? matches : nil)
    }
}
