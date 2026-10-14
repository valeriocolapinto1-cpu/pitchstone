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
    /// Fissata alla prima domanda: una chat nata su un dato di salute resta solo
    /// locale, e una nata fuori non riceve dati di salute. Se il nodo cambia area,
    /// serve una chat nuova.
    private(set) var sensitive: Bool?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Cambia a ogni domanda e a ogni "Nuova chat": una risposta vecchia non scrive più.
    @ObservationIgnored private var request = UUID()

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
        let localOnly = focus.map { notes.isSensitive($0) } ?? false
        if let sensitive, sensitive != localOnly {
            notice = String(localized: "Il nodo è cambiato tra dati di salute e appunti: inizia una nuova chat.")
            draft = question
            return
        }
        sensitive = localOnly
        let id = UUID()
        request = id
        let history = messages
        let asked = ChatMessage(role: .user, text: question)
        messages.append(asked)
        answering = true
        notice = nil
        defer { if request == id { answering = false } }
        do {
            let index = await notes.currentChatIndex()
            // La chat di un nodo di salute resta sull'iPad e non legge il nodo.
            let reply = try await notes.chatRouter().answer(
                question, history: history, index: index, embedder: notes.chatEmbedder,
                focus: localOnly ? nil : focus, localOnly: localOnly)
            guard request == id, !Task.isCancelled else { return }
            messages.append(reply.message)
            if localOnly {
                notice = String(localized: "Dato di salute: la chat resta sull'iPad e non legge questo nodo.")
            } else if reply.fallbackReason != nil, notes.workerTransport != nil || notes.chatRouterOverride != nil {
                notice = String(localized: "Gemini non raggiungibile: ha risposto il modello sul dispositivo.")
            }
            if savedNodeID != nil { save(using: notes) }
        } catch {
            guard request == id, !Task.isCancelled, !(error is CancellationError) else { return }
            // La domanda senza risposta torna nel campo: non resta nella conversazione.
            messages.removeAll { $0.id == asked.id }
            if draft.isEmpty { draft = question }
            notice = Self.message(for: error)
        }
    }

    func save(using notes: NotesModel) {
        guard let sensitive else { return }
        savedNodeID = notes.saveChat(messages, focus: focus, existing: savedNodeID, sensitive: sensitive)
    }

    func reset() {
        task?.cancel()
        task = nil
        request = UUID()
        messages = []
        savedNodeID = nil
        sensitive = nil
        notice = nil
        answering = false
    }

    static func message(for error: Error) -> String {
        switch error {
        case ChatError.noProvider:
            String(localized: "Nessun modello disponibile. Offline serve Apple Intelligence attiva; online, configura il Worker nelle impostazioni.")
        case ChatError.contextTooLarge:
            String(localized: "La domanda è troppo lunga per il modello sul dispositivo: accorciala.")
        case ChatError.refused:
            String(localized: "Il modello sul dispositivo non ha voluto rispondere a questa domanda.")
        case let error as HTTPError where error.status == 429:
            String(localized: "Limite giornaliero di Gemini raggiunto e modello sul dispositivo non disponibile.")
        case let error as HTTPError:
            String(localized: "Il Worker ha risposto con l'errore \(error.status).")
        default:
            String(localized: "Risposta non riuscita: \(error.localizedDescription)")
        }
    }
}
