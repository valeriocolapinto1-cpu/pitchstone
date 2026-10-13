import PitchstoneGraph
import PitchstoneSync
import SpriteKit
import UIKit

/// Scena SpriteKit del grafo. Disegna soltanto: layout, camera, gesti e ricerca
/// stanno in PitchstoneGraph (testati su Linux).
///
/// Prestazioni: i nodi sono sprite con la stessa texture (un solo draw call), tutti
/// gli archi sono un unico percorso, le etichette sono un insieme fisso riciclato
/// e compaiono solo per i nodi visibili a zoom alto.
final class GraphScene: SKScene {
    /// Tap: apre il nodo (false); doppio tap: lo apre in modifica (true).
    var onOpen: ((UUID, Bool) -> Void)?
    /// Pencil da un nodo a un altro: collega i due nodi.
    var onLink: ((UUID, UUID) -> Void)?

    private(set) var graphCamera = GraphCamera(viewSize: CGSize(width: 1, height: 1))
    private var graph = GraphData(nodes: [], edges: [])
    private var positions: [CGPoint] = []
    private var index = SpatialIndex(positions: [])
    private var highlighted: Set<Int> = []
    private var filterActive = false
    private var hasFitted = false

    private let cameraNode = SKCameraNode()
    private let edgesNode = SKShapeNode()
    private let nodesLayer = SKNode()
    private let clustersLayer = SKNode()
    private let labelsLayer = SKNode()
    private let linkLine = SKShapeNode()
    private var sprites: [SKSpriteNode] = []
    private var labelPool: [SKLabelNode] = []
    private var clusterLabels: [SKLabelNode] = []
    private var linkStart: Int?

