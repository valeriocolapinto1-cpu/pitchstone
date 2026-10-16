import PitchstoneAI
import PitchstoneImport
import PitchstoneSync
import SwiftUI
import UniformTypeIdentifiers

/// Un nodo aperto: titolo, tipo, area, tag e corpo in Markdown.
/// Il testo si salva da solo dopo una breve pausa e quando si lascia il nodo.
struct NodeDetailView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openChat) private var openChat
    @Environment(\.openSource) private var openSource
    @Environment(StudyModel.self) private var study
    @State private var generatingQuiz = false
    @State private var exportFile: ExportFile?

    struct ExportFile {
        var document: DataFile
        var type: UTType
        var name: String
    }
    @State private var quizMessage: String?
    let nodeID: UUID
    let onOpenNode: (String, Area) -> Void

    init(nodeID: UUID, initialMode: Mode = .split, onOpenNode: @escaping (String, Area) -> Void) {
        self.nodeID = nodeID
        self.onOpenNode = onOpenNode
        _mode = State(initialValue: initialMode)
    }

    @State private var title = ""
    @State private var text = ""
    @State private var tags = ""
    @State private var mode: Mode
    @State private var showingHistory = false
    @State private var showingAttachments = false
    @State private var analysisResult: AnalysisResult?
    @State private var analyzing = false

    struct AnalysisResult: Identifiable {
        let id = UUID()
        var outcome: NotesModel.AnalysisOutcome
    }
    /// Ultimo stato salvato o caricato: si salva solo ciò che l'utente ha cambiato
    /// rispetto a qui, e si ricarica dall'archivio solo se non ci sono modifiche in sospeso.
    @State private var baseline: Draft?

    enum Mode: String, CaseIterable, Identifiable {
        case write, split, preview, ink
        var id: Self { self }
        var label: LocalizedStringKey {
            switch self {
            case .write: "Scrivi"
            case .split: "Affiancato"
            case .preview: "Anteprima"
            case .ink: "Penna"
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
            .sheet(isPresented: $showingAttachments) {
                AttachmentsView(nodeID: nodeID)
            }
            .alert("Quiz creati", isPresented: Binding(get: { quizMessage != nil }, set: { if !$0 { quizMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(quizMessage ?? "")
            }
            .fileExporter(
                isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } }),
                document: exportFile?.document, contentType: exportFile?.type ?? .data,
                defaultFilename: exportFile?.name
            ) { result in
                if case .failure(let error) = result { notes.errorMessage = error.localizedDescription }
            }
            .sheet(item: $analysisResult) { result in
                AnalysisSheet(nodeID: nodeID, outcome: result.outcome)
            }
            .onAppear(perform: load)
            .onDisappear {
                save()
                notes.flushSync()
            }
            // Ripristino dallo storico o modifica arrivata con la sync.
            .onChange(of: notes.node(nodeID)) { _, node in
                guard let node, draft == baseline else { return }
                apply(node)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    save()
                    notes.flushSync()
                }
            }
            // Salvataggio automatico dopo 0,8 s senza modifiche.
            .task(id: draft) {
                guard baseline != nil else { return }
                do {
                    try await Task.sleep(for: .milliseconds(800))
                } catch {
                    return
                }
                save()
            }
    }

    private var draft: Draft { Draft(title: title, text: text, tags: tags) }

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
                AnalysisBanners(nodeID: nodeID, beforeAction: save) { moved in
                    // Per id: un altro nodo può avere lo stesso titolo.
                    openSource(SourceRef(nodeID: moved))
                }
                Divider()
                switch effectiveMode {
                case .write:
                    MarkdownEditor(text: $text)
                case .preview:
                    preview(node)
                case .ink:
                    InkPagesView(nodeID: nodeID)
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
            // Da un nodo sensibile non si creano nodi sensibili per errore.
            onOpenNode(title, node.isSensitive ? .studio : node.area)
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
                if node.type == .exam {
                    ExamControls(node: node, beforeChange: save)
                }
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
            .frame(maxWidth: 420)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                save()
                openChat(nodeID)
            } label: {
                Label("Chiedi", systemImage: "bubble.left.and.text.bubble.right")
            }
            Button {
                save()
                analyzing = true
                Task {
                    defer { analyzing = false }
                    do {
                        analysisResult = AnalysisResult(outcome: try await notes.analyze(nodeID, allowOnline: true))
                    } catch ChatError.sensitiveContent {
                        notes.errorMessage = String(localized: "I dati di salute, anche solo sospetti, non vengono analizzati.")
                    } catch {
                        notes.errorMessage = ChatModel.message(for: error)
                    }
                }
            } label: {
                Label("Analizza", systemImage: analyzing ? "hourglass" : "sparkles")
            }
            .disabled(analyzing)
            Button {
                save()
                generatingQuiz = true
                Task {
                    defer { generatingQuiz = false }
                    do {
                        let count = try await study.generate(from: nodeID)
                        quizMessage = count == 1
                            ? String(localized: "1 quiz nuovo nel ripasso.")
                            : String(localized: "\(count) quiz nuovi nel ripasso.")
                    } catch StudyModel.GenerationError.subjectFull {
                        notes.errorMessage = String(localized: "Questa materia ha già 200 quiz.")
                    } catch ChatError.sensitiveContent {
                        notes.errorMessage = String(localized: "Dai dati di salute, anche solo sospetti, non si creano quiz.")
                    } catch {
                        notes.errorMessage = ChatModel.message(for: error)
                    }
                }
            } label: {
                Label("Quiz", systemImage: generatingQuiz ? "hourglass" : "questionmark.square.dashed")
            }
            .disabled(generatingQuiz)
            Button {
                save()
                showingAttachments = true
            } label: {
                let count = notes.attachments(of: nodeID).count
                Label(count > 0 ? "Allegati (\(count))" : "Allegati", systemImage: count > 0 ? "paperclip.circle.fill" : "paperclip")
            }
            // Le azioni meno frequenti in un menu: con troppi pulsanti la barra comprime il selettore della vista.
            Menu {
                Button {
                    save()
                    showingHistory = true
                } label: {
                    Label("Storico", systemImage: "clock.arrow.circlepath")
                }
                Button("Esporta in Markdown (.md)", systemImage: "square.and.arrow.up") {
                    save()
                    guard let node = notes.node(nodeID) else { return }
                    exportFile = ExportFile(
                        document: DataFile(data: Data(VaultExport.markdown(node).utf8)), type: .plainText,
                        name: VaultExport.fileName(node.title) + ".md")
                }
                Button("Esporta in PDF", systemImage: "doc.richtext") {
                    save()
                    guard let node = notes.node(nodeID) else { return }
                    exportFile = ExportFile(document: DataFile(data: notes.pdf(of: node)), type: .pdf, name: VaultExport.fileName(node.title))
                }
                Divider()
                Button(role: .destructive) {
                    save()
                    notes.trash(nodeID)
                } label: {
                    Label("Sposta nel cestino", systemImage: "trash")
                }
            } label: {
                Label("Altro", systemImage: "ellipsis.circle")
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
        apply(node)
    }

    private func apply(_ node: NodeRecord) {
        title = node.title
        text = node.bodyMD
        tags = node.tags.joined(separator: ", ")
        baseline = draft
    }

    /// Salva solo ciò che l'utente ha cambiato: ogni salvataggio è una modifica da
    /// sincronizzare, e uno stato vecchio non deve sovrascrivere l'archivio.
    private func save() {
        guard let baseline, draft != baseline, notes.node(nodeID) != nil else { return }
        let snapshot = draft
        let parsedTags = Self.parseTags(snapshot.tags)
        notes.update(nodeID) {
            $0.title = snapshot.title
            $0.bodyMD = snapshot.text
            $0.tags = parsedTags
        }
        self.baseline = snapshot
    }

    nonisolated static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
