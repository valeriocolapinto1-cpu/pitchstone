import Foundation
import PitchstoneGraph
import PitchstoneStore
import PitchstoneSync
import SpriteKit
import Testing
@testable import Pitchstone

@MainActor
@Suite("Grafo nell'app", .serialized)
struct AppGraphTests {
    let model: NotesModel

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "graph-\(UUID().uuidString)"))
        model = NotesModel(container: try PitchstoneSchema.container(inMemory: true), defaults: defaults, startSync: false)
    }

    @Test("un [[link]] nel testo diventa un arco, e sparisce quando si toglie")
    func wikiLinksBecomeEdges() {
        let a = model.createNode(title: "Derivata")
        let b = model.createNode(title: "Integrale")
        model.update(a.id) { $0.bodyMD = "Inversa: [[integrale]] e [[Inesistente]]." }
        let links = { model.edges.filter { $0.kind == .link && $0.deletedAt == nil } }
        #expect(links().map(\.targetID) == [b.id])
        model.update(a.id) { $0.bodyMD = "Nessun link." }
        #expect(links().isEmpty)
    }

    @Test("un link a un nodo nuovo crea nodo e arco")
    func linkToNewNode() {
        let a = model.createNode(title: "Serie")
        model.update(a.id) { $0.bodyMD = "Vedi [[Taylor]]" }
        let created = model.openOrCreate(titled: "Taylor", area: .studio, from: a.id)
        #expect(model.edges.contains { $0.sourceID == a.id && $0.targetID == created && $0.deletedAt == nil })
    }

    @Test("collegamento con la Pencil: niente doppioni, niente archi verso sé stesso")
    func connect() {
        let a = model.createNode(title: "A")
        let b = model.createNode(title: "B")
        model.connect(a.id, b.id)
        model.connect(b.id, a.id)
        model.connect(a.id, a.id)
        #expect(model.edges.filter { $0.deletedAt == nil }.count == 1)
        #expect(model.edges.first?.kind == .manual)
    }

    @Test("la scena carica 3000 nodi in tempi da interfaccia e regge zoom e ricerca")
    func scenePerformance() {
        let date = Date()
        let nodes = (0..<3000).map { i in
            NodeRecord(type: i % 50 == 0 ? .health : .concept, title: "Nodo \(i)",
                       area: AreaLayout.order[i % AreaLayout.order.count], createdAt: date, updatedAt: date, deviceID: "t")
        }
        let edges = (0..<6000).map { i in
            EdgeRecord(sourceID: nodes[i % 3000].id, targetID: nodes[(i * 7 + 13) % 3000].id, kind: .link, createdAt: date)
        }
        let graph = GraphData(nodes: nodes, edges: edges)
        var config = GraphLayout.Config()
        config.iterations = 60
        let positions = GraphLayout(config: config).positions(for: graph)

        let scene = GraphScene(size: CGSize(width: 1180, height: 820))
        let clock = ContinuousClock()
        let elapsed = clock.measure { scene.show(graph, positions: positions) }
        #expect(elapsed < .seconds(2), "show in \(elapsed)")
        #expect(scene.graphCamera.detail != .labels, "all'inizio si vede tutto il grafo")

        scene.highlight(GraphFilter(query: "Nodo 12").matches(in: graph))
        scene.focus(on: nodes[12].id)
        #expect(scene.graphCamera.detail == .labels)
        scene.highlight(nil)
        scene.fitAll()
        #expect(scene.graphCamera.detail != .labels)
    }
}
