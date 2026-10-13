import PencilKit
import PitchstoneStore
import PitchstoneSync
import SwiftUI

/// Pagine di disegno di un nodo: scelta della pagina, sfondo, nuova pagina, cestino.
struct InkPagesView: View {
    @Environment(NotesModel.self) private var notes
    let nodeID: UUID
    @State private var selectedPage: UUID?
    @AppStorage("fingerDraws") private var fingerDraws = false

    var body: some View {
        let pages = notes.inkPages(of: nodeID)
        VStack(spacing: 0) {
            toolbar(pages)
            Divider()
            if let page = pages.first(where: { $0.id == selectedPage }) ?? pages.first {
                InkPageView(page: page, fingerDraws: fingerDraws)
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
            Toggle(isOn: $fingerDraws) {
                Label("Disegna con il dito", systemImage: "hand.draw")
            }
            .toggleStyle(.button)
            if let current {
                Button(role: .destructive) {
                    notes.trashInkPage(current.id)
                    selectedPage = nil
                } label: {
                    Label("Elimina pagina", systemImage: "trash")
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
                InkCanvas(initialDrawing: initial, background: page.background, fingerDraws: fingerDraws) { drawing in
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
        .onAppear(perform: reload)
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
        guard let drawing = pending else { return }
        pending = nil
        let data = InkCodec.data(from: drawing)
        guard data != lastData else { return }
        lastData = data
        notes.updateInkPage(page.id) { $0.inkData = data }
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
