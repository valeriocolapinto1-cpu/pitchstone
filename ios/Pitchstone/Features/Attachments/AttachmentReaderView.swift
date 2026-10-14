import PDFKit
import PencilKit
import PitchstoneStore
import PitchstoneSync
import SwiftUI
import UIKit

/// Lettore di un allegato. PDF: pagine continue, annotazioni con la Pencil salvate
/// per pagina, nodo nuovo dal testo selezionato. Immagine: a tutto schermo.
struct AttachmentReaderView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fingerDraws") private var fingerDraws = false
    let attachment: AttachmentRecord
    /// Pagina da mostrare all'apertura (da una citazione), da 0.
    var initialPage: Int?

    @State private var fileURL: URL?
    @State private var failure: String?
    @State private var annotating = false
    @State private var selection: (text: String, page: Int)?
    @State private var createdNode: String?

    var body: some View {
        NavigationStack {
            Group {
                if let fileURL {
                    if attachment.kind == .pdf {
                        PDFReader(url: fileURL, attachment: attachment, initialPage: initialPage, annotating: annotating, fingerDraws: fingerDraws) {
                            selection = $0
                        }
                        .ignoresSafeArea(edges: .bottom)
                    } else if let image = UIImage(contentsOfFile: fileURL.path) {
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                    } else {
                        ContentUnavailableView("Immagine non leggibile", systemImage: "photo")
                    }
                } else if let failure {
                    ContentUnavailableView {
                        Label("File non disponibile", systemImage: "icloud.slash")
                    } description: {
                        Text(failure)
                    }
                } else {
                    ProgressView("Scaricamento…")
                }
            }
            .navigationTitle(attachment.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fine") { dismiss() }
                }
                if attachment.kind == .pdf, fileURL != nil {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            guard let selection else { return }
                            notes.createNode(fromQuote: selection.text, attachment: attachment, page: selection.page)
                            createdNode = String(selection.text.prefix(60))
                        } label: {
                            Label("Nodo dalla selezione", systemImage: "circle.hexagongrid.badge.plus")
                        }
                        .disabled(selection == nil || attachment.nodeID == nil)
                        Toggle(isOn: $annotating) {
                            Label("Annota", systemImage: "pencil.tip.crop.circle")
                        }
                        .disabled(attachment.nodeID == nil)
                    }
                }
            }
            .alert("Nodo creato", isPresented: Binding(get: { createdNode != nil }, set: { if !$0 { createdNode = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Il testo selezionato è in un nodo nuovo, collegato a questo PDF.")
            }
        }
        .task {
            do {
                fileURL = try await notes.localFile(for: attachment)
            } catch AttachmentError.missingLocalFile {
                failure = String(localized: "Il file è su un altro dispositivo: configura la sync per scaricarlo.")
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// PDFView con uno strato PencilKit per ogni pagina (PDFPageOverlayViewProvider).
private struct PDFReader: UIViewRepresentable {
    @Environment(NotesModel.self) private var notes
    let url: URL
    let attachment: AttachmentRecord
    let initialPage: Int?
    let annotating: Bool
    let fingerDraws: Bool
    let onSelection: ((text: String, page: Int)?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(notes: notes, attachment: attachment) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageOverlayViewProvider = context.coordinator
        view.document = PDFDocument(url: url)
        if let initialPage {
            // Dopo la prima impaginazione, o PDFView torna alla prima pagina.
            DispatchQueue.main.async {
                if let page = view.document?.page(at: initialPage) { view.go(to: page) }
            }
        }
        context.coordinator.view = view
        context.coordinator.onSelection = onSelection
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.selectionChanged),
            name: .PDFViewSelectionChanged, object: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onSelection = onSelection
        // In modalità annotazione le pagine ricevono i tocchi; altrimenti si scorre e si seleziona.
        view.isInMarkupMode = annotating
        context.coordinator.configure(annotating: annotating, fingerDraws: fingerDraws)
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.saveAll()
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider, @preconcurrency PKCanvasViewDelegate {
        let notes: NotesModel
        let attachment: AttachmentRecord
        weak var view: PDFView?
        var onSelection: ((text: String, page: Int)?) -> Void = { _ in }

        /// Tela di ogni pagina visibile, con lo strato in cui salva e i byte da cui è partita.
        private struct PageCanvas {
            var canvas: PKCanvasView
            var layer: UUID?
            var loaded: Data
            var dirty = false
        }

        private var canvases: [Int: PageCanvas] = [:]
        private var annotating = false
        private var fingerDraws = false
        private var pendingSave: Task<Void, Never>?

        init(notes: NotesModel, attachment: AttachmentRecord) {
            self.notes = notes
            self.attachment = attachment
        }

        func configure(annotating: Bool, fingerDraws: Bool) {
            self.annotating = annotating
            self.fingerDraws = fingerDraws
            for entry in canvases.values { apply(to: entry.canvas) }
            if !annotating { saveAll() }
        }

        private func apply(to canvas: PKCanvasView) {
            canvas.isUserInteractionEnabled = annotating
            canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        }

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            guard let index = view.document?.index(for: page) else { return nil }
            if let existing = canvases[index] { return existing.canvas }
            let layers = notes.pdfAnnotationLayers(attachment.id, page: index)
            var drawing = PKDrawing()
            for layer in layers {
                if let other = try? InkCodec.drawing(from: layer.inkData) { drawing.append(other) }
            }
            let layerID = layers.first?.id
            var loaded = layers.first?.inkData ?? Data()
            // Più strati (dopo un conflitto): si uniscono nel primo, nessun tratto si perde.
            // Fuori dal ciclo di disegno di PDFKit; se l'unione fallisse, il salvataggio
            // successivo vedrebbe lo strato diverso e userebbe uno strato nuovo.
            if layers.count > 1 {
                let merged = InkCodec.data(from: drawing)
                loaded = merged
                let notes = notes
                DispatchQueue.main.async { _ = notes.mergePDFLayers(layers, into: merged) }
            }
            let canvas = PKCanvasView()
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isScrollEnabled = false
            canvas.drawing = drawing
            canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 2)
            canvas.delegate = self
            apply(to: canvas)
            canvases[index] = PageCanvas(canvas: canvas, layer: layerID, loaded: loaded)
            return canvas
        }

        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            guard let index = pdfView.document?.index(for: page) else { return }
            save(page: index)
            canvases[index] = nil
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard let index = canvases.first(where: { $0.value.canvas === canvasView })?.key else { return }
            canvases[index]?.dirty = true
            pendingSave?.cancel()
            pendingSave = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.saveAll()
            }
        }

        func saveAll() {
            for index in canvases.keys { save(page: index) }
        }

        private func save(page index: Int) {
            guard var entry = canvases[index], entry.dirty else { return }
            let data = InkCodec.data(from: entry.canvas.drawing)
            if let layer = notes.savePDFAnnotation(
                data, attachment: attachment, page: index, layer: entry.layer, loadedFrom: entry.loaded) {
                entry.layer = layer
                entry.loaded = data
                entry.dirty = false
                canvases[index] = entry
            }
        }

        @objc func selectionChanged() {
            guard let selection = view?.currentSelection, let text = selection.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let page = selection.pages.first, let index = view?.document?.index(for: page)
            else {
                onSelection(nil)
                return
            }
            onSelection((text, index))
        }
    }
}
