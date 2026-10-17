#if canImport(SwiftData)
import Foundation
import PitchstoneStudy
import SwiftData

/// Quiz con il loro stato di ripasso. Solo locali come le statistiche di studio
/// (ARCHITETTURA.md, sezione 7): si rigenerano dagli appunti (ADR 0011).
@Model
public final class QuizEntity {
    @Attribute(.unique) public var id: UUID
    public var nodeID: UUID?
    public var subject: String
    public var kind: String
    public var question: String
    public var options: [String]
    public var answer: String
    public var explanation: String
    public var difficulty: Int
    public var language: String
    public var createdAt: Date
    public var due: Date
    public var stability: Double
    public var fsrsDifficulty: Double
    public var reps: Int
    public var lapses: Int
    public var phase: String
    public var lastReview: Date?

    init(_ q: QuizRecord) {
        id = q.id
        nodeID = q.nodeID
        subject = q.subject
        kind = q.kind.rawValue
        question = q.question
        options = q.options
        answer = q.answer
        explanation = q.explanation
        difficulty = q.difficulty
        language = q.language
        createdAt = q.createdAt
        due = q.review.due
        stability = q.review.stability
        fsrsDifficulty = q.review.difficulty
        reps = q.review.reps
        lapses = q.review.lapses
        phase = q.review.phase.rawValue
        lastReview = q.review.lastReview
    }

    func update(review r: ReviewState) {
        due = r.due
        stability = r.stability
        fsrsDifficulty = r.difficulty
        reps = r.reps
        lapses = r.lapses
        phase = r.phase.rawValue
        lastReview = r.lastReview
    }

    var record: QuizRecord? {
        guard let kind = QuizKind(rawValue: kind) else { return nil }
        let review = ReviewState(
            due: due, stability: stability, difficulty: fsrsDifficulty, reps: reps, lapses: lapses,
            phase: ReviewPhase(rawValue: phase) ?? .new, lastReview: lastReview)
        return QuizRecord(
            id: id, nodeID: nodeID, subject: subject, kind: kind, question: question, options: options, answer: answer,
            explanation: explanation, difficulty: difficulty, language: language, createdAt: createdAt, review: review)
    }
}

@Model
public final class ReviewLogEntity {
    @Attribute(.unique) public var id: UUID
    public var quizID: UUID
    public var rating: Int
    public var answeredAt: Date
    public var durationMs: Int?

    init(_ r: ReviewLogRecord) {
        id = r.id
        quizID = r.quizID
        rating = r.rating.rawValue
        answeredAt = r.answeredAt
        durationMs = r.durationMs
    }

    var record: ReviewLogRecord? {
        Rating(rawValue: rating).map { ReviewLogRecord(id: id, quizID: quizID, rating: $0, answeredAt: answeredAt, durationMs: durationMs) }
    }
}

@MainActor
public final class StudyStore {
    private let container: ModelContainer
    private let context: ModelContext
    /// Chiamata a ogni salvataggio fallito: l'errore si vede, non si perde.
    public var onError: ((Error) -> Void)?

    public init(container: ModelContainer) {
        self.container = container
        context = container.mainContext
    }

    public func quizzes() -> [QuizRecord] {
        let d = FetchDescriptor<QuizEntity>(sortBy: [SortDescriptor(\.createdAt)])
        return ((try? context.fetch(d)) ?? []).compactMap(\.record)
    }

    public func logs() -> [ReviewLogRecord] {
        let d = FetchDescriptor<ReviewLogEntity>(sortBy: [SortDescriptor(\.answeredAt)])
        return ((try? context.fetch(d)) ?? []).compactMap(\.record)
    }

    /// Aggiunge i quiz che non ci sono già (per id, anche tra quelli passati insieme). Dice se ha salvato.
    @discardableResult
    public func insert(_ quizzes: [QuizRecord]) -> Bool {
        var known = Set(((try? context.fetch(FetchDescriptor<QuizEntity>())) ?? []).map(\.id))
        for quiz in quizzes where known.insert(quiz.id).inserted { context.insert(QuizEntity(quiz)) }
        return commit()
    }

    /// Una risposta: nuovo stato FSRS del quiz e una riga nel registro.
    @discardableResult
    public func record(_ log: ReviewLogRecord, review: ReviewState) -> Bool {
        let id = log.quizID
        var d = FetchDescriptor<QuizEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let entity = (try? context.fetch(d))?.first else { return false }
        entity.update(review: review)
        context.insert(ReviewLogEntity(log))
        return commit()
    }

    /// Elimina i quiz (e il loro registro), per esempio quelli di un nodo eliminato.
    @discardableResult
    public func delete(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return true }
        for entity in (try? context.fetch(FetchDescriptor<QuizEntity>())) ?? [] where ids.contains(entity.id) {
            context.delete(entity)
        }
        for entity in (try? context.fetch(FetchDescriptor<ReviewLogEntity>())) ?? [] where ids.contains(entity.quizID) {
            context.delete(entity)
        }
        return commit()
    }

    /// Salva; se non riesce annulla il contesto, avvisa chi ascolta e lo dice a chi chiama.
    private func commit() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            onError?(error)
            return false
        }
    }
}
#endif
