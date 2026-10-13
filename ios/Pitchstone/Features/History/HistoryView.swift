import PitchstoneNotes
import PitchstoneSync
import SwiftUI

/// Storico delle versioni di un nodo, con differenze e ripristino.
struct HistoryView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.dismiss) private var dismiss
    let nodeID: UUID

    var body: some View {
        NavigationStack {
            let versions = Array(notes.history(of: nodeID).reversed())
            List {
                if versions.isEmpty {
                    Text("Le versioni compaiono qui dopo la prima sincronizzazione.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                    let previous = index + 1 < versions.count ? versions[index + 1].bodyMD : ""
                    NavigationLink {
                        VersionDetailView(nodeID: nodeID, version: version, previous: previous)
                    } label: {
                        VersionRow(version: version, previous: previous, isCurrent: index == 0)
                    }
                }
            }
            .navigationTitle("Storico")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }
}

private struct VersionRow: View {
    let version: NodeVersionRecord
    let previous: String
    let isCurrent: Bool
    /// Calcolato dopo la comparsa della riga, non durante il disegno della lista.
    @State private var diff: (added: Int, removed: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Versione \(version.version)").bold()
                if isCurrent {
                    Text("attuale")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
            }
            HStack(spacing: 12) {
                Text(version.createdAt, format: .dateTime.day().month().year().hour().minute())
                Text(version.deviceID)
                if let diff {
                    Text("+\(diff.added)").foregroundStyle(.green)
                    Text("−\(diff.removed)").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .task(id: version.id) {
            diff = LineDiff.summary(LineDiff.diff(previous, version.bodyMD))
        }
    }
}

private struct VersionDetailView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.dismiss) private var dismiss
    let nodeID: UUID
    let version: NodeVersionRecord
    let previous: String
    @State private var confirming = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(LineDiff.diff(previous, version.bodyMD).enumerated()), id: \.offset) { _, line in
                    DiffLineView(line: line)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .padding()
        }
        .navigationTitle("Versione \(version.version)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Ripristina") { confirming = true }
            }
        }
        .confirmationDialog("Ripristinare questa versione?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Ripristina la versione \(version.version)") {
                notes.restoreVersion(version.version, of: nodeID)
                dismiss()
            }
        } message: {
            Text("Il testo attuale resta nello storico: il ripristino crea una nuova versione.")
        }
    }
}

private struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        switch line {
        case .same(let text):
            row(" ", text, nil)
        case .added(let text):
            row("+", text, .green)
        case .removed(let text):
            row("−", text, .red)
        }
    }

    private func row(_ sign: String, _ text: String, _ color: Color?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(sign).foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            Text(text.isEmpty ? " " : text)
                .strikethrough(color == .red)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(color.map { $0.opacity(0.12) } ?? .clear)
        .accessibilityElement(children: .combine)
    }
}
