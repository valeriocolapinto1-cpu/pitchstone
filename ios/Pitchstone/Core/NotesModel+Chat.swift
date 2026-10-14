import Foundation
import PitchstoneAI
import PitchstoneSync

extension NotesModel {
    static let chatOnlineKey = "chatUsesGemini"

    /// Gemini si usa se la sync è configurata e l'utente non l'ha spento.
    var chatUsesGemini: Bool {
        get { defaults.object(forKey: Self.chatOnlineKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.chatOnlineKey) }
    }

    func chatRouter() -> ChatRouter {
        if let chatRouterOverride { return chatRouterOverride }
        let online = chatUsesGemini ? workerTransport.map(WorkerChatProvider.init(transport:)) : nil
        return ChatRouter(online: online, local: LocalModelProvider())
    }

    /// Frammenti degli appunti per la chat, senza nodi di salute. I vettori dei
    /// testi non cambiati si riusano; il calcolo dei nuovi avviene fuori dal thread principale.
    func currentChatIndex() async -> SemanticIndex {
        if let cached = chatIndex, cached.revision == revision { return cached.index }
        let built = revision
        let chunks = Chunker.corpus(nodes: activeNodes, extracted: extractedTexts)
        let embedder = chatEmbedder
        let previous = chatIndex?.index
        let index = await Task.detached(priority: .userInitiated) {
            SemanticIndex(chunks: chunks, embedder: embedder, previous: previous)
        }.value
        if chatIndex == nil || built >= (chatIndex?.revision ?? 0) { chatIndex = (built, index) }
        return index
    }

    func isSensitive(_ id: UUID) -> Bool {
        node(id).map(Privacy.isSensitive) ?? false
    }

    /// Salva la conversazione come nodo `idea`, collegato al nodo da cui è partita.
    /// Una chat già salvata si aggiorna invece di creare un doppione.
    /// La chat di un nodo di salute diventa a sua volta un dato di salute, solo locale.
    @discardableResult
    func saveChat(_ messages: [ChatMessage], focus: UUID?, existing: UUID?) -> UUID? {
        guard messages.contains(where: { $0.role == .assistant }) else { return nil }
        let origin = focus.flatMap(node)
        let sensitive = origin.map(Privacy.isSensitive) ?? false
        let body = ChatTranscript.markdown(messages) { self.node($0)?.title }
        let title = ChatTranscript.title(for: messages)
        let id: UUID
        if let existing, let saved = node(existing), saved.deletedAt == nil {
            id = existing
            // Il titolo resta quello scelto dall'utente.
            update(id) { $0.bodyMD = body }
        } else {
            id = createNode(type: .idea, title: title, area: sensitive ? .salute : (origin?.area ?? .studio)).id
            update(id) { $0.bodyMD = body }
        }
        if let origin {
            let linked = edges.contains {
                $0.deletedAt == nil && Set([$0.sourceID, $0.targetID]) == Set([id, origin.id])
            }
            if !linked { perform { try repository.createEdge(from: id, to: origin.id, kind: .ai) } }
        }
        return id
    }
}
