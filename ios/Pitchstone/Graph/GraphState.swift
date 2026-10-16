import Foundation
import Observation
import PitchstoneGraph
import PitchstoneStudy
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
    /// Elenco accessibile dei nodi aperto: RootView lo conta tra i fogli aperti, così le
    /// scorciatoie globali non provano a presentare un altro foglio sopra.
    var showingList = false
    /// Cresce a ogni ⌘F con il grafo aperto: GraphScreen porta il cursore nella ricerca.
    private(set) var searchFocusRequest = 0

    func requestSearchFocus() {
        searchFocusRequest += 1
    }

    /// Dati del grafo ricostruiti una sola volta per modifica dell'archivio.
    func refresh(from notes: NotesModel) {
        guard notes.revision != cachedRevision else { return }
        cachedRevision = notes.revision
        // Il testo di PDF, foto e scrittura a mano è ricercabile anche nel grafo.
        let extracted = notes.extractedTextByNode()
        let nodes = notes.nodes.map { node in
            var copy = node
            if let text = extracted[node.id] { copy.bodyMD += "\n" + text }
            // Gli esami mostrano la data nel grafo.
            if node.type == .exam, let day = ExamInfo.parse(node.tags).date, let d = day.day, let m = day.month {
                copy.title += " · \(d)/\(m)"
            }
            return copy
        }
        graph = GraphData(nodes: nodes, edges: notes.edges)
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
