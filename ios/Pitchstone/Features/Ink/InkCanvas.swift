import PencilKit
import PitchstoneSync
import SwiftUI
import UIKit

/// Tela PencilKit con la palette di sistema: penna, evidenziatore, gomma, lazo, righello.
/// La pagina ha proporzioni A4 e scorre in verticale; lo sfondo scorre con i tratti.
struct InkCanvas: UIViewRepresentable {
    let initialDrawing: PKDrawing
    let background: InkBackground
    /// Con la Pencil collegata il dito scorre la pagina; qui si può far disegnare anche il dito.
    let fingerDraws: Bool
    let onChange: (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeUIView(context: Context) -> PageCanvasView {
        let canvas = PageCanvasView()
        canvas.drawing = initialDrawing
        canvas.delegate = context.coordinator
        canvas.backgroundColor = .systemBackground
        canvas.isOpaque = true
        canvas.alwaysBounceVertical = true
        canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        canvas.pageBackground.style = background
        canvas.tool = PKInkingTool(.pen, color: .label, width: 3)

        let picker = PKToolPicker()
        picker.addObserver(canvas)
        picker.setVisible(true, forFirstResponder: canvas)
        context.coordinator.toolPicker = picker
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ canvas: PageCanvasView, context: Context) {
        context.coordinator.onChange = onChange
        canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        if canvas.pageBackground.style != background {
            canvas.pageBackground.style = background
        }
    }

    static func dismantleUIView(_ canvas: PageCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker?.setVisible(false, forFirstResponder: canvas)
        coordinator.toolPicker?.removeObserver(canvas)
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onChange: (PKDrawing) -> Void
        var toolPicker: PKToolPicker?

        init(onChange: @escaping (PKDrawing) -> Void) {
            self.onChange = onChange
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onChange(canvasView.drawing)
        }
    }
}

/// PKCanvasView con pagina A4 e sfondo a righe o quadretti sotto i tratti.
final class PageCanvasView: PKCanvasView {
    let pageBackground = PageBackgroundView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        pageBackground.isUserInteractionEnabled = false
        insertSubview(pageBackground, at: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) non supportato")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        // Altezza A4, o più se i tratti vanno oltre (per esempio su un iPad più largo).
        // Un disegno vuoto ha bounds nulli (coordinate infinite): non vanno usati.
        let inkBottom = drawing.strokes.isEmpty ? 0 : drawing.bounds.maxY
        let height = max(width * 1.414, inkBottom + 200)
        if contentSize != CGSize(width: width, height: height) {
            contentSize = CGSize(width: width, height: height)
        }
        pageBackground.frame = CGRect(x: 0, y: 0, width: width, height: height)
        sendSubviewToBack(pageBackground)
    }
}

/// Righe o quadretti, nel colore dei separatori di sistema (si adatta al tema scuro).
final class PageBackgroundView: UIView {
    var style: InkBackground = .blank {
        didSet { setNeedsDisplay() }
    }

    static let lineSpacing: CGFloat = 32
    static let gridSpacing: CGFloat = 24

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) non supportato")
    }

    override func draw(_ rect: CGRect) {
        guard style != .blank, let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(UIColor.separator.cgColor)
        context.setLineWidth(1 / max(traitCollection.displayScale, 1))
        switch style {
        case .lines:
            var y = Self.lineSpacing * 2
            while y < bounds.height {
                if y >= rect.minY - 1 && y <= rect.maxY + 1 {
                    context.move(to: CGPoint(x: rect.minX, y: y))
                    context.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                y += Self.lineSpacing
            }
        case .grid:
            var x = (rect.minX / Self.gridSpacing).rounded(.down) * Self.gridSpacing
            while x <= rect.maxX {
                context.move(to: CGPoint(x: x, y: rect.minY))
                context.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += Self.gridSpacing
            }
            var y = (rect.minY / Self.gridSpacing).rounded(.down) * Self.gridSpacing
            while y <= rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += Self.gridSpacing
            }
        case .blank:
            break
        }
        context.strokePath()
    }
}
