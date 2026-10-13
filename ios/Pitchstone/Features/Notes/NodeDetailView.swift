import PitchstoneSync
import SwiftUI

/// Un nodo aperto: titolo, tipo, area, tag e corpo in Markdown.
/// Il testo si salva da solo dopo una breve pausa e quando si lascia il nodo.
struct NodeDetailView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.horizontalSizeClass) private var sizeClass
    let nodeID: UUID
    let onOpenNode: (String, Area) -> Void

    @State private var title = ""
    @State private var text = ""
    @State private var tags = ""
    @State private var mode: Mode = .split
    @State private var showingHistory = false
    @State private var loaded = false

    enum Mode: String, CaseIterable, Identifiable {
        case write, split, preview
        var id: Self { self }
        var label: LocalizedStringKey {
            switch self {
            case .write: "Scrivi"
            case .split: "Affiancato"
            case .preview: "Anteprima"
            }
        }
    }

    var body: some View {
        content
            .navigationTitle(title.isEmpty ? String(localized: "Senza titolo") : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showingHistory) {
                HistoryView(nodeID: nodeID)
            }
            .onAppear(perform: load)
            .onDisappear(perform: save)
            // Salvataggio automatico dopo 0,8 s senza modifiche.
            .task(id: Draft(title: title, text: text, tags: tags)) {
                guard loaded else { return }
                do {
                    try await Task.sleep(for: .milliseconds(800))
                } catch {
                    return
                }
                save()
            }
    }

    private struct Draft: Equatable {
        var title: String
        var text: String
        var tags: String
    }

    @ViewBuilder
    private var content: some View {
        if let node = notes.node(nodeID) {
            VStack(alignment: .leading, spacing: 0) {
                header(node)
                Divider()
                switch effectiveMode {
                case .write:
                    MarkdownEditor(text: $text)
                case .preview:
                    preview(node)
                case .split:
                    HStack(spacing: 0) {
                        MarkdownEditor(text: $text)
                        Divider()
                        preview(node)
                    }
                }
            }
        }
    }

    /// Su schermo stretto (Split View) l'affiancato diventa solo scrittura.
    private var effectiveMode: Mode {
        mode == .split && sizeClass == .compact ? .write : mode
    }

    private func preview(_ node: NodeRecord) -> some View {
        MarkdownPreview(text: text) { title in
            save()
            onOpenNode(title, node.area)
        }
        .frame(maxWidth: .infinity)
    }

    private func header(_ node: NodeRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Titolo", text: $title)
                .font(.title.bold())
                .submitLabel(.done)
            HStack(spacing: 12) {
                Menu {
                    Picker("Tipo", selection: typeBinding(node)) {
                        ForEach(NodeType.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                } label: {
                    Label(node.type.label, systemImage: node.type.symbol)
                }
                Menu {
                    Picker("Area", selection: areaBinding(node)) {
                        ForEach(Area.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label(node.area.label, systemImage: "square.grid.2x2")
                }
                TextField("Tag, separati da virgole", text: $tags)
                    .textInputAutocapitalization(.never)
                    .font(.callout)
                if node.isSensitive {
                    Label("Solo su questo iPad", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.pink)
                }
            }
            .font(.callout)
        }
        .padding()
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Vista", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                save()
                showingHistory = true
            } label: {
                Label("Storico", systemImage: "clock.arrow.circlepath")
            }
            Button(role: .destructive) {
                save()
                notes.trash(nodeID)
            } label: {
                Label("Sposta nel cestino", systemImage: "trash")
            }
        }
    }

    private func typeBinding(_ node: NodeRecord) -> Binding<NodeType> {
        Binding(get: { node.type }, set: { value in
            save()
            notes.update(nodeID) { $0.type = value }
        })
    }

    private func areaBinding(_ node: NodeRecord) -> Binding<Area> {
        Binding(get: { node.area }, set: { value in
            save()
            notes.update(nodeID) { $0.area = value }
        })
    }

    private func load() {
        guard let node = notes.node(nodeID) else { return }
        title = node.title
        text = node.bodyMD
        tags = node.tags.joined(separator: ", ")
        loaded = true
    }

    /// Salva solo se qualcosa è cambiato: ogni salvataggio è una modifica da sincronizzare.
    private func save() {
        guard loaded, let node = notes.node(nodeID) else { return }
        let parsedTags = Self.parseTags(tags)
        guard node.title != title || node.bodyMD != text || node.tags != parsedTags else { return }
        notes.update(nodeID) {
            $0.title = title
            $0.bodyMD = text
            $0.tags = parsedTags
        }
    }

    nonisolated static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
