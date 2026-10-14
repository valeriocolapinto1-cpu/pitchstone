import Foundation
import PitchstoneAI
import PitchstoneStore
import PitchstoneSync
import Testing
import UIKit
@testable import Pitchstone

/// Modello finto che registra i prompt ricevuti.
private final class RecordingProvider: ChatProvider, @unchecked Sendable {
    let kind: ChatProviderKind
    let budget: TokenBudget
    let failure: Error?
    let answer: String
    private let lock = NSLock()
    private var _prompts: [ChatPrompt] = []
    var prompts: [ChatPrompt] { lock.withLock { _prompts } }

    init(kind: ChatProviderKind, failure: Error? = nil, answer: String = "Il mitocondrio produce energia [1].") {
        self.kind = kind
        budget = kind == .local ? .local : .gemini
        self.failure = failure
        self.answer = answer
    }

    func isAvailable() async -> Bool { true }

    func reply(to prompt: ChatPrompt) async throws -> String {
        lock.withLock { _prompts.append(prompt) }
        if let failure { throw failure }
        return answer
    }
}

@MainActor
@Suite("Chat", .serialized)
struct ChatModelTests {
    let model: NotesModel

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "chat-\(UUID().uuidString)"))
        model = NotesModel(container: try PitchstoneSchema.container(inMemory: true), defaults: defaults, startSync: false,
                           attachmentsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test("risponde con Gemini e salva la chat come nodo collegato")
    func answersAndSaves() async throws {
        let cell = model.createNode(title: "Cellula", body: "Il mitocondrio produce energia per la cellula.")
        let online = RecordingProvider(kind: .gemini)
        model.chatRouterOverride = ChatRouter(online: online, local: RecordingProvider(kind: .local))
        let chat = ChatModel(focus: cell.id)
        await chat.ask("Cosa fa il mitocondrio?", notes: model)

        let reply = try #require(chat.messages.last)
        #expect(reply.provider == .gemini)
        #expect(reply.citations.first?.ref.nodeID == cell.id)
        #expect(chat.notice == nil)

        chat.save(using: model)
        let saved = try #require(chat.savedNodeID.flatMap(model.node))
        #expect(saved.type == .idea)
        #expect(saved.title == "Chat: Cosa fa il mitocondrio?")
        #expect(saved.bodyMD.contains("[[Cellula]]"))
        #expect(saved.bodyMD.contains(Citations.url(for: SourceRef(nodeID: cell.id)).absoluteString))
        // Arco verso il nodo di origine: dal link `[[Cellula]]`, senza doppioni.
        let between = model.edges.filter { $0.deletedAt == nil && Set([$0.sourceID, $0.targetID]) == Set([saved.id, cell.id]) }
        #expect(between.count == 1)

        // Una seconda domanda aggiorna lo stesso nodo.
        await chat.ask("E i ribosomi?", notes: model)
        #expect(chat.savedNodeID == saved.id)
        #expect(model.node(saved.id)?.bodyMD.contains("E i ribosomi?") == true)
        #expect(model.activeNodes.filter { $0.type == .idea }.count == 1)
    }

    @Test("offline risponde il modello sul dispositivo")
    func offlineFallback() async throws {
        model.createNode(title: "Cellula", body: "Il mitocondrio produce energia.")
        let local = RecordingProvider(kind: .local)
        model.chatRouterOverride = ChatRouter(online: RecordingProvider(kind: .gemini, failure: URLError(.notConnectedToInternet)), local: local)
        let chat = ChatModel()
        await chat.ask("mitocondrio", notes: model)
        #expect(chat.messages.last?.provider == .local)
        #expect(chat.notice != nil)
        #expect(local.prompts.count == 1)
    }

    @Test("i nodi di salute non entrano nei prompt")
    func healthExcluded() async throws {
        model.createNode(title: "Cellula", body: "Il mitocondrio produce energia.")
        let diary = model.createNode(type: .health, title: "Diario", area: .salute, body: "Mitocondrio, farmaco Xyzolam 20 mg")
        let online = RecordingProvider(kind: .gemini)
        let local = RecordingProvider(kind: .local)
        model.chatRouterOverride = ChatRouter(online: online, local: local)

        let general = ChatModel()
        await general.ask("mitocondrio Xyzolam", notes: model)
        let healthChat = ChatModel(focus: diary.id)
        await healthChat.ask("Xyzolam", notes: model)

        // La chat del nodo di salute non va a Gemini.
        #expect(online.prompts.count == 1)
        #expect(local.prompts.count == 1)
        for prompt in online.prompts + local.prompts {
            #expect(!prompt.system.contains("Xyzolam"))
            #expect(!prompt.sources.contains { $0.ref.nodeID == diary.id })
        }
        // Salvata, resta un dato di salute.
        healthChat.save(using: model)
        let saved = try #require(healthChat.savedNodeID.flatMap(model.node))
        #expect(Privacy.isSensitive(saved))
    }

    @Test("senza modelli la chat spiega cosa manca")
    func noProvider() async {
        model.chatRouterOverride = ChatRouter(online: nil, local: nil)
        let chat = ChatModel()
        await chat.ask("ciao", notes: model)
        #expect(chat.messages.count == 1)
        #expect(chat.notice?.isEmpty == false)
        chat.save(using: model)
        #expect(chat.savedNodeID == nil)
    }
}
