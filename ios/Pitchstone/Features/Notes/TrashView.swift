import PitchstoneSync
import SwiftUI

/// Cestino: i nodi restano 30 giorni, poi vengono eliminati definitivamente.
struct TrashView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(notes.trashedNodes) { node in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.title.isEmpty ? String(localized: "Senza titolo") : node.title)
                            Text("Eliminato tra \(notes.daysLeftInTrash(node)) giorni")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Ripristina") { notes.restore(node.id) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .overlay {
                if notes.trashedNodes.isEmpty {
                    ContentUnavailableView("Il cestino è vuoto", systemImage: "trash")
                }
            }
            .navigationTitle("Cestino")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }
}
