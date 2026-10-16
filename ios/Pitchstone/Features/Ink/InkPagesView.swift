import PencilKit
import PitchstoneStore
import PitchstoneSync
import SwiftUI

/// Pagine di disegno di un nodo: scelta della pagina, sfondo, nuova pagina, cestino.
struct InkPagesView: View {
    @Environment(NotesModel.self) private var notes
    let nodeID: UUID
    @State private var selectedPage: UUID?
    @State private var confirmingDelete = false
    @AppStorage("fingerDraws") private var fingerDraws = false
    /// Annulla e ripristina della pagina aperta.
    @State private var history = InkHistory()

    var body: some View {
        let pages = notes.inkPages(of: nodeID)
        VStack(spacing: 0) {
            toolbar(pages)
            Divider()
            if let page = pages.first(where: { $0.id == selectedPage }) ?? pages.first {
                InkPageView(page: page, fingerDraws: fingerDraws, history: history) { moved in
                    // I tratti sono finiti in una nuova pagina (conflitto con una sync): la si apre.
                    selectedPage = moved
                }
                // Ogni pagina ha la sua tela e il suo stato.
                .id(page.id)
            } else {
                ContentUnavailableView {
                    Label("Nessuna pagina", systemImage: "pencil.and.scribble")
                } description: {
                    Text("Aggiungi una pagina per scrivere con la Pencil.")
                } actions: {
                    Button("Nuova pagina") { addPage(.lines) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func toolbar(_ pages: [InkPageRecord]) -> some View {
        let current = pages.first(where: { $0.id == selectedPage }) ?? pages.first
        return HStack(spacing: 12) {
            if !pages.isEmpty {
                Picker("Pagina", selection: Binding(get: { current?.id }, set: { selectedPage = $0 })) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        Text("Pagina \(index + 1)").tag(Optional(page.id))
                    }
                }
                .pickerStyle(.menu)
            }
            Menu {
                ForEach(InkBackground.allCases, id: \.self) { background in
                    Button { addPage(background) } label: {
                        Label(background.label, systemImage: background.symbol)
                    }
                }
            } label: {
                Label("Nuova pagina", systemImage: "plus.rectangle.portrait")
            }
            if let current {
                Menu {
                    Picker("Sfondo", selection: Binding(get: { current.background }, set: { value in
                        notes.updateInkPage(current.id) { $0.background = value }
                    })) {
                        ForEach(InkBackground.allCases, id: \.self) { background in
                            Label(background.label, systemImage: background.symbol).tag(background)
                        }
                    }
                } label: {
                    Label("Sfondo", systemImage: current.background.symbol)
                }
            }
            Spacer()
            if current != nil {
                Button { history.undo() } label: {
                    Label("Annulla", systemImage: "arrow.uturn.backward")
                }
                .disabled(!history.canUndo)
                Button { history.redo() } label: {
                    Label("Ripristina", systemImage: "arrow.uturn.forward")
                }
                .disabled(!history.canRedo)
            }
            Toggle(isOn: $fingerDraws) {
                Label("Disegna con il dito", systemImage: "hand.draw")
            }
            .toggleStyle(.button)
            let trashed = notes.trashedInkPages(of: nodeID)
            if !trashed.isEmpty {
                Menu {
                    ForEach(trashed) { page in
                        Button {
                            notes.restoreInkPage(page.id)
                            selectedPage = page.id
                        } label: {
                            Text("Pagina eliminata \(page.deletedAt ?? page.updatedAt, format: .relative(presentation: .named))")
                        }
                    }
                } label: {
                    Label("Pagine eliminate", systemImage: "arrow.uturn.backward.circle")
                }
            }
            if current != nil {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Elimina pagina", systemImage: "trash")
                }
                .confirmationDialog("Eliminare questa pagina?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Elimina pagina", role: .destructive) {
                        if let current {
                            notes.trashInkPage(current.id)
                            selectedPage = nil
                        }
                    }
                } message: {
                    Text("La pagina resta nel cestino per 30 giorni e si può ripristinare.")
                }
            }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func addPage(_ background: InkBackground) {
        if let page = notes.createInkPage(in: nodeID, background: background) {
            selectedPage = page.id
        }
    }
}

/// Una pagina: tela PencilKit con salvataggio un secondo dopo l'ultimo tratto.
/// Se la pagina cambia dall'esterno (sync, conflitto) e non ci sono tratti da
/// salvare, la tela si ricarica.
private struct InkPageView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.scenePhase) private var scenePhase
    let page: InkPageRecord
    let fingerDraws: Bool
    let history: InkHistory
    let onMoved: (UUID) -> Void

    /// Disegno decodificato una volta sola, non a ogni tratto.
    @State private var initial: PKDrawing?
    @State private var canvasToken = UUID()
    @State private var pending: PKDrawing?
    @State private var edits = 0
    /// Ultimi byte caricati o salvati da questa vista.
    @State private var lastData: Data?
    @State private var loadError = false

    var body: some View {
        Group {
            if let initial {
                InkCanvas(initialDrawing: initial, background: page.background, fingerDraws: fingerDraws, history: history) { drawing in
                    pending = drawing
                    edits += 1
                }
                .id(canvasToken)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            // Una nuova comparsa (per esempio un cambio di layout) non deve perdere i tratti in sospeso.
            if initial == nil { reload() }
        }
        .task(id: edits) {
            guard edits > 0 else { return }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            save()
        }
        .onChange(of: page.inkData) { _, data in
            // Byte diversi da quelli che questa vista conosce: sync o conflitto.
            // Si ricarica solo se non ci sono tratti da salvare.
            guard pending == nil, data != lastData else { return }
            reload()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { save() }
        }
        .onDisappear(perform: save)
        .alert("Disegno non leggibile", isPresented: $loadError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("I dati di questa pagina non sono un disegno valido. La pagina resta vuota e i dati originali restano finché non disegni.")
        }
    }

    private func reload() {
        do {
            initial = try InkCodec.drawing(from: page.inkData)
        } catch {
            initial = PKDrawing()
            loadError = true
        }
        lastData = page.inkData
        canvasToken = UUID()
    }

    private func save() {
        guard let drawing = pending, let loaded = lastData else { return }
        pending = nil
        let data = InkCodec.data(from: drawing)
        guard data != loaded else { return }
        // Il repository confronta con i byte da cui è partita la tela: se una sync li ha
        // cambiati nel frattempo, i tratti vanno in una nuova pagina invece di sovrascriverli.
        guard let saved = notes.saveDrawing(data, to: page.id, loadedFrom: loaded) else { return }
        if saved.id == page.id {
            lastData = data
        } else {
            onMoved(saved.id)
        }
    }
}

extension InkBackground {
    var label: LocalizedStringKey {
        switch self {
        case .blank: "Bianco"
        case .lines: "A righe"
        case .grid: "A quadretti"
        }
    }

    var symbol: String {
        switch self {
        case .blank: "rectangle.portrait"
        case .lines: "line.3.horizontal"
        case .grid: "grid"
        }
    }
}
