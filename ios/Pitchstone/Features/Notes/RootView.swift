import PitchstoneSync
import SwiftUI
import UniformTypeIdentifiers

/// Elenco dei nodi a sinistra, nodo aperto a destra.
struct RootView: View {
    @Environment(NotesModel.self) private var notes
    @State private var selection: UUID?
    @State private var showingTrash = false
    @State private var showingSettings = false
    @State private var showingImport = false
    @State private var importingDocuments = false
    @State private var showingGraph = false
    @State private var graphState = GraphState()
    /// Nodo aperto dal grafo, in un foglio sopra il grafo.
    @State private var graphOpen: GraphOpen?

    struct GraphOpen: Identifiable {
        var id: UUID
        var editing: Bool
    }

    var body: some View {
        NavigationSplitView {
            NodeListView(selection: Binding(get: { selection }, set: { value in
                selection = value
                // Scegliere un nodo dall'elenco riporta alla nota.
                if value != nil { showingGraph = false }
            }))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Picker("Vista", selection: $showingGraph) {
                            Label("Elenco", systemImage: "doc.text").tag(false)
                            Label("Grafo", systemImage: "circle.hexagongrid").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelStyle(.iconOnly)
                    }
                }
                // Barra in fondo all'elenco: la bottomBar della sidebar non è supportata da UIKit.
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Button { showingTrash = true } label: {
                            Label("Cestino", systemImage: "trash")
                        }
                        .labelStyle(.iconOnly)
                        Menu {
                            Button { showingImport = true } label: {
                                Label("Vault Obsidian", systemImage: "folder")
                            }
                            Button { importingDocuments = true } label: {
                                Label("PDF e immagini", systemImage: "doc.richtext")
                            }
                        } label: {
                            Label("Importa", systemImage: "square.and.arrow.down")
                        }
                        .labelStyle(.iconOnly)
                        Spacer()
                        SyncStatusView()
                        Spacer()
                        Button { showingSettings = true } label: {
                            Label("Impostazioni", systemImage: "gearshape")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
        } detail: {
            if showingGraph {
                GraphScreen(state: graphState) { id, editing in
                    graphOpen = GraphOpen(id: id, editing: editing)
                }
            } else if let selection, let node = notes.node(selection), node.deletedAt == nil {
                NodeDetailView(nodeID: selection) { title, area in
                    self.selection = notes.openOrCreate(titled: title, area: area, from: selection)
                }
                .id(selection)
            } else {
                ContentUnavailableView {
                    Label("Nessun nodo aperto", systemImage: "square.and.pencil")
                } description: {
                    Text("Scegli un nodo dall'elenco o creane uno nuovo con ⌘N.")
                }
            }
        }
        .sheet(item: $graphOpen) { open in
            NavigationStack {
                NodeDetailView(nodeID: open.id, initialMode: open.editing ? .write : .preview) { title, area in
                    graphOpen = GraphOpen(id: notes.openOrCreate(titled: title, area: area, from: open.id), editing: false)
                }
                .id(open.id)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fine") { graphOpen = nil }
                    }
                }
            }
        }
        .background {
            // ⌘G passa dall'elenco al grafo e viceversa.
            Button("Grafo") { showingGraph.toggle() }
                .keyboardShortcut("g", modifiers: .command)
                .hidden()
        }
        .sheet(isPresented: $showingTrash) {
            TrashView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingImport) {
            ImportVaultView()
        }
        // Ogni PDF o immagine diventa un nodo con il nome del file.
        .fileImporter(isPresented: $importingDocuments, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var first: UUID?
            for url in urls {
                do {
                    let id = try notes.importDocument(at: url, area: .studio)
                    first = first ?? id
                } catch {
                    notes.errorMessage = error.localizedDescription
                }
            }
            if let first {
                showingGraph = false
                selection = first
            }
        }
        .alert(
            "Operazione non riuscita",
            isPresented: Binding(get: { notes.errorMessage != nil }, set: { if !$0 { notes.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notes.errorMessage ?? "")
        }
    }
}

private struct SyncStatusView: View {
    @Environment(NotesModel.self) private var notes

    var body: some View {
        switch notes.syncStatus {
        case .notConfigured:
            Label("Solo locale", systemImage: "icloud.slash")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .syncing:
            ProgressView()
        case .idle(let last):
            Button {
                Task { await notes.syncNow() }
            } label: {
                if let last {
                    Label {
                        Text(last, style: .relative)
                    } icon: {
                        Image(systemName: "checkmark.icloud")
                    }
                } else {
                    Label("Sincronizza", systemImage: "arrow.triangle.2.circlepath.icloud")
                }
            }
            .font(.caption)
        case .failed:
            Button {
                Task { await notes.syncNow() }
            } label: {
                Label("Offline, riprova", systemImage: "exclamationmark.icloud")
            }
            .font(.caption)
            .tint(.orange)
        }
    }
}
