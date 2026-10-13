import Foundation
import PitchstoneSync

/// Grafo pronto per il layout e il disegno: nodi attivi e archi tra nodi attivi,
/// indicizzati per posizione negli array (più veloce dei dizionari per UUID).
public struct GraphData: Sendable, Equatable {
    public struct Node: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        public var type: NodeType
        public var area: Area
        public var tags: [String]
        public var body: String
        public var degree: Int

        public var isSensitive: Bool { type == .health || area == .salute }
    }

    public struct Edge: Sendable, Equatable {
        public var source: Int
        public var target: Int
        public var kind: EdgeKind
    }

    public private(set) var nodes: [Node]
    public private(set) var edges: [Edge]
    public private(set) var indexByID: [UUID: Int]

    public init(nodes records: [NodeRecord], edges edgeRecords: [EdgeRecord]) {
        let active = records.filter { $0.deletedAt == nil }
        var index: [UUID: Int] = [:]
        index.reserveCapacity(active.count)
        for (i, node) in active.enumerated() { index[node.id] = i }

        var degree = [Int](repeating: 0, count: active.count)
        var seen = Set<[Int]>()
        var edges: [Edge] = []
        for edge in edgeRecords where edge.deletedAt == nil {
            guard let s = index[edge.sourceID], let t = index[edge.targetID], s != t else { continue }
            // Un solo arco per coppia nel disegno, anche se ce ne sono di tipi diversi.
            guard seen.insert([min(s, t), max(s, t)]).inserted else { continue }
            edges.append(Edge(source: s, target: t, kind: edge.kind))
            degree[s] += 1
            degree[t] += 1
        }

        nodes = active.enumerated().map { i, n in
            Node(id: n.id, title: n.title, type: n.type, area: n.area, tags: n.tags, body: n.bodyMD, degree: degree[i])
        }
        self.edges = edges
        indexByID = index
    }

    public var isEmpty: Bool { nodes.isEmpty }

    /// Firma della struttura: cambia se cambiano nodi, aree o archi, non se cambia un testo.
    /// Serve a decidere quando ricalcolare il layout.
    public var structureKey: Int {
        var hasher = Hasher()
        for node in nodes {
            hasher.combine(node.id)
            hasher.combine(node.area)
        }
        for edge in edges {
            hasher.combine(edge.source)
            hasher.combine(edge.target)
        }
        return hasher.finalize()
    }
}

/// Ordine stabile delle aree sul piano: ogni area ha il suo settore.
public enum AreaLayout {
    public static let order: [Area] = [.studio, .progetti, .lavoro, .persone, .interessi, .salute]

    /// Centro del cluster di un'area, su un cerchio il cui raggio cresce con il grafo.
    public static func center(of area: Area, nodeCount: Int) -> CGPoint {
        let index = order.firstIndex(of: area) ?? 0
        let angle = 2 * Double.pi * Double(index) / Double(order.count) - Double.pi / 2
        let radius = clusterRadius(nodeCount: nodeCount)
        return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
    }

    public static func clusterRadius(nodeCount: Int) -> Double {
        120 + 18 * Double(max(nodeCount, 1)).squareRoot()
    }
}
