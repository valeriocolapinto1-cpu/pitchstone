import Foundation

/// Griglia uniforme sulle posizioni dei nodi: trova il nodo toccato e i nodi visibili
/// senza scorrere tutto il grafo a ogni fotogramma.
public struct SpatialIndex: Sendable {
    public let cellSize: Double
    private var cells: [Cell: [Int]] = [:]
    public private(set) var positions: [CGPoint]

    struct Cell: Hashable, Sendable {
        var x: Int
        var y: Int
    }

    public init(positions: [CGPoint], cellSize: Double = 64) {
        self.cellSize = cellSize
        self.positions = positions
        for (i, p) in positions.enumerated() {
            cells[cell(p), default: []].append(i)
        }
    }

    private func cell(_ p: CGPoint) -> Cell {
        Cell(x: Int((Double(p.x) / cellSize).rounded(.down)), y: Int((Double(p.y) / cellSize).rounded(.down)))
    }

    /// Indici dei nodi dentro il rettangolo (coordinate della scena).
    public func nodes(in rect: CGRect) -> [Int] {
        guard !rect.isNull, rect.width.isFinite, rect.height.isFinite else { return [] }
        let low = cell(CGPoint(x: rect.minX, y: rect.minY))
        let high = cell(CGPoint(x: rect.maxX, y: rect.maxY))
        // Rettangolo enorme (zoom molto basso): più veloce controllare tutti i nodi.
        let cellCount = (high.x - low.x + 1) * (high.y - low.y + 1)
        if cellCount > cells.count {
            return positions.indices.filter { rect.contains(positions[$0]) }
        }
        var result: [Int] = []
        for cx in low.x...high.x {
            for cy in low.y...high.y {
                for i in cells[Cell(x: cx, y: cy)] ?? [] where rect.contains(positions[i]) {
                    result.append(i)
                }
            }
        }
        return result
    }

    /// Il nodo più vicino a `point` entro `radius`, se c'è.
    public func nearest(to point: CGPoint, within radius: Double) -> Int? {
        let rect = CGRect(x: Double(point.x) - radius, y: Double(point.y) - radius, width: 2 * radius, height: 2 * radius)
        var best: (Int, Double)?
        for i in nodes(in: rect) {
            let dx = Double(positions[i].x - point.x), dy = Double(positions[i].y - point.y)
            let d2 = dx * dx + dy * dy
            if d2 <= radius * radius, d2 < (best?.1 ?? .infinity) { best = (i, d2) }
        }
        return best?.0
    }

    /// Rettangolo che contiene tutti i nodi.
    public var bounds: CGRect {
        guard let first = positions.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in positions {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Livelli dello zoom semantico.
public enum GraphDetail: Sendable, Equatable {
    /// Da lontano: bolle delle aree con il numero di nodi.
    case clusters
    /// Distanza media: nodi senza etichette.
    case nodes
    /// Da vicino: nodi con il titolo.
    case labels

    public static let clusterThreshold: Double = 0.3
    public static let labelThreshold: Double = 1.1

    public init(zoom: Double) {
        if zoom < Self.clusterThreshold {
            self = .clusters
        } else if zoom < Self.labelThreshold {
            self = .nodes
        } else {
            self = .labels
        }
    }
}

/// Camera del grafo e significato dei gesti, indipendenti da SpriteKit.
/// Coordinate della vista: origine in alto a sinistra, y verso il basso (UIKit).
/// Coordinate della scena: y verso l'alto (SpriteKit).
public struct GraphCamera: Sendable, Equatable {
    public static let zoomRange: ClosedRange<Double> = 0.05...6
    /// Raggio del tocco in punti dello schermo, indipendente dallo zoom.
    public static let touchRadius: Double = 24

    /// Punto della scena al centro dello schermo.
    public var center: CGPoint
    /// Punti dello schermo per unità della scena.
    public var zoom: Double
    public var viewSize: CGSize

    public init(center: CGPoint = .zero, zoom: Double = 1, viewSize: CGSize) {
        self.center = center
        self.zoom = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        self.viewSize = viewSize
    }

    public var detail: GraphDetail { GraphDetail(zoom: zoom) }

    public func sceneToView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: Double(viewSize.width) / 2 + Double(p.x - center.x) * zoom,
                y: Double(viewSize.height) / 2 - Double(p.y - center.y) * zoom)
    }

    public func viewToScene(_ p: CGPoint) -> CGPoint {
        CGPoint(x: Double(center.x) + (Double(p.x) - Double(viewSize.width) / 2) / zoom,
                y: Double(center.y) - (Double(p.y) - Double(viewSize.height) / 2) / zoom)
    }

    /// Parte della scena visibile, con un margine per non far comparire i nodi di colpo.
    public func visibleRect(margin: Double = 40) -> CGRect {
        let w = Double(viewSize.width) / zoom + 2 * margin / zoom
        let h = Double(viewSize.height) / zoom + 2 * margin / zoom
        return CGRect(x: Double(center.x) - w / 2, y: Double(center.y) - h / 2, width: w, height: h)
    }

    // MARK: Gesti

    /// Pinch: lo zoom cambia di `factor` tenendo fermo il punto sotto le dita.
    public mutating func pinch(by factor: Double, around viewPoint: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let anchor = viewToScene(viewPoint)
        zoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        // Dopo lo zoom il punto della scena sotto le dita deve restare lì.
        let moved = viewToScene(viewPoint)
        center.x += anchor.x - moved.x
        center.y += anchor.y - moved.y
    }

    /// Trascinamento: il contenuto segue il dito.
    public mutating func pan(by viewDelta: CGSize) {
        center.x -= viewDelta.width / zoom
        center.y += viewDelta.height / zoom
    }

    /// Nodo sotto un tocco, con un raggio costante sullo schermo.
    public func node(at viewPoint: CGPoint, in index: SpatialIndex) -> Int? {
        index.nearest(to: viewToScene(viewPoint), within: Self.touchRadius / zoom)
    }

    /// Inquadra un rettangolo della scena con un margine.
    public mutating func fit(_ rect: CGRect, padding: Double = 40) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        center = CGPoint(x: rect.midX, y: rect.midY)
        let w = max(Double(rect.width), 1), h = max(Double(rect.height), 1)
        let zx = (Double(viewSize.width) - 2 * padding) / w
        let zy = (Double(viewSize.height) - 2 * padding) / h
        zoom = min(max(min(zx, zy), Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    /// Centra un punto con uno zoom da etichette, per mostrare un risultato di ricerca.
    public mutating func focus(on point: CGPoint) {
        center = point
        zoom = max(zoom, GraphDetail.labelThreshold * 1.4)
    }
}

/// Collegamento con la Pencil: si parte da un nodo, si arriva su un altro.
public enum PencilLink {
    /// Coppia di nodi da collegare, o nil se il tratto non va da un nodo a un altro.
    public static func endpoints(from start: CGPoint, to end: CGPoint, camera: GraphCamera, index: SpatialIndex) -> (Int, Int)? {
        guard let a = camera.node(at: start, in: index), let b = camera.node(at: end, in: index), a != b else { return nil }
        return (a, b)
    }
}
