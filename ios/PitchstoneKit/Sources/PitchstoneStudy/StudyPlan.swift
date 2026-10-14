import Foundation

/// Coda del giorno, streak e obiettivi settimanali. Calendario locale: i giorni
/// iniziano a mezzanotte dove si trova l'iPad.
public struct StudyPlan: Sendable {
    /// Al massimo circa 20 ripassi al giorno (ARCHITETTURA.md, sezione 2).
    public static let dailyLimit = 20
    /// Quiz nuovi al giorno, dentro il limite.
    public static let newPerDay = 8

    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// I quiz da fare adesso: prima i ripassi scaduti (i più in ritardo per primi), poi
    /// i nuovi, senza superare il limite del giorno contando quelli già fatti oggi.
    public func queue(_ quizzes: [QuizRecord], logs: [ReviewLogRecord], now: Date) -> [QuizRecord] {
        let today = calendar.startOfDay(for: now)
        let doneToday = logs.filter { $0.answeredAt >= today }
        let reviewedToday = Set(doneToday.map(\.quizID))
        let left = max(0, Self.dailyLimit - reviewedToday.count)
        // Un "di nuovo" di oggi torna dopo 10 minuti e non conta di nuovo nel limite.
        let relearning = quizzes.filter {
            ($0.review.phase == .learning || $0.review.phase == .relearning) && $0.review.due <= now && reviewedToday.contains($0.id)
        }
        let due = quizzes.filter { $0.review.phase != .new && $0.review.due <= now && !reviewedToday.contains($0.id) }
            .sorted { $0.review.due < $1.review.due }
        // Quiz visti per la prima volta oggi: la loro prima risposta è di oggi.
        var first: [UUID: Date] = [:]
        for log in logs { first[log.quizID] = min(first[log.quizID] ?? log.answeredAt, log.answeredAt) }
        let newDoneToday = first.values.filter { $0 >= today }.count
        let newQuizzes = quizzes.filter { $0.review.phase == .new }.sorted { $0.createdAt < $1.createdAt }
        let reviews = Array(due.prefix(left))
        let newCount = min(max(0, Self.newPerDay - newDoneToday), left - reviews.count)
        return relearning.sorted { $0.review.due < $1.review.due } + reviews + Array(newQuizzes.prefix(max(0, newCount)))
    }

    /// Quanti ripassi scadono entro la fine del giorno di `date`, nuovi esclusi, entro il limite.
    public func dueCount(_ quizzes: [QuizRecord], on date: Date) -> Int {
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else { return 0 }
        return min(Self.dailyLimit, quizzes.filter { $0.review.phase != .new && $0.review.due < end }.count)
    }

    /// Giorni di fila con almeno un ripasso, fino a oggi. Se oggi non si è ancora
    /// studiato vale lo streak fino a ieri; un giorno saltato lo azzera.
    public func streak(_ logs: [ReviewLogRecord], now: Date) -> Int {
        let days = Set(logs.map { calendar.startOfDay(for: $0.answeredAt) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// Inizio della settimana (lunedì) che contiene `date`.
    public func weekStart(_ date: Date) -> Date {
        var iso = calendar
        iso.firstWeekday = 2
        return iso.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    public struct WeekProgress: Sendable, Equatable {
        public var quizzes: Int
        public var minutes: Int
        public var targetQuizzes: Int
        public var targetMinutes: Int

        public var fraction: Double {
            let parts = [
                targetQuizzes > 0 ? min(1, Double(quizzes) / Double(targetQuizzes)) : nil,
                targetMinutes > 0 ? min(1, Double(minutes) / Double(targetMinutes)) : nil,
            ].compactMap { $0 }
            return parts.isEmpty ? 0 : parts.reduce(0, +) / Double(parts.count)
        }
    }

    /// Risposte e minuti della settimana in corso rispetto all'obiettivo.
    public func week(_ logs: [ReviewLogRecord], goal: StudyGoal, now: Date) -> WeekProgress {
        let start = weekStart(now)
        let this = logs.filter { $0.answeredAt >= start && $0.answeredAt <= now }
        let ms = this.compactMap(\.durationMs).reduce(0, +)
        return WeekProgress(quizzes: this.count, minutes: ms / 60_000, targetQuizzes: goal.targetQuizzes, targetMinutes: goal.targetMinutes)
    }

    /// Difficoltà adattiva: sopra l'85% di risposte giuste nelle ultime 20 della materia
    /// il livello sale, sotto il 60% scende.
    public static func adaptedLevel(current: Int, recentRatings: [Rating]) -> Int {
        let recent = recentRatings.suffix(20)
        guard recent.count >= 10 else { return current }
        let correct = Double(recent.filter { $0 >= .good }.count) / Double(recent.count)
        if correct > 0.85 { return min(5, current + 1) }
        if correct < 0.6 { return max(1, current - 1) }
        return current
    }
}

public struct StudyGoal: Sendable, Equatable, Codable {
    public var targetQuizzes: Int
    public var targetMinutes: Int

    public init(targetQuizzes: Int = 100, targetMinutes: Int = 120) {
        self.targetQuizzes = targetQuizzes
        self.targetMinutes = targetMinutes
    }
}
