import PitchstoneAI
import PitchstoneSync
import SwiftUI

/// Chat sul lato: generale sugli appunti o dedicata al nodo aperto.
struct ChatPanel: View {
    @Environment(NotesModel.self) private var notes
    /// Nodo aperto a sinistra, se c'è.
    let openNodeID: UUID?
    @Binding var scope: ChatScope
    let general: ChatModel
    let nodeChat: (UUID) -> ChatModel

    enum ChatScope: Hashable {
        case general, node
    }

    var body: some View {
        VStack(spacing: 0) {
            if let openNodeID, let node = notes.node(openNodeID) {
                Picker("Chat", selection: $scope) {
                    Text("Tutti gli appunti").tag(ChatScope.general)
                    Text(node.title.isEmpty ? String(localized: "Questo nodo") : node.title).tag(ChatScope.node)
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])
            }
            if scope == .node, let openNodeID, notes.node(openNodeID) != nil {
                ChatView(chat: nodeChat(openNodeID))
                    .id(openNodeID)
            } else {
                ChatView(chat: general)
            }
        }
    }
}

struct ChatView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.openSource) private var openSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var chat: ChatModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if chat.messages.isEmpty {
                            empty
                        }
                        ForEach(chat.messages) { message in
                            MessageView(message: message)
                                .id(message.id)
                        }
                        if chat.answering {
                            ProgressView("Sto pensando…")
                                .id("answering")
                        }
                    }
                    .padding()
                }
                .onChange(of: chat.messages.count) {
                    guard let last = chat.messages.last?.id else { return }
                    if reduceMotion {
                        proxy.scrollTo(last, anchor: .bottom)
                    } else {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                if let ref = Citations.ref(from: url) {
                    openSource(ref)
                    return .handled
                }
                return .systemAction
            })
            if let notice = chat.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
            Divider()
            input
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    chat.save(using: notes)
                } label: {
                    Label(chat.savedNodeID == nil ? "Salva come nodo" : "Salvata", systemImage: chat.savedNodeID == nil ? "square.and.arrow.down" : "checkmark.circle")
                }
                .disabled(!chat.messages.contains { $0.role == .assistant } || chat.answering)
                Button {
                    chat.reset()
                } label: {
                    Label("Nuova chat", systemImage: "square.and.pencil")
                }
                .disabled(chat.messages.isEmpty)
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chat.focus == nil ? "Chiedi qualcosa sui tuoi appunti" : "Chiedi qualcosa su questo nodo")
                .font(.headline)
            Text("Le risposte citano le fonti: tocca un numero per aprire il nodo o la pagina del PDF. I dati di salute non vengono mai letti.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical)
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Scrivi una domanda", text: $chat.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit { chat.send(using: notes) }
                .accessibilityIdentifier("chat-input")
            Button {
                chat.send(using: notes)
            } label: {
                Label("Invia", systemImage: "arrow.up.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
            }
            .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.answering)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
    }
}

private struct MessageView: View {
    @Environment(\.openSource) private var openSource
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .textSelection(.enabled)
                .padding(10)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                MarkdownBlocks(text: Citations.linked(message.text, citations: message.citations))
                if !message.citations.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(message.citations, id: \.number) { citation in
                                Button {
                                    openSource(citation.ref)
                                } label: {
                                    Label("\(citation.number). \(citation.title)", systemImage: icon(citation.ref.kind))
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                Label(message.provider == .gemini ? "Gemini" : String(localized: "Sul dispositivo"),
                      systemImage: message.provider == .gemini ? "cloud" : "ipad")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(_ kind: SourceRef.Kind) -> String {
        switch kind {
        case .node: "doc.text"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .handwriting: "pencil.tip"
        }
    }
}
