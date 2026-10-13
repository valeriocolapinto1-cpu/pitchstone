import Foundation

/// Layout a forze (Fruchterman–Reingold) con repulsione approssimata Barnes–Hut,
/// O(n log n) per iterazione, e un'attrazione verso il centro dell'area che forma
/// i cluster. Deterministico: stesse entrate, stesse posizioni.
public struct GraphLayout: Sendable {
    public struct Config: Sendable {
        /// Lunghezza ideale di un arco.
        public var spacing: Double = 60
        public var iterations: Int = 300
        /// Precisione di Barnes–Hut: più alto è più veloce e meno preciso.
        public var theta: Double = 0.9
        /// Forza che tiene i nodi vicini al centro della loro area.
        public var clusterGravity: Double = 0.04
        /// Spostamento massimo iniziale per iterazione; decresce fino a quasi zero.
        public var initialTemperature: Double = 80

        public init() {}

        /// Per aggiornare un layout esistente: pochi passi, piccoli.
        public static var incremental: Config {
            var c = Config()
            c.iterations = 60
            c.initialTemperature = 15
            return c
        }
    }

    public var config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Posizioni dei nodi, nell'ordine di `graph.nodes`. `previous` tiene fermi i nodi
    /// già disposti: il grafo non si rimescola a ogni modifica.
    public func positions(for graph: GraphData, previous: [UUID: CGPoint] = [:]) -> [CGPoint] {
        let n = graph.nodes.count
        guard n > 0 else { return [] }
        var x = [Double](repeating: 0, count: n)
        var y = [Double](repeating: 0, count: n)
        var cx = [Double](repeating: 0, count: n)
        var cy = [Double](repeating: 0, count: n)

        for (i, node) in graph.nodes.enumerated() {
            let center = AreaLayout.center(of: node.area, nodeCount: n)
            cx[i] = Double(center.x)
            cy[i] = Double(center.y)
            if let p = previous[node.id] {
                x[i] = Double(p.x)
                y[i] = Double(p.y)
            } else {
                // Posizione iniziale pseudo-casuale ma stabile, ricavata dall'UUID.
                let (u, v) = Self.unitPair(node.id)
                let r = AreaLayout.clusterRadius(nodeCount: n) * 0.5 * u.squareRoot()
                x[i] = cx[i] + r * cos(2 * .pi * v)
                y[i] = cy[i] + r * sin(2 * .pi * v)
            }
        }

        let k = config.spacing
        let k2 = k * k
        var dx = [Double](repeating: 0, count: n)
        var dy = [Double](repeating: 0, count: n)
        var tree = QuadTree(capacity: n)

        for step in 0..<config.iterations {
            let t = config.initialTemperature * (1 - Double(step) / Double(config.iterations)) + 0.5
            for i in 0..<n {
                dx[i] = 0
                dy[i] = 0
            }

            // Repulsione tra tutti i nodi (Barnes–Hut).
            tree.build(x: x, y: y)
            for i in 0..<n {
                let f = tree.repulsion(at: i, x: x, y: y, k2: k2, theta: config.theta)
                dx[i] += f.0
                dy[i] += f.1
            }

            // Attrazione lungo gli archi.
            for edge in graph.edges {
                let s = edge.source, d = edge.target
                let ex = x[s] - x[d], ey = y[s] - y[d]
                let dist = max((ex * ex + ey * ey).squareRoot(), 0.01)
                let f = dist / k
                dx[s] -= ex * f
                dy[s] -= ey * f
                dx[d] += ex * f
                dy[d] += ey * f
            }

            // Gravità verso il centro dell'area.
            for i in 0..<n {
                dx[i] += (cx[i] - x[i]) * config.clusterGravity * k
                dy[i] += (cy[i] - y[i]) * config.clusterGravity * k
            }

            // Spostamento limitato dalla temperatura.
            for i in 0..<n {
                let len = (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot()
                guard len > 0 else { continue }
                let move = min(len, t)
                x[i] += dx[i] / len * move
                y[i] += dy[i] / len * move
            }
        }
        return (0..<n).map { CGPoint(x: x[$0], y: y[$0]) }
    }

    /// Due numeri in [0, 1) ricavati dai byte dell'UUID.
    static func unitPair(_ id: UUID) -> (Double, Double) {
        let b = id.uuid
        let a = UInt32(b.0) << 24 | UInt32(b.1) << 16 | UInt32(b.2) << 8 | UInt32(b.3)
        let c = UInt32(b.8) << 24 | UInt32(b.9) << 16 | UInt32(b.10) << 8 | UInt32(b.11)
        return (Double(a) / 4_294_967_296, Double(c) / 4_294_967_296)
    }
}

/// Quadtree per la repulsione di Barnes–Hut, in array piatti e riusato tra le iterazioni.
struct QuadTree {
    private var px: [Double] = []
    private var py: [Double] = []
    private var minX: [Double] = []
    private var minY: [Double] = []
    private var size: [Double] = []
    private var massX: [Double] = []
    private var massY: [Double] = []
    private var mass: [Double] = []
    /// Primo dei 4 figli consecutivi, o -1 se foglia.
    private var child: [Int32] = []
    /// Punto della foglia: -1 vuota, -2 più punti sovrapposti oltre la profondità massima.
    private var point: [Int32] = []
    private static let maxDepth = 24

