import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import PitchstoneGraph
@testable import PitchstoneSync

/// Grafo di esempio: `count` nodi distribuiti sulle aree, archi soprattutto dentro l'area.
func sampleGraph(count: Int, edgesPerNode: Int = 2, seed: UInt64 = 42) -> (GraphData, [NodeRecord], [EdgeRecord]) {
    var rng = SplitMix(seed: seed)
    let date = Date(timeIntervalSince1970: 0)
    let areas = AreaLayout.order
    let nodes: [NodeRecord] = (0..<count).map { i in
        let area = areas[i % areas.count]
        return NodeRecord(id: UUID(uuid: rng.uuid()), type: area == .salute ? .health : .concept,
                          title: "Nodo \(i)", bodyMD: i % 10 == 0 ? "derivata e integrale" : "testo",
                          area: area, tags: i % 3 == 0 ? ["analisi"] : [], createdAt: date, updatedAt: date, deviceID: "t")
    }
    var edges: [EdgeRecord] = []
    for i in 0..<count {
        for _ in 0..<edgesPerNode {
            // 90% dentro la stessa area, 10% tra aree.
            let sameArea = rng.next() % 10 != 0
            var j = Int(rng.next() % UInt64(count))
            if sameArea { j = j - j % areas.count + i % areas.count; if j >= count { j -= areas.count } }
            guard j >= 0, j != i else { continue }
            edges.append(EdgeRecord(id: UUID(uuid: rng.uuid()), sourceID: nodes[i].id, targetID: nodes[j].id,
                                    kind: .link, createdAt: date))
        }
    }
    return (GraphData(nodes: nodes, edges: edges), nodes, edges)
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uuid() -> uuid_t {
        let a = next(), b = next()
        return withUnsafeBytes(of: (a, b)) { raw in
            let p = raw.bindMemory(to: UInt8.self)
            return (p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9], p[10], p[11], p[12], p[13], p[14], p[15])
        }
    }
}

