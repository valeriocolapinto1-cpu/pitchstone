import PitchstoneSync
import SwiftUI

/// Elenco dei nodi a sinistra, nodo aperto a destra.
struct RootView: View {
    @Environment(NotesModel.self) private var notes
    @State private var selection: UUID?
    @State private var showingTrash = false
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            NodeListView(selection: $selection)
                // Barra in fondo all'elenco: la bottomBar della sidebar non è supportata da UIKit.
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Button { showingTrash = true } label: {
                            Label("Cestino", systemImage: "trash")
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
            if let selection, let node = notes.node(selection), node.deletedAt == nil {
                NodeDetailView(nodeID: selection) { title, area in
                    self.selection = notes.openOrCreate(titled: title, area: area)
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
        .sheet(isPresented: $showingTrash) {
            TrashView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
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
