import Foundation
import PencilKit
import PitchstoneStore
import PitchstoneSync
import UIKit

/// Ponte tra PencilKit e il formato portabile PSINK1 (ADR 0015), che anche la PWA del PC
/// legge e scrive. Le pagine del nodo si salvano in PSINK1; si leggono sia PSINK1 sia i
/// PKDrawing salvati prima. Le annotazioni sui PDF restano PKDrawing (`InkCodec`).
/// Senza isolamento: lo usa anche l'OCR della scrittura a mano, fuori dal thread principale.
enum InkPortable {
    /// Un disegno pronto per una tela larga `canvasWidth` punti, e la larghezza di pagina
    /// in cui stanno le sue coordinate (da usare al salvataggio).
    struct Loaded {
        let drawing: PKDrawing
        let pageWidth: CGFloat
    }

    /// PSINK1 si scala sulla larghezza della tela: la pagina occupa la stessa porzione
    /// su ogni schermo. Un PKDrawing resta in punti com'è.
    static func load(_ data: Data, canvasWidth: CGFloat) throws -> Loaded {
        switch PortableInk.format(of: data) {
        case .empty:
            return Loaded(drawing: PKDrawing(), pageWidth: canvasWidth)
        case .other:
            let drawing = try InkCodec.drawing(from: data)
            // Un disegno nato su uno schermo più largo non va tagliato sul PC.
            let inkRight = drawing.strokes.isEmpty ? 0 : drawing.bounds.maxX
            return Loaded(drawing: drawing, pageWidth: max(canvasWidth, inkRight))
        case .portable:
            let page = try PortableInk.decode(data)
            let target = canvasWidth > 0 ? canvasWidth : CGFloat(page.width)
            return Loaded(drawing: drawing(from: page, scale: target / CGFloat(page.width)), pageWidth: target)
        }
    }

    /// Byte PSINK1 di un disegno le cui coordinate stanno in una pagina larga `pageWidth`.
    /// Un tratto con maschera (gomma pixel) in PSINK1 tornerebbe intero: in quel caso la
    /// pagina resta PKDrawing, modificabile solo sull'iPad, e nessun tratto cambia.
    static func data(from drawing: PKDrawing, pageWidth: CGFloat) -> Data {
        if drawing.strokes.contains(where: { $0.mask != nil }) { return InkCodec.data(from: drawing) }
        let strokes = drawing.strokes.compactMap(portableStroke)
        guard !strokes.isEmpty else { return Data() }
        let width = Double(pageWidth > 0 ? pageWidth : CGFloat(PortableInk.defaultPageWidth))
        return PortableInk(width: width, height: PortableInk.pageHeight(width: width, strokes: strokes), strokes: strokes).encoded()
    }

    // MARK: PSINK1 → PencilKit

    static func drawing(from page: PortableInk, scale: CGFloat) -> PKDrawing {
        PKDrawing(strokes: page.strokes.compactMap { pkStroke($0, scale: scale) })
    }

    static func pkStroke(_ stroke: PortableInk.Stroke, scale: CGFloat) -> PKStroke? {
        guard !stroke.points.isEmpty else { return nil }
        let inkType: PKInk.InkType = switch stroke.tool {
        case .pen: .pen
        case .marker: .marker
        case .pencil: .pencil
        }
        let rgba = PortableInk.components(ofColor: stroke.color)
        let color = UIColor(red: CGFloat(rgba.red), green: CGFloat(rgba.green), blue: CGFloat(rgba.blue), alpha: CGFloat(rgba.alpha))
        var points = stroke.points.map { p -> PKStrokePoint in
            let size = max(0.1, CGFloat(PortableInk.width(of: stroke, atPressure: p.pressure)) * scale)
            return PKStrokePoint(
                location: CGPoint(x: CGFloat(p.x) * scale, y: CGFloat(p.y) * scale),
                timeOffset: p.time, size: CGSize(width: size, height: size),
                opacity: 1, force: CGFloat(p.pressure), azimuth: 0, altitude: .pi / 2)
        }
        // Un punto solo (un puntino del PC): PencilKit vuole almeno due punti per disegnarlo.
        if points.count == 1, let only = points.first {
            points.append(PKStrokePoint(
                location: only.location, timeOffset: only.timeOffset + 0.001, size: only.size,
                opacity: only.opacity, force: only.force, azimuth: only.azimuth, altitude: only.altitude))
        }
        return PKStroke(ink: PKInk(inkType, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    // MARK: PencilKit → PSINK1

    static func portableStroke(_ stroke: PKStroke) -> PortableInk.Stroke? {
        let controlPoints = Array(stroke.path)
        guard !controlPoints.isEmpty else { return nil }
        let tool: PortableInk.Tool = switch stroke.ink.inkType {
        case .marker: .marker
        case .pencil: .pencil
        // Penna, e gli inchiostri che il PC non ha (monoline, stilografica, acquerello, pastello).
        default: .pen
        }
        // Il lazo sposta e ridimensiona i tratti con una trasformazione: si applica ai punti.
        let transform = stroke.transform
        let transformScale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
        let sizes = controlPoints.map { Double(max($0.size.width, $0.size.height) * transformScale) }
        let width = max(0.1, sizes.reduce(0, +) / Double(sizes.count))
        let points = zip(controlPoints, sizes).map { point, size in
            let location = point.location.applying(transform)
            return PortableInk.Point(
                x: Double(location.x), y: Double(location.y),
                pressure: tool == .marker ? 0.5 : PortableInk.pressure(forSize: size, nominalWidth: width),
                time: point.timeOffset)
        }
        return PortableInk.Stroke(tool: tool, color: hexColor(stroke.ink.color), width: width, points: points)
    }

    /// Colore nell'aspetto chiaro, come lo salva PencilKit (in tema scuro la tela lo adatta da sola).
    static func hexColor(_ color: UIColor) -> String {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "#000000ff" }
        return PortableInk.hexColor(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    }
}