func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    Double(((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot())
}

@Suite("Layout del grafo")
struct GraphLayoutTests {
    @Test("i nodi si raggruppano per area")
    func clustersByArea() {
        let (graph, _, _) = sampleGraph(count: 600)
        let positions = GraphLayout().positions(for: graph)
        var centroid: [Area: (Double, Double, Int)] = [:]
        for (i, node) in graph.nodes.enumerated() {
            let c = centroid[node.area] ?? (0, 0, 0)
            centroid[node.area] = (c.0 + Double(positions[i].x), c.1 + Double(positions[i].y), c.2 + 1)
        }
        let centers = centroid.mapValues { CGPoint(x: $0.0 / Double($0.2), y: $0.1 / Double($0.2)) }
        // Ogni nodo è più vicino al centro della sua area che a quello delle altre (quasi sempre).
        var correct = 0
        for (i, node) in graph.nodes.enumerated() {
            let nearest = centers.min { distance(positions[i], $0.value) < distance(positions[i], $1.value) }!.key
            if nearest == node.area { correct += 1 }
        }
        #expect(Double(correct) / Double(graph.nodes.count) > 0.9)
    }

    @Test("nessuna posizione non valida e nodi non sovrapposti")
    func validPositions() {
        let (graph, _, _) = sampleGraph(count: 400)
        let positions = GraphLayout().positions(for: graph)
        #expect(positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let index = SpatialIndex(positions: positions)
        // Pochi nodi praticamente coincidenti.
        let overlapping = positions.indices.filter { i in
            index.nodes(in: CGRect(x: positions[i].x - 1, y: positions[i].y - 1, width: 2, height: 2)).count > 1
        }
        #expect(overlapping.count < positions.count / 20)
    }

    @Test("stesso grafo, stesse posizioni")
    func deterministic() {
        let (graph, _, _) = sampleGraph(count: 200)
        let a = GraphLayout().positions(for: graph)
        let b = GraphLayout().positions(for: graph)
        #expect(a == b)
    }

    @Test("aggiungere un nodo non rimescola il grafo")
    func incrementalIsStable() {
        let (graph, records, edgeRecords) = sampleGraph(count: 300)
        let first = GraphLayout().positions(for: graph)
        var previous: [UUID: CGPoint] = [:]
        for (i, node) in graph.nodes.enumerated() { previous[node.id] = first[i] }

        let date = Date(timeIntervalSince1970: 0)
        let extra = NodeRecord(type: .idea, title: "Nuovo", area: .progetti, createdAt: date, updatedAt: date, deviceID: "t")
        let link = EdgeRecord(sourceID: extra.id, targetID: records[1].id, kind: .manual, createdAt: date)
        let grown = GraphData(nodes: records + [extra], edges: edgeRecords + [link])
        let second = GraphLayout(config: .incremental).positions(for: grown, previous: previous)
        var moved: [Double] = []
        for (i, node) in graph.nodes.enumerated() {
            moved.append(distance(first[i], second[grown.indexByID[node.id]!]))
        }
        let median = moved.sorted()[moved.count / 2]
        #expect(median < 60, "spostamento mediano \(median)")
    }

    @Test("nodi sovrapposti si separano")
    func coincidentNodesSeparate() {
        let date = Date(timeIntervalSince1970: 0)
        // Indici uguali modulo 35, stessa area, nessun arco: il caso peggiore per una spinta periodica.
        let nodes = (0..<36).map { i in
            NodeRecord(id: UUID(uuid: (UInt8(i), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), type: .concept,
                       title: "\(i)", area: .studio, createdAt: date, updatedAt: date, deviceID: "t")
        }
        let graph = GraphData(nodes: nodes, edges: [])
        let start = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, CGPoint(x: 10, y: 10)) })
        let positions = GraphLayout().positions(for: graph, previous: start)
        #expect(distance(positions[0], positions[35]) > 5)
        #expect(Set(positions.map { "\(Int($0.x)),\(Int($0.y))" }).count == positions.count)
    }

    @Test("calcolo interrotto: risultato vuoto")
    func cancellation() {
        let (graph, _, _) = sampleGraph(count: 100)
        #expect(GraphLayout().positions(for: graph, shouldStop: { true }).isEmpty)
    }

    @Test("indice robusto a posizioni non valide e rettangoli enormi")
    func robustIndex() {
        let index = SpatialIndex(positions: [CGPoint(x: Double.nan, y: 0), CGPoint(x: 1e300, y: -1e300), CGPoint(x: 5, y: 5)])
        // Il nodo a 1e300 sta fuori dal rettangolo, quello NaN non è indicizzato: niente crash.
        #expect(index.nodes(in: CGRect(x: -2e13, y: -2e13, width: 4e13, height: 4e13)) == [2])
        #expect(index.nearest(to: CGPoint(x: 5, y: 6), within: 3) == 2)
        #expect(index.nodes(in: CGRect(x: Double.infinity, y: 0, width: 1, height: 1)).isEmpty)
    }

    @Test("grafo vuoto e con un nodo")
    func edgeCases() {
        #expect(GraphLayout().positions(for: GraphData(nodes: [], edges: [])).isEmpty)
        let date = Date()
        let one = GraphData(nodes: [NodeRecord(type: .idea, title: "x", area: .studio, createdAt: date, updatedAt: date, deviceID: "t")], edges: [])
        #expect(GraphLayout().positions(for: one).count == 1)
    }

    @Test("prestazioni: 3000 nodi e 6000 archi")
    func performance() {
        let (graph, _, _) = sampleGraph(count: 3000)
        let clock = ContinuousClock()
        var config = GraphLayout.Config()
        config.iterations = 100
        let elapsed = clock.measure { _ = GraphLayout(config: config).positions(for: graph) }
        // In debug su Linux; sull'iPad in release è molte volte più veloce e gira in background.
        #expect(elapsed < .seconds(60), "layout in \(elapsed)")
        print("Layout di 3000 nodi, 100 iterazioni: \(elapsed)")

        let positions = GraphLayout(config: .incremental).positions(for: graph)
        let index = SpatialIndex(positions: positions)
        var camera = GraphCamera(viewSize: CGSize(width: 1180, height: 820))
        camera.fit(index.bounds)
        camera.pinch(by: 4, around: CGPoint(x: 590, y: 410))
        // Un fotogramma: nodi visibili e nodo sotto il dito, ben sotto i 16 ms anche in debug.
        let frame = clock.measure {
            for _ in 0..<10 {
                _ = index.nodes(in: camera.visibleRect())
                _ = camera.node(at: CGPoint(x: 590, y: 410), in: index)
            }
        }
        #expect(frame / 10 < .milliseconds(16), "query per fotogramma \(frame / 10)")
    }
}

@Suite("Gesti e camera")
struct GraphCameraTests {
    let size = CGSize(width: 1000, height: 800)

    @Test("vista e scena sono una l'inversa dell'altra")
    func roundTrip() {
        let camera = GraphCamera(center: CGPoint(x: 120, y: -40), zoom: 2.5, viewSize: size)
        let p = CGPoint(x: 333, y: 123)
        let back = camera.sceneToView(camera.viewToScene(p))
        #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
        // y della scena verso l'alto: un punto più in basso sullo schermo ha y più piccola.
        #expect(camera.viewToScene(CGPoint(x: 500, y: 700)).y < camera.viewToScene(CGPoint(x: 500, y: 100)).y)
    }

