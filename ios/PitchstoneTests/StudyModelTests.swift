import Foundation
import PitchstoneAI
import PitchstoneStore
import PitchstoneStudy
import PitchstoneSync
import Testing
@testable import Pitchstone

private struct Scripted: ChatProvider {
    let kind: ChatProviderKind
    var budget: TokenBudget { kind == .local ? .local : .gemini }
    var available = true
    let answer: String
    func isAvailable() async -> Bool { available }
    func reply(to prompt: ChatPrompt) async throws -> String { answer }
}

@MainActor
@Suite("Quiz e ripasso", .serialized)
struct StudyModelTests {
    let notes: NotesModel
    let study: StudyModel
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "study-\(UUID().uuidString)"))
        let container = try PitchstoneSchema.container(inMemory: true)
        notes = NotesModel(container: container, defaults: defaults, startSync: false,
                           attachmentsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        study = StudyModel(container: container, notes: notes, defaults: defaults)
        study.notificationsEnabled = false
        let fixed = clock
        study.now = { fixed }
    }

    static let answer = """
    {"language":"it","quizzes":[
      {"kind":"mcq","question":"Derivata di x^2?","options":["2x","x","x^2","2"],"answer":"2x"},
      {"kind":"calc","question":"f'(1) con f=3x^2?","answer":"6"},
      {"kind":"open","question":"Cosa misura la derivata?","answer":"La variazione istantanea."}
    ]}
    """

    @Test("i quiz di un appunto vanno nella materia dell'esame collegato")
    func generatesIntoTheExamSubject() async throws {
        let exam = notes.createNode(type: .exam, title: "Analisi 1")
        let node = notes.createNode(title: "Derivata", body: "La derivata misura la variazione istantanea.")
        notes.connect(exam.id, node.id)
        notes.analysisProvidersOverride = (nil, Scripted(kind: .gemini, answer: Self.answer))
        #expect(try await study.generate(from: node.id) == 3)
        #expect(study.quizzes.allSatisfy { $0.subject == "Analisi 1" })
        // Rigenerare non duplica le domande.
        #expect(try await study.generate(from: node.id) == 0)
        #expect(study.queue.count == 3)
    }

    @Test("offline solo risposta multipla con il modello locale; aperte e calcoli in coda")
    func offlineQueuesOpenAndCalc() async throws {
        let node = notes.createNode(title: "Derivata", body: "Testo.")
        notes.analysisProvidersOverride = (
            Scripted(kind: .local, answer: Self.answer),
            Scripted(kind: .gemini, available: false, answer: ""))
        #expect(try await study.generate(from: node.id) == 1)
        #expect(study.quizzes.map(\.kind) == [.mcq])
        #expect(study.queuedGenerations == [node.id])
    }

    @Test("una risposta aggiorna la scadenza con FSRS e lo streak")
    func answerUpdatesFSRS() async throws {
        let node = notes.createNode(title: "Derivata", body: "Testo.")
        notes.analysisProvidersOverride = (nil, Scripted(kind: .gemini, answer: Self.answer))
        try await study.generate(from: node.id)
        let quiz = try #require(study.queue.first)
        study.answer(quiz, rating: .good, duration: 12)
        let updated = try #require(study.quizzes.first { $0.id == quiz.id })
        #expect(updated.review.phase == .review)
        #expect(updated.review.due == clock.addingTimeInterval(3 * 86_400))
        #expect(study.logs.count == 1)
        #expect(study.logs.first?.durationMs == 12_000)
        #expect(study.streak == 1)
        #expect(!study.queue.contains { $0.id == quiz.id })
    }

    @Test("niente quiz dai dati di salute, e i loro quiz escono dal ripasso")
    func healthNodesHaveNoQuizzes() async throws {
        let diary = notes.createNode(type: .health, title: "Diario", area: .salute, body: "Terapia.")
        notes.analysisProvidersOverride = (nil, Scripted(kind: .gemini, answer: Self.answer))
        await #expect(throws: ChatError.sensitiveContent) { try await study.generate(from: diary.id) }

        let node = notes.createNode(title: "Derivata", body: "Testo.")
        try await study.generate(from: node.id)
        notes.trash(node.id)
        #expect(study.queue.isEmpty)
    }

    @Test("il livello della materia si adatta alle risposte")
    func adaptiveLevel() async throws {
        let node = notes.createNode(title: "Derivata", body: "Testo.")
        notes.analysisProvidersOverride = (nil, Scripted(kind: .gemini, answer: Self.answer))
        try await study.generate(from: node.id)
        let quiz = try #require(study.quizzes.first)
        for _ in 0..<12 { study.answer(quiz, rating: .good, duration: 5) }
        #expect(study.level(for: quiz.subject) == 4)
    }
}
