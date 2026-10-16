import PitchstoneAI
import PitchstoneSync
import SwiftUI
import UniformTypeIdentifiers

/// Elenco dei nodi a sinistra, nodo aperto a destra.
struct RootView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(CommandCenter.self) private var commands
    @AppStorage(OnboardingPolicy.storageKey) private var onboardingCompleted = false
    /// Chiesta dalle Impostazioni: la presentazione si riapre quando il foglio è chiuso.
    @State private var replayOnboarding = false
    @State private var showingOnboarding = false
    @State private var columns = NavigationSplitViewVisibility.automatic
    @State private var searching = false
    @State private var selection: UUID?
    @State private var showingTrash = false
    @State private var showingSettings = false
    @State private var showingImport = false
    @State private var importingDocuments = false
    @State private var showingGraph = false
    @State private var graphState = GraphState()
    /// Nodo aperto dal grafo, in un foglio sopra il grafo.
    @State private var graphOpen: GraphOpen?
    @State private var showingChat = false
    @State private var showingQuiz = false
    @State private var showingExams = false
    @State private var showingBackup = false
    @State private var chatScope = ChatPanel.ChatScope.general
    @State private var chats = ChatStore()
    /// Nodo della chat dedicata: segue l'elenco, non le citazioni, così aprire
    /// una fonte non nasconde la conversazione che la cita.
    @State private var chatNodeID: UUID?
    /// Allegato aperto da una citazione, alla pagina citata.
    @State private var reader: ReaderRequest?

    struct GraphOpen: Identifiable {
        var id: UUID
        var editing: Bool
    }

    struct ReaderRequest: Identifiable {
        var attachment: AttachmentRecord
        var page: Int?
        var id: UUID { attachment.id }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            NodeListView(selection: Binding(get: { selection }, set: { value in
                selection = value
                chatNodeID = value
                // Scegliere un nodo dall'elenco riporta alla nota.
                if value != nil { showingGraph = false }
            }), searching: $searching)
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
                        Button { toggleChat(nil) } label: {
                            Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                        }
                        .labelStyle(.iconOnly)
                        Button { showingQuiz = true } label: {
                            Label("Ripasso", systemImage: "rectangle.stack.badge.play")
                        }
                        .labelStyle(.iconOnly)
                        Button { showingExams = true } label: {
                            Label("Esami", systemImage: "calendar")
                        }
                        .labelStyle(.iconOnly)
                        Spacer()
                        SyncStatusView()
                        Spacer()
                        Menu {
                            Button { showingSettings = true } label: {
                                Label("Impostazioni", systemImage: "gearshape")
                            }
                            Button { showingBackup = true } label: {
                                Label("Backup ed esportazione", systemImage: "externaldrive")
                            }
                        } label: {
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
        .inspector(isPresented: $showingChat) {
            NavigationStack {
                ChatPanel(openNodeID: chatNodeID, scope: $chatScope, general: chats.general) {
                    chats.chat(for: $0)
                }
                .navigationTitle("Chat")
                .navigationBarTitleDisplayMode(.inline)
            }
            .inspectorColumnWidth(min: 320, ideal: 420, max: 600)
        }
        .environment(\.openSource, OpenSourceAction { open($0) })
        .environment(\.openChat, OpenChatAction { toggleChat($0, forceOpen: true) })
        .fullScreenCover(item: $reader) { request in
            AttachmentReaderView(attachment: request.attachment, initialPage: request.page)
        }
        // Scorciatoie da tastiera: arrivano dai comandi della scena (AppShortcuts.swift).
        .onChange(of: commands.request) { _, request in
            if let request { perform(request.shortcut) }
        }
        .onAppear {
            showingOnboarding = OnboardingPolicy.shouldShow(
                completed: onboardingCompleted, arguments: ProcessInfo.processInfo.arguments)
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView {
                onboardingCompleted = true
                showingOnboarding = false
            }
        }
        .sheet(isPresented: $showingQuiz) {
            QuizView()
        }
        .sheet(isPresented: $showingExams) {
            ExamCalendarView()
        }
        .sheet(isPresented: $showingBackup) {
            BackupView()
        }
        .sheet(isPresented: $showingTrash) {
            TrashView()
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            // "Rivedi la presentazione" nelle Impostazioni: si apre a foglio chiuso.
            if replayOnboarding {
                replayOnboarding = false
                showingOnboarding = true
            }
        }) {
            SettingsView { replayOnboarding = true }
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
                chatNodeID = first
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

extension RootView {
    /// Un foglio aperto sopra la finestra: le scorciatoie globali aspettano che si chiuda,
    /// perché un foglio non può presentarne un altro.
    private var presentingModal: Bool {
        showingOnboarding || graphOpen != nil || reader != nil || showingQuiz || showingExams || showingBackup
            || showingTrash || showingSettings || showingImport || importingDocuments || graphState.showingList
    }

    private func perform(_ shortcut: AppShortcut) {
        guard !presentingModal else { return }
        switch shortcut {
        case .newNode:
            let id = notes.createNode(type: .concept, area: .studio).id
            showingGraph = false
            selection = id
            chatNodeID = id
        case .search:
            if showingGraph {
                graphState.requestSearchFocus()
            } else {
                columns = .all
                searching = true
            }
        case .toggleGraph:
            showingGraph.toggle()
        case .chat:
            toggleChat(nil)
        case .review:
            showingQuiz = true
        case .settings:
            showingSettings = true
        }
    }

    /// `nodeID` apre la chat di quel nodo; nil apre la chat generale o la chiude.
    private func toggleChat(_ nodeID: UUID?, forceOpen: Bool = false) {
        if let nodeID {
            graphOpen = nil
            showingGraph = false
            selection = nodeID
            chatNodeID = nodeID
            chatScope = .node
        } else if !showingChat {
            chatScope = .general
        }
        showingChat = forceOpen || nodeID != nil ? true : !showingChat
    }

    /// Una citazione: il nodo si apre a sinistra, un PDF o una foto a tutto schermo.
    private func open(_ ref: SourceRef) {
        if ref.kind == .pdf || ref.kind == .image, let id = ref.sourceID,
           let attachment = notes.attachment(id), attachment.deletedAt == nil {
            let request = ReaderRequest(attachment: attachment, page: ref.page)
            if graphOpen != nil {
                // Il lettore a tutto schermo non si apre sopra un foglio: prima si chiude il foglio.
                graphOpen = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    reader = request
                }
            } else {
                reader = request
            }
            return
        }
        guard let node = notes.node(ref.nodeID), node.deletedAt == nil else {
            notes.errorMessage = String(localized: "La fonte citata non esiste più.")
            return
        }
        graphOpen = nil
        showingGraph = false
        selection = node.id
    }
}

/// Le conversazioni aperte in questa sessione: una generale e una per nodo.
@MainActor
final class ChatStore {
    let general = ChatModel()
    private var byNode: [UUID: ChatModel] = [:]

    func chat(for nodeID: UUID) -> ChatModel {
        if let chat = byNode[nodeID] { return chat }
        let chat = ChatModel(focus: nodeID)
        byNode[nodeID] = chat
        return chat
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