    init(capacity: Int) {
        let c = max(capacity * 4, 16)
        for keyPath in [\QuadTree.minX, \.minY, \.size, \.massX, \.massY, \.mass] {
            self[keyPath: keyPath].reserveCapacity(c)
        }
        child.reserveCapacity(c)
        point.reserveCapacity(c)
    }

    private mutating func addCell(_ x: Double, _ y: Double, _ s: Double) -> Int {
        minX.append(x)
        minY.append(y)
        size.append(s)
        massX.append(0)
        massY.append(0)
        mass.append(0)
        child.append(-1)
        point.append(-1)
        return minX.count - 1
    }

    mutating func build(x: [Double], y: [Double]) {
        px = x
        py = y
        for keyPath in [\QuadTree.minX, \.minY, \.size, \.massX, \.massY, \.mass] {
            self[keyPath: keyPath].removeAll(keepingCapacity: true)
        }
        child.removeAll(keepingCapacity: true)
        point.removeAll(keepingCapacity: true)

        var lx = Double.infinity, ly = Double.infinity, hx = -Double.infinity, hy = -Double.infinity
        for i in x.indices {
            lx = min(lx, x[i]); ly = min(ly, y[i])
            hx = max(hx, x[i]); hy = max(hy, y[i])
        }
        let s = max(hx - lx, hy - ly, 1) * 1.0001
        _ = addCell(lx, ly, s)
        for i in x.indices { insert(i, cell: 0, depth: 0) }
    }

    private mutating func insert(_ i: Int, cell start: Int, depth start0: Int) {
        var cell = start
        var depth = start0
        while true {
            // Centro di massa aggiornato lungo il percorso.
            let m = mass[cell]
            massX[cell] = (massX[cell] * m + px[i]) / (m + 1)
            massY[cell] = (massY[cell] * m + py[i]) / (m + 1)
            mass[cell] = m + 1

            if child[cell] < 0 {
                if point[cell] == -1 {
                    point[cell] = Int32(i)
                    return
                }
                if point[cell] == -2 || depth >= Self.maxDepth {
                    // Punti (quasi) sovrapposti: la foglia diventa un aggregato.
                    point[cell] = -2
                    return
                }
                // Divide la foglia e sposta il suo punto in un figlio.
                let half = size[cell] / 2
                let first = addCell(minX[cell], minY[cell], half)
                _ = addCell(minX[cell] + half, minY[cell], half)
                _ = addCell(minX[cell], minY[cell] + half, half)
                _ = addCell(minX[cell] + half, minY[cell] + half, half)
                child[cell] = Int32(first)
                let old = Int(point[cell])
                point[cell] = -1
                let oldChild = quadrant(of: old, in: cell)
                mass[oldChild] = 1
                massX[oldChild] = px[old]
                massY[oldChild] = py[old]
                point[oldChild] = Int32(old)
            }
            cell = quadrant(of: i, in: cell)
            depth += 1
        }
    }

    private func quadrant(of i: Int, in cell: Int) -> Int {
        let half = size[cell] / 2
        let qx = px[i] >= minX[cell] + half ? 1 : 0
        let qy = py[i] >= minY[cell] + half ? 1 : 0
        return Int(child[cell]) + qx + 2 * qy
    }

    /// Forza repulsiva di modulo k²/d su `i` dagli altri nodi.
    func repulsion(at i: Int, x: [Double], y: [Double], k2: Double, theta: Double) -> (Double, Double) {
        var fx = 0.0, fy = 0.0
        var stack: [Int] = [0]
        stack.reserveCapacity(64)
        let qx = x[i], qy = y[i]
        while let cell = stack.popLast() {
            var m = mass[cell]
            if m == 0 { continue }
            let leaf = child[cell] < 0
            if leaf && point[cell] == Int32(i) { continue }
            var ddx = qx - massX[cell]
            var ddy = qy - massY[cell]
            var d2 = ddx * ddx + ddy * ddy
            if leaf || size[cell] * size[cell] < theta * theta * d2 {
                if d2 < 0.01 {
                    // Sovrapposti (anche `i` può far parte dell'aggregato): spinta stabile.
                    if leaf && point[cell] == -2 { m = max(m - 1, 0) }
                    if m == 0 { continue }
                    ddx = Double(i % 7) - 2.9
                    ddy = Double(i % 5) - 1.9
                    d2 = ddx * ddx + ddy * ddy
                }
                let f = k2 * m / d2
                fx += ddx * f
                fy += ddy * f
            } else {
                let first = Int(child[cell])
                stack.append(first)
                stack.append(first + 1)
                stack.append(first + 2)
                stack.append(first + 3)
            }
        }
        return (fx, fy)
    }
}
