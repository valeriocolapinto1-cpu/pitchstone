import CoreGraphics
import Foundation
import PencilKit
import PitchstoneStore
import PitchstoneSync
import UIKit

/// Dati dimostrativi per gli screenshot automatici (argomento `-demoData`):
/// nodi collegati in tutte le aree, un nodo di salute e una pagina a penna.
extension NotesModel {
    func loadDemoData() {
        guard activeNodes.isEmpty else { return }
        let notes: [(String, NodeType, Area, [String], String)] = [
            ("Analisi 1", .exam, .studio, ["esame"], """
            # Analisi 1
            Esame il 20 gennaio. Programma:
            - [[Limiti]] e [[Funzioni continue]]
            - [[Derivata]] e [[Serie di Taylor]]
            - [[Integrale]] e [[Teorema fondamentale del calcolo]]

            Docente: [[Prof.ssa Bianchi]].
            """),
            ("Limiti", .concept, .studio, ["analisi"], """
            Il **limite** descrive il comportamento di una funzione vicino a un punto.
            Base per [[Derivata]] e [[Funzioni continue]].
            """),
            ("Funzioni continue", .concept, .studio, ["analisi"], "Una funzione è continua se il [[Limiti|limite]] coincide con il valore. Vedi [[Teorema fondamentale del calcolo]]."),
            ("Derivata", .concept, .studio, ["analisi", "teorema"], """
            # Derivata
            La derivata misura la **variazione istantanea** di una funzione: è il [[Limiti|limite]] del rapporto incrementale.

            ## Regole
            | Funzione | Derivata |
            |---|---|
            | xⁿ | n·xⁿ⁻¹ |
            | sin x | cos x |
            | eˣ | eˣ |

            ## Collegamenti
            - Approssimazione con la [[Serie di Taylor]]
            - Operazione inversa: [[Integrale]]
            - In fisica: velocità in [[Cinematica]]

            > Da ripassare: teorema di Lagrange.
            """),
            ("Integrale", .concept, .studio, ["analisi"], "L'integrale definito misura l'area. Legato alla [[Derivata]] dal [[Teorema fondamentale del calcolo]]. Usato per il lavoro in [[Energia]]."),
            ("Teorema fondamentale del calcolo", .concept, .studio, ["teorema"], "Collega [[Derivata]] e [[Integrale]]."),
            ("Serie di Taylor", .concept, .studio, ["analisi"], "Approssima una funzione con un polinomio costruito dalle derivate. Vedi [[Derivata]]."),
            ("Fisica 1", .exam, .studio, ["esame"], "Programma: [[Cinematica]], [[Dinamica]], [[Energia]]. Serve [[Analisi 1]]."),
            ("Cinematica", .concept, .studio, ["fisica"], "Velocità e accelerazione come [[Derivata|derivate]] della posizione."),
            ("Dinamica", .concept, .studio, ["fisica"], "F = m·a. Si collega a [[Cinematica]] ed [[Energia]]."),
            ("Energia", .concept, .studio, ["fisica"], "Lavoro come [[Integrale]] della forza. Conservazione dell'energia in [[Dinamica]]."),
            ("Algebra lineare", .exam, .studio, ["esame"], "Programma: [[Matrici]], [[Spazi vettoriali]], [[Autovalori]]."),
            ("Matrici", .concept, .studio, ["algebra"], "Prodotto, determinante, inversa. Vedi [[Autovalori]]."),
            ("Spazi vettoriali", .concept, .studio, ["algebra"], "Basi e dimensione. Le [[Matrici]] rappresentano applicazioni lineari."),
            ("Autovalori", .concept, .studio, ["algebra"], "Av = λv. Servono per diagonalizzare le [[Matrici]]."),
            ("Pitchstone", .project, .progetti, ["app"], """
            Secondo cervello su iPad.
            - [[Grafo delle note]]
            - [[Sync offline]]
            - [[Quiz FSRS]] basati sulla [[Ripetizione spaziata]]
            """),
            ("Grafo delle note", .project, .progetti, ["app"], "Layout a forze, cluster per area. Parte di [[Pitchstone]]."),
            ("Sync offline", .project, .progetti, ["app"], "Outbox e pull incrementale per [[Pitchstone]]."),
            ("Quiz FSRS", .idea, .progetti, ["app"], "Domande generate dagli appunti di [[Analisi 1]] e [[Fisica 1]]."),
            ("Riunione settimanale", .concept, .lavoro, ["lavoro"], "Ogni lunedì con [[Marco]]. Punto fisso: [[Report trimestrale]]."),
            ("Report trimestrale", .project, .lavoro, ["lavoro"], "Da consegnare a fine mese."),
            ("Prof.ssa Bianchi", .person, .persone, [], "Docente di [[Analisi 1]]. Ricevimento il martedì."),
            ("Marco", .person, .persone, [], "Collega. Vedi [[Riunione settimanale]]."),
            ("Fotografia", .concept, .interessi, ["hobby"], "Esposizione e composizione. Foto del cielo per [[Astronomia]]."),
            ("Astronomia", .concept, .interessi, ["hobby"], "Orbite e gravità: c'entra la [[Dinamica]]."),
            ("Ripetizione spaziata", .idea, .interessi, ["studio"], "Ripassare a intervalli crescenti. Base dei [[Quiz FSRS]]."),
            ("Visita annuale", .health, .salute, [], "Controllo di routine. Resta solo su questo iPad."),
        ]
        // Prima tutti i nodi, poi i testi: così ogni [[link]] trova il suo nodo.
        let ids = notes.map { createNode(type: $0.1, title: $0.0, area: $0.2).id }
        for (id, note) in zip(ids, notes) {
            update(id) {
                $0.bodyMD = note.4
                $0.tags = note.3
            }
        }
        if let index = notes.firstIndex(where: { $0.0 == "Derivata" }) {
            addDemoDrawing(to: ids[index])
        }
    }

    /// Una pagina a righe con un grafico a mano: assi, una curva e la sua tangente.
    private func addDemoDrawing(to nodeID: UUID) {
        guard let page = createInkPage(in: nodeID, background: .lines) else { return }
        func stroke(_ points: [CGPoint], color: UIColor = .label, width: CGFloat = 3) -> PKStroke {
            let path = points.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: width, height: width),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: path, creationDate: Date()))
        }
        let origin = CGPoint(x: 120, y: 520)
        let axisX = stroke([origin, CGPoint(x: 620, y: 520)])
        let axisY = stroke([origin, CGPoint(x: 120, y: 140)])
        let curve = stroke((0...60).map { i in
            let x = Double(i) / 60 * 4.5
            return CGPoint(x: origin.x + x * 100, y: origin.y - x * x * 17)
        }, color: .systemBlue, width: 4)
        // Tangente in x = 2: pendenza 2·x = 4 (in unità del disegno 4·17/100).
        let slope = 2 * 2 * 17.0 / 100
        let tangent = stroke([
            CGPoint(x: origin.x + 100, y: origin.y - 68 + slope * 100),
            CGPoint(x: origin.x + 340, y: origin.y - 68 - slope * 140),
        ], color: .systemRed, width: 3)
        let drawing = PKDrawing(strokes: [axisX, axisY, curve, tangent])
        updateInkPage(page.id) { $0.inkData = InkCodec.data(from: drawing) }
    }
}