    private static let maxLabels = 150
    private static let dotTexture: SKTexture = {
        let size = CGSize(width: 64, height: 64)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)).fill()
        }
        return SKTexture(image: image)
    }()

    /// Shader Metal (SpriteKit compila il sorgente per Metal): i risultati della ricerca pulsano.
    private static let pulseShader = SKShader(source: """
    void main() {
        vec4 color = SKDefaultShading();
        float pulse = 0.75 + 0.25 * sin(u_time * 4.0);
        gl_FragColor = vec4(color.rgb * (0.7 + 0.5 * pulse), color.a);
    }
    """)

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        backgroundColor = .systemBackground
        camera = cameraNode
        addChild(cameraNode)

        edgesNode.strokeColor = UIColor.secondaryLabel.withAlphaComponent(0.35)
        edgesNode.lineWidth = 1
        edgesNode.isAntialiased = true
        edgesNode.zPosition = 0
        addChild(edgesNode)

        clustersLayer.zPosition = -1
        addChild(clustersLayer)
        nodesLayer.zPosition = 1
        addChild(nodesLayer)
        labelsLayer.zPosition = 2
        addChild(labelsLayer)

        linkLine.strokeColor = .systemPink
        linkLine.lineWidth = 3
        linkLine.zPosition = 3
        linkLine.isHidden = true
        addChild(linkLine)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) non supportato")
    }

    // MARK: Dati

    /// Nuovi dati: ricostruisce sprite, archi e cluster. `positions` è nell'ordine di `graph.nodes`.
    func show(_ graph: GraphData, positions: [CGPoint]) {
        guard positions.count == graph.nodes.count else { return }
        // Stessa struttura e stesse posizioni (per esempio un testo salvato): bastano
        // i dati nuovi per etichette e ricerca, senza ricostruire migliaia di sprite.
        if graph.structureKey == self.graph.structureKey, positions == self.positions, !sprites.isEmpty {
            self.graph = graph
            for (i, node) in graph.nodes.enumerated() { sprites[i].color = node.graphColor }
            updateLabels()
            return
        }
        self.graph = graph
        self.positions = positions
        index = SpatialIndex(positions: positions)

        nodesLayer.removeAllChildren()
        sprites = graph.nodes.enumerated().map { i, node in
            let sprite = SKSpriteNode(texture: Self.dotTexture)
            let diameter = 10 + 3 * min(Double(node.degree), 10).squareRoot() * 2
            sprite.size = CGSize(width: diameter, height: diameter)
            sprite.color = node.graphColor
            sprite.colorBlendFactor = 1
            sprite.position = positions[i]
            nodesLayer.addChild(sprite)
            return sprite
        }

        let path = CGMutablePath()
        for edge in graph.edges {
            path.move(to: positions[edge.source])
            path.addLine(to: positions[edge.target])
        }
        edgesNode.path = path

        buildClusters()
        applyHighlight()
        if !hasFitted, !positions.isEmpty, size.width > 1 {
            graphCamera.fit(index.bounds)
            hasFitted = true
        }
        applyCamera()
    }

    /// Bolle delle aree per lo zoom lontano: centro, raggio e numero di nodi.
    private func buildClusters() {
        clustersLayer.removeAllChildren()
        clusterLabels = []
        var groups: [Area: [Int]] = [:]
        for (i, node) in graph.nodes.enumerated() { groups[node.area, default: []].append(i) }
        for area in AreaLayout.order {
            guard let members = groups[area], !members.isEmpty else { continue }
            let cx = members.reduce(0.0) { $0 + Double(positions[$1].x) } / Double(members.count)
            let cy = members.reduce(0.0) { $0 + Double(positions[$1].y) } / Double(members.count)
            let distances = members.map { i -> Double in
                let dx = Double(positions[i].x) - cx, dy = Double(positions[i].y) - cy
                return (dx * dx + dy * dy).squareRoot()
            }.sorted()
            let radius = max(distances[Int(Double(distances.count - 1) * 0.85)], 40) + 30
            let bubble = SKShapeNode(circleOfRadius: radius)
            bubble.position = CGPoint(x: cx, y: cy)
            bubble.fillColor = area.graphColor.withAlphaComponent(0.10)
            bubble.strokeColor = area.graphColor.withAlphaComponent(0.35)
            bubble.lineWidth = 2
            clustersLayer.addChild(bubble)

            let label = SKLabelNode(text: "\(area.graphName) · \(members.count)")
            label.fontName = "HelveticaNeue-Bold"
            label.fontColor = area.graphColor
            label.verticalAlignmentMode = .center
            label.position = CGPoint(x: cx, y: cy)
            label.zPosition = 4
            clustersLayer.addChild(label)
            clusterLabels.append(label)
        }
    }

    // MARK: Ricerca

    /// Evidenzia i risultati; nil spegne il filtro.
    func highlight(_ matches: [Int]?) {
        filterActive = matches != nil
        highlighted = Set(matches ?? [])
        applyHighlight()
    }

    private func applyHighlight() {
        for (i, sprite) in sprites.enumerated() {
            let on = !filterActive || highlighted.contains(i)
            sprite.alpha = on ? 1 : 0.12
            // Lo shader rompe il raggruppamento dei draw call: solo per pochi risultati.
            sprite.shader = filterActive && on && highlighted.count <= 200 ? Self.pulseShader : nil
        }
        edgesNode.alpha = filterActive ? 0.3 : 1
        updateLabels()
    }

    /// Centra un nodo (per esempio il primo risultato della ricerca).
    func focus(on id: UUID) {
        guard let i = graph.indexByID[id], i < positions.count else { return }
        graphCamera.focus(on: positions[i])
        applyCamera()
    }

    func fitAll() {
        guard !positions.isEmpty else { return }
        graphCamera.fit(index.bounds)
        applyCamera()
    }

    // MARK: Camera e zoom semantico

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        graphCamera.viewSize = size
        if !hasFitted, !positions.isEmpty, size.width > 1 {
            graphCamera.fit(index.bounds)
            hasFitted = true
        }
        applyCamera()
    }

    private func applyCamera() {
        cameraNode.position = graphCamera.center
        cameraNode.setScale(1 / graphCamera.zoom)
        // Archi sempre sottili sullo schermo.
        edgesNode.lineWidth = max(0.5, 1 / graphCamera.zoom)
        linkLine.lineWidth = 3 / graphCamera.zoom

        let detail = graphCamera.detail
        clustersLayer.alpha = detail == .clusters ? 1 : (detail == .nodes ? 0.35 : 0)
        for label in clusterLabels {
            label.fontSize = 20 / graphCamera.zoom
            label.isHidden = detail == .labels
        }
        nodesLayer.alpha = detail == .clusters ? 0.5 : 1
        updateLabels()
    }

    /// Titoli solo da vicino e solo per i nodi visibili (al massimo `maxLabels`).
    private func updateLabels() {
        guard graphCamera.detail == .labels else {
            labelsLayer.isHidden = true
            return
        }
        labelsLayer.isHidden = false
        var visible = index.nodes(in: graphCamera.visibleRect())
        if filterActive { visible.sort { highlighted.contains($0) && !highlighted.contains($1) } }
        if visible.count > Self.maxLabels {
            // Precedenza ai nodi più collegati.
            visible = Array(visible.sorted { graph.nodes[$0].degree > graph.nodes[$1].degree }.prefix(Self.maxLabels))
        }
        while labelPool.count < visible.count {
            let label = SKLabelNode()
            label.fontName = "HelveticaNeue"
            label.fontColor = .label
            label.verticalAlignmentMode = .top
            labelsLayer.addChild(label)
            labelPool.append(label)
        }
        let fontSize = 12 / graphCamera.zoom
        for (slot, label) in labelPool.enumerated() {
            guard slot < visible.count else {
                label.isHidden = true
                continue
            }
            let i = visible[slot]
            let node = graph.nodes[i]
            label.isHidden = false
            label.text = node.title.isEmpty ? String(localized: "Senza titolo") : node.title
            label.fontSize = fontSize
            label.position = CGPoint(x: positions[i].x, y: positions[i].y - (sprites[i].size.height / 2 + 4 / graphCamera.zoom))
            label.alpha = (!filterActive || highlighted.contains(i)) ? 1 : 0.25
        }
    }

    // MARK: Gesti

    override func didMove(to view: SKView) {
        super.didMove(to: view)
        view.isMultipleTouchEnabled = true

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        view.addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)

        let pencil = UIPanGestureRecognizer(target: self, action: #selector(handlePencil))
        pencil.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        view.addGestureRecognizer(pencil)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let view = recognizer.view, recognizer.state == .changed || recognizer.state == .ended else { return }
        graphCamera.pinch(by: Double(recognizer.scale), around: recognizer.location(in: view))
        recognizer.scale = 1
        applyCamera()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let view = recognizer.view, recognizer.state == .changed || recognizer.state == .ended else { return }
        let delta = recognizer.translation(in: view)
        graphCamera.pan(by: CGSize(width: delta.x, height: delta.y))
        recognizer.setTranslation(.zero, in: view)
        applyCamera()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view, let i = graphCamera.node(at: recognizer.location(in: view), in: index) else { return }
        onOpen?(graph.nodes[i].id, false)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view, let i = graphCamera.node(at: recognizer.location(in: view), in: index) else { return }
        onOpen?(graph.nodes[i].id, true)
    }

    @objc private func handlePencil(_ recognizer: UIPanGestureRecognizer) {
        guard let view = recognizer.view else { return }
        let point = recognizer.location(in: view)
        switch recognizer.state {
        case .began:
            linkStart = graphCamera.node(at: point, in: index)
            linkLine.isHidden = linkStart == nil
        case .changed:
            guard let start = linkStart else { return }
            let path = CGMutablePath()
            path.move(to: positions[start])
            path.addLine(to: graphCamera.viewToScene(point))
            linkLine.path = path
        case .ended:
            if let start = linkStart, let end = graphCamera.node(at: point, in: index), end != start {
                onLink?(graph.nodes[start].id, graph.nodes[end].id)
            }
            fallthrough
        default:
            linkStart = nil
            linkLine.isHidden = true
            linkLine.path = nil
        }
    }
}

extension GraphData.Node {
    /// Colore del nodo: quello dell'area; i dati di salute hanno sempre il loro colore dedicato.
    var graphColor: UIColor {
        isSensitive ? Area.salute.graphColor : area.graphColor
    }
}

extension Area {
    var graphColor: UIColor {
        switch self {
        case .studio: .systemBlue
        case .progetti: .systemOrange
        case .lavoro: .systemTeal
        case .persone: .systemPurple
        case .interessi: .systemGreen
        case .salute: .systemPink
        }
    }

    var graphName: String {
        switch self {
        case .studio: String(localized: "Studio")
        case .progetti: String(localized: "Progetti")
        case .lavoro: String(localized: "Lavoro e clienti")
        case .persone: String(localized: "Persone")
        case .interessi: String(localized: "Interessi")
        case .salute: String(localized: "Salute e allenamento")
        }
    }
}
