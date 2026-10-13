import PitchstoneSync
import SwiftUI
import UniformTypeIdentifiers

/// Allegati di un nodo: PDF e immagini. Un PDF si apre nel lettore con le annotazioni.
struct AttachmentsView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.dismiss) private var dismiss
    let nodeID: UUID
    @State private var choosing = false
    @State private var opened: AttachmentRecord?

    var body: some View {
        NavigationStack {
            let attachments = notes.attachments(of: nodeID)
            List {
                ForEach(attachments) { attachment in
                    Button {
                        opened = attachment
                    } label: {
                        AttachmentRow(attachment: attachment)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            notes.trashAttachment(attachment.id)
                        } label: {
                            Label("Cestino", systemImage: "trash")
                        }
                    }
                }
            }
            .overlay {
                if attachments.isEmpty {
                    ContentUnavailableView {
                        Label("Nessun allegato", systemImage: "paperclip")
                    } description: {
                        Text("Aggiungi un PDF o un'immagine: con la sync attiva va anche nel tuo spazio privato su Supabase.")
                    } actions: {
                        Button("Aggiungi") { choosing = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Allegati")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fine") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        choosing = true
                    } label: {
                        Label("Aggiungi", systemImage: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    do {
                        try notes.attach(fileAt: url, to: nodeID)
                    } catch {
                        notes.errorMessage = error.localizedDescription
                    }
                }
            }
            .fullScreenCover(item: $opened) { attachment in
                AttachmentReaderView(attachment: attachment)
            }
        }
    }
}

struct AttachmentRow: View {
    let attachment: AttachmentRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "photo")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName).lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var details: String {
        var parts = [ByteCountFormatter.string(fromByteCount: Int64(attachment.sizeBytes), countStyle: .file)]
        if let pages = attachment.pageCount { parts.append(String(localized: "\(pages) pagine")) }
        if attachment.partCount > 1 { parts.append(String(localized: "\(attachment.partCount) parti")) }
        return parts.joined(separator: " · ")
    }
}
