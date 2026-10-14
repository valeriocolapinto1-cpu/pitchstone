import Foundation
import Observation
import PitchstoneAI
import PitchstoneSync

/// Una conversazione: generale (sugli appunti) o dedicata a un nodo.
@MainActor
@Observable
final class ChatModel {
    let focus: UUID?
    private(set) var messages: [ChatMessage] = []
    private(set) var answering = false
    /// Avviso sotto la chat: chi ha risposto e perché, o cosa è andato storto.
    private(set) var notice: String?
    private(set) var savedNodeID: UUID?
    var draft = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    init(focus: UUID? = nil) {
        self.focus = focus
    }

    func send(using notes: NotesModel) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !answering else { return }
        draft = ""
        task = Task { await ask(question, notes: notes) }
    }

    func ask(_ question: String, notes: NotesModel) async {
        let history = messages
        messages.append(ChatMessage(role: .user, text: question))
        answering = true
        notice = nil
        defer { answering = false }
        // La chat di un nodo di salute resta sull'iPad e non legge il nodo.
        let localOnly = focus.map(notes.isSensitive) ?? false
        do {
            let index = await notes.currentChatIndex()
            let reply = try await notes.chatRouter().answer(
                question, history: history, index: index, embedder: notes.chatEmbedder,
                focus: localOnly ? nil : focus, localOnly: localOnly)
            try Task.checkCancellation()
            messages.append(reply.message)
            if localOnly {
                notice = String(localized: "Dato di salute: la chat resta sull'iPad e non legge questo nodo.")
            } else if reply.fallbackReason != nil, notes.workerTransport != nil || notes.chatRouterOverride != nil {
                notice = String(localized: "Gemini non raggiungibile: ha risposto il modello sul dispositivo.")
            }
            if savedNodeID != nil { save(using: notes) }
        } catch is CancellationError {
            return
        } catch {
            notice = Self.message(for: error)
        }
    }

    func save(using notes: NotesModel) {
        savedNodeID = notes.saveChat(messages, focus: focus, existing: savedNodeID)
    }

    func reset() {
        task?.cancel()
        task = nil
        messages = []
        savedNodeID = nil
        notice = nil
        answering = false
    }

    static func message(for error: Error) -> String {
        switch error {
        case ChatError.noProvider:
            String(localized: "Nessun modello disponibile. Offline serve Apple Intelligence attiva; online, configura il Worker nelle impostazioni.")
        case let error as HTTPError where error.status == 429:
            String(localized: "Limite giornaliero di Gemini raggiunto e modello sul dispositivo non disponibile.")
        case let error as HTTPError:
            String(localized: "Il Worker ha risposto con l'errore \(error.status).")
        default:
            String(localized: "Risposta non riuscita: \(error.localizedDescription)")
        }
    }
}