    @Test("pinch: il punto sotto le dita resta fermo, lo zoom ha limiti")
    func pinch() {
        var camera = GraphCamera(viewSize: size)
        let fingers = CGPoint(x: 200, y: 600)
        let before = camera.viewToScene(fingers)
        camera.pinch(by: 3, around: fingers)
        let after = camera.viewToScene(fingers)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
        #expect(camera.zoom == 3)
        camera.pinch(by: 1000, around: fingers)
        #expect(camera.zoom == GraphCamera.zoomRange.upperBound)
        camera.pinch(by: 0.000001, around: fingers)
        #expect(camera.zoom == GraphCamera.zoomRange.lowerBound)
        camera.pinch(by: .nan, around: fingers)
        #expect(camera.zoom == GraphCamera.zoomRange.lowerBound)
    }

    @Test("pan: il contenuto segue il dito")
    func pan() {
        var camera = GraphCamera(zoom: 2, viewSize: size)
        let node = CGPoint(x: 10, y: 10)
        let before = camera.sceneToView(node)
        camera.pan(by: CGSize(width: 50, height: -30))
        let after = camera.sceneToView(node)
        #expect(abs(after.x - before.x - 50) < 1e-9 && abs(after.y - before.y + 30) < 1e-9)
    }

    @Test("tap: trova il nodo entro un raggio costante sullo schermo")
    func tap() {
        let index = SpatialIndex(positions: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        var camera = GraphCamera(viewSize: size)
        #expect(camera.node(at: CGPoint(x: 510, y: 400), in: index) == 0)
        #expect(camera.node(at: CGPoint(x: 600, y: 400), in: index) == 1)
        #expect(camera.node(at: CGPoint(x: 550, y: 400), in: index) == nil)
        // Da lontano gli stessi 24 punti coprono più scena: il tocco prende ancora il nodo.
        camera.zoom = 0.2
        #expect(camera.node(at: CGPoint(x: 504, y: 400), in: index) == 0)
    }

    @Test("Pencil: collega due nodi diversi, ignora tratti nel vuoto")
    func pencilLink() {
        let index = SpatialIndex(positions: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        let camera = GraphCamera(viewSize: size)
        let link = PencilLink.endpoints(from: CGPoint(x: 500, y: 400), to: CGPoint(x: 600, y: 402), camera: camera, index: index)
        #expect(link.map { [$0.0, $0.1] } == [0, 1])
        #expect(PencilLink.endpoints(from: CGPoint(x: 500, y: 400), to: CGPoint(x: 502, y: 400), camera: camera, index: index) == nil)
        #expect(PencilLink.endpoints(from: CGPoint(x: 500, y: 400), to: CGPoint(x: 800, y: 100), camera: camera, index: index) == nil)
    }

    @Test("zoom semantico: cluster, nodi, etichette")
    func semanticZoom() {
        #expect(GraphDetail(zoom: 0.1) == .clusters)
        #expect(GraphDetail(zoom: 0.6) == .nodes)
        #expect(GraphDetail(zoom: 2) == .labels)
        var camera = GraphCamera(viewSize: size)
        camera.focus(on: CGPoint(x: 5, y: 5))
        #expect(camera.detail == .labels)
        #expect(camera.center == CGPoint(x: 5, y: 5))
    }

    @Test("inquadra tutto il grafo")
    func fit() {
        var camera = GraphCamera(viewSize: size)
        let rect = CGRect(x: -500, y: -200, width: 1000, height: 400)
        camera.fit(rect)
        let visible = camera.visibleRect(margin: 0)
        #expect(visible.contains(CGPoint(x: rect.minX, y: rect.minY)))
        #expect(visible.contains(CGPoint(x: rect.maxX, y: rect.maxY)))
    }
}

@Suite("Ricerca e dati del grafo")
struct GraphFilterTests {
    @Test("testo, aree e tipi; titolo prima del corpo")
    func filter() {
        let (graph, _, _) = sampleGraph(count: 60, edgesPerNode: 0)
        let derivata = GraphFilter(query: "DERIVATA").matches(in: graph)
        #expect(derivata.count == 6, "nodi con 'derivata' nel corpo")
        #expect(GraphFilter(query: "nodo 12").matches(in: graph).first == 12)
        let studio = GraphFilter(areas: [.studio]).matches(in: graph)
        #expect(studio.allSatisfy { graph.nodes[$0].area == .studio })
        #expect(GraphFilter(query: "analisi", types: [.health]).matches(in: graph).allSatisfy { graph.nodes[$0].isSensitive })
        #expect(!GraphFilter().isActive)
        #expect(GraphFilter(query: "x").isActive)
    }

    @Test("nodi nel cestino e archi verso di loro restano fuori")
    func graphData() {
        let date = Date()
        var a = NodeRecord(type: .concept, title: "a", area: .studio, createdAt: date, updatedAt: date, deviceID: "t")
        let b = NodeRecord(type: .concept, title: "b", area: .studio, createdAt: date, updatedAt: date, deviceID: "t")
        let c = NodeRecord(type: .health, title: "c", area: .salute, createdAt: date, updatedAt: date, deviceID: "t")
        let edges = [
            EdgeRecord(sourceID: a.id, targetID: b.id, kind: .link, createdAt: date),
            EdgeRecord(sourceID: b.id, targetID: a.id, kind: .manual, createdAt: date),
            EdgeRecord(sourceID: b.id, targetID: c.id, kind: .manual, createdAt: date),
        ]
        let graph = GraphData(nodes: [a, b, c], edges: edges)
        #expect(graph.edges.count == 2, "un solo arco per coppia")
        #expect(graph.nodes[2].isSensitive)
        #expect(graph.nodes[1].degree == 2)
        a.deletedAt = date
        let withoutA = GraphData(nodes: [a, b, c], edges: edges)
        #expect(withoutA.nodes.map(\.title) == ["b", "c"])
        #expect(withoutA.edges.count == 1)
        #expect(withoutA.structureKey != graph.structureKey)
    }

    @Test("vicini per l'elenco accessibile: simmetrici, prima i più collegati")
    func neighbors() {
        let date = Date()
        let records = ["hub", "beta", "alfa", "solo"].map {
            NodeRecord(type: .concept, title: $0, area: .studio, createdAt: date, updatedAt: date, deviceID: "t")
        }
        let link = { (s: Int, t: Int) in
            EdgeRecord(sourceID: records[s].id, targetID: records[t].id, kind: .link, createdAt: date)
        }
        // hub è collegato a beta e alfa; beta anche ad alfa.
        let graph = GraphData(nodes: records, edges: [link(0, 1), link(2, 0), link(1, 2)])
        let near = graph.neighbors()
        #expect(near.count == 4)
        #expect(near[0].map { graph.nodes[$0].title } == ["alfa", "beta"], "stesso grado: per titolo")
        #expect(near[2].map { graph.nodes[$0].title } == ["beta", "hub"])
        #expect(near[3].isEmpty)
        for (i, list) in near.enumerated() {
            #expect(list.allSatisfy { near[$0].contains(i) }, "un arco vale nei due sensi")
        }
        #expect(GraphData(nodes: [], edges: []).neighbors().isEmpty)
    }
}

@MainActor
@Suite("Archi dai link [[...]]")
struct LinkEdgeTests {
    @Test("crea, ripristina e toglie solo gli archi di tipo link")
    func syncLinks() throws {
        let store = InMemoryStore()
        let repository = Repository(store: store, deviceID: "a")
        let a = repository.createNode(type: .concept, title: "A", area: .studio)
        let b = repository.createNode(type: .concept, title: "B", area: .studio)
        let c = repository.createNode(type: .concept, title: "C", area: .studio)
        let manual = try repository.createEdge(from: a.id, to: c.id, kind: .manual)

        repository.syncLinkEdges(from: a.id, to: [b.id, c.id, a.id])
        let links = { store.allEdges().filter { $0.kind == .link && $0.deletedAt == nil }.map(\.targetID) }
        #expect(Set(links()) == [b.id, c.id], "niente arco verso sé stesso")

        repository.syncLinkEdges(from: a.id, to: [c.id])
        #expect(links() == [c.id])
        #expect(store.edge(manual.id)?.deletedAt == nil, "l'arco manuale resta")

        repository.syncLinkEdges(from: a.id, to: [b.id, c.id])
        #expect(Set(links()) == [b.id, c.id])
        #expect(store.allEdges().filter { $0.kind == .link }.count == 2, "l'arco verso B è ripristinato, non duplicato")

        // Doppione arrivato da un altro dispositivo: togliendo il link spariscono entrambi.
        let duplicate = EdgeRecord(sourceID: a.id, targetID: b.id, kind: .link, createdAt: Date())
        store.saveEdge(duplicate)
        repository.syncLinkEdges(from: a.id, to: [b.id, c.id])
        #expect(links().filter { $0 == b.id }.count == 1, "un solo arco attivo per destinazione")
        repository.syncLinkEdges(from: a.id, to: [c.id])
        #expect(links() == [c.id])
    }
}
