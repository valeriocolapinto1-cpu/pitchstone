import Foundation
import Testing
@testable import PitchstoneStudy

private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Rome")!
    return c
}()

private func day(_ d: Int, _ h: Int = 12, _ m: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
}

private func quiz(_ review: ReviewState? = nil, created: Date = day(1)) -> QuizRecord {
    QuizRecord(nodeID: UUID(), subject: "Analisi 1", kind: .mcq, question: "?", options: ["a", "b", "c"], answer: "a",
               difficulty: 3, language: "it", createdAt: created, review: review)
}

@Suite struct FSRSTests {
    let fsrs = FSRS()

    /// Casi noti dalle formule di FSRS-5 con i parametri predefiniti.
    @Test func firstReviewUsesInitialParameters() {
        let new = ReviewState.new(at: day(1))
        let good = fsrs.review(new, rating: .good, now: day(1))
        #expect(abs(good.stability - 3.173) < 1e-9)
        // D0(3) = w4 - e^(2·w5) + 1
        #expect(abs(good.difficulty - (7.1949 - exp(2 * 0.5345) + 1)) < 1e-9)
        #expect(good.phase == .review)
        #expect(good.due == day(4))

        let easy = fsrs.review(new, rating: .easy, now: day(1))
        #expect(abs(easy.stability - 15.69105) < 1e-9)
        #expect(easy.due == day(17))

        let again = fsrs.review(new, rating: .again, now: day(1))
        #expect(abs(again.stability - 0.40255) < 1e-9)
        #expect(abs(again.difficulty - 7.1949) < 1e-9)
        #expect(again.phase == .learning)
        #expect(again.due == day(1).addingTimeInterval(600))
    }

    @Test func retrievabilityIsNinetyPercentAfterStabilityDays() {
        #expect(abs(FSRS.retrievability(days: 10, stability: 10) - 0.9) < 1e-12)
        #expect(fsrs.interval(stability: 10) == 10)
        #expect(FSRS(desiredRetention: 0.8).interval(stability: 10) > 10)
    }

    @Test func successfulReviewsGrowIntervals() {
        var state = fsrs.review(.new(at: day(1)), rating: .good, now: day(1))
        var last = 3
        var date = state.due
        for _ in 0..<4 {
            state = fsrs.review(state, rating: .good, now: date)
            let interval = Int((state.due.timeIntervalSince(date) / 86_400).rounded())
            #expect(interval > last)
            last = interval
            date = state.due
        }
        #expect(state.reps == 5)
        #expect(state.lapses == 0)
    }

    @Test func lapseShrinksStabilityAndCountsIt() {
        let reviewed = fsrs.review(fsrs.review(.new(at: day(1)), rating: .good, now: day(1)), rating: .good, now: day(4))
        let lapsed = fsrs.review(reviewed, rating: .again, now: reviewed.due)
        #expect(lapsed.stability < reviewed.stability)
        #expect(lapsed.lapses == 1)
        #expect(lapsed.phase == .relearning)
        #expect(lapsed.difficulty > reviewed.difficulty)
        let relearned = fsrs.review(lapsed, rating: .good, now: lapsed.due)
        #expect(relearned.phase == .review)
        #expect(relearned.due > lapsed.due)
    }

    @Test func difficultyStaysInRange() {
        var state = ReviewState.new(at: day(1))
        var now = day(1)
        for _ in 0..<30 {
            state = fsrs.review(state, rating: .again, now: now)
            now = now.addingTimeInterval(86_400 * 2)
        }
        #expect(state.difficulty <= 10 && state.difficulty >= 1)
        #expect(state.stability >= 0.1)
    }
}

@Suite struct StudyPlanTests {
    let plan = StudyPlan(calendar: calendar)

    @Test func streakCountsConsecutiveDaysAndResetsAfterAGap() {
        let logs = [day(5), day(6), day(7, 9), day(7, 20)].map { ReviewLogRecord(quizID: UUID(), rating: .good, answeredAt: $0) }
        #expect(plan.streak(logs, now: day(7, 22)) == 3)
        // Oggi non si è ancora studiato: vale lo streak fino a ieri.
        #expect(plan.streak(logs, now: day(8, 7)) == 3)
        // Un giorno intero saltato lo azzera.
        #expect(plan.streak(logs, now: day(9, 7)) == 0)
        #expect(plan.streak([], now: day(9)) == 0)
    }

    @Test func streakFollowsLocalMidnight() {
        let late = ReviewLogRecord(quizID: UUID(), rating: .good, answeredAt: day(5, 23, 59))
        let early = ReviewLogRecord(quizID: UUID(), rating: .good, answeredAt: day(6, 0, 1))
        #expect(plan.streak([late, early], now: day(6, 12)) == 2)
    }

    @Test func queueRespectsTheDailyLimit() {
        let fsrs = FSRS()
        let due = (0..<30).map { i in
            quiz(fsrs.review(.new(at: day(1)), rating: .good, now: day(1).addingTimeInterval(Double(i))))
        }
        let fresh = (0..<10).map { _ in quiz() }
        let queue = plan.queue(due + fresh, logs: [], now: day(10))
        #expect(queue.count == StudyPlan.dailyLimit)
        #expect(queue.allSatisfy { $0.review.phase == .review })
        // Più in ritardo per primi.
        #expect(queue.first?.id == due.first?.id)

        // Un ripasso che scade stasera si può fare già dalla mattina.
        let tonight = quiz(ReviewState(due: day(10, 21), stability: 3, difficulty: 5, reps: 1, phase: .review, lastReview: day(7)))
        #expect(plan.queue([tonight], logs: [], now: day(10, 8)).map(\.id) == [tonight.id])
        #expect(plan.practice([tonight], now: day(9, 8)).map(\.id) == [tonight.id])

        let done = due.prefix(15).map { ReviewLogRecord(quizID: $0.id, rating: .good, answeredAt: day(10, 9)) }
        #expect(plan.queue(due + fresh, logs: done, now: day(10)).count == 5)
        let few = plan.queue(Array(due.prefix(2)) + fresh, logs: [], now: day(10))
        #expect(few.count == 2 + StudyPlan.newPerDay)
    }

    @Test func weeklyGoalProgress() {
        let logs = [day(12, 9), day(13), day(18, 9), day(11)].map {
            ReviewLogRecord(quizID: UUID(), rating: .good, answeredAt: $0, durationMs: 60_000)
        }
        // Settimana da lunedì 12 ottobre 2026.
        let week = plan.week(logs, goal: StudyGoal(targetQuizzes: 4, targetMinutes: 6), now: day(18, 10))
        #expect(week.quizzes == 3)
        #expect(week.minutes == 3)
        #expect(abs(week.fraction - (0.75 + 0.5) / 2) < 1e-9)
    }

    @Test func adaptiveLevel() {
        #expect(StudyPlan.adaptedLevel(current: 3, recentRatings: Array(repeating: .good, count: 20)) == 4)
        #expect(StudyPlan.adaptedLevel(current: 3, recentRatings: Array(repeating: .again, count: 20)) == 2)
        #expect(StudyPlan.adaptedLevel(current: 5, recentRatings: Array(repeating: .easy, count: 20)) == 5)
        #expect(StudyPlan.adaptedLevel(current: 3, recentRatings: [.good]) == 3)
    }
}

@Suite struct ReminderTests {
    let planner = ReminderPlanner(plan: StudyPlan(calendar: calendar))
    let fsrs = FSRS()

    @Test func morningRemindersAtEightForTheNextDays() {
        let reviewed = quiz(fsrs.review(.new(at: day(1)), rating: .good, now: day(1)))  // scade il 4
        let log = ReviewLogRecord(quizID: reviewed.id, rating: .good, answeredAt: day(1))
        let mornings = planner.reminders(quizzes: [reviewed], logs: [log], now: day(3, 21)).filter { $0.kind == .morning }
        // Dal 4 in poi il ripasso è in scadenza ogni mattina finché non si fa.
        #expect(mornings.first?.fireDate == day(4, 8))
        #expect(mornings.first?.body == "Hai 1 ripasso in scadenza.")
        #expect(mornings.count == ReminderPlanner.morningDays)
        #expect(Set(mornings.map(\.identifier)).count == mornings.count)
        // Il 2 sera non scade niente il 3: il primo promemoria è il 4.
        #expect(planner.reminders(quizzes: [reviewed], logs: [log], now: day(2, 21)).first { $0.kind == .morning }?.fireDate == day(4, 8))
        // Prima delle 8 di un giorno con ripassi: anche oggi.
        #expect(planner.reminders(quizzes: [reviewed], logs: [log], now: day(4, 6)).first { $0.kind == .morning }?.fireDate == day(4, 8))
    }

    @Test func missedDayAlertsAtMidnightOnce() {
        let reviewed = quiz(fsrs.review(.new(at: day(1)), rating: .good, now: day(1)))
        let logs = [day(2), day(3)].map { ReviewLogRecord(quizID: reviewed.id, rating: .good, answeredAt: $0) }
        // Il 4 non si è ancora studiato: l'avviso è a mezzanotte del 4.
        let missed = planner.reminders(quizzes: [reviewed], logs: logs, now: day(4, 18)).filter { $0.kind == .missed }
        #expect(missed.map(\.fireDate) == [day(5, 0)])
        // Studiato il 4: l'avviso passa alla mezzanotte del 5.
        let studied = logs + [ReviewLogRecord(quizID: reviewed.id, rating: .good, answeredAt: day(4, 19))]
        #expect(planner.reminders(quizzes: [reviewed], logs: studied, now: day(4, 20)).filter { $0.kind == .missed }.map(\.fireDate) == [day(6, 0)])
        // Streak già perso: nessun altro avviso nei giorni dopo.
        #expect(planner.reminders(quizzes: [reviewed], logs: logs, now: day(6, 10)).allSatisfy { $0.kind != .missed })
    }
}

@Suite struct QuizTests {
    let node = UUID()

    @Test func parsesValidQuizzesAndDropsBrokenOnes() {
        let answer = """
        ```json
        {"language":"it","quizzes":[
          {"kind":"mcq","question":"Derivata di x^2?","options":["2x","x","x^2","2"],"answer":"2x","explanation":"Regola della potenza."},
          {"kind":"mcq","question":"Senza risposta tra le opzioni","options":["a","b","c"],"answer":"d"},
          {"kind":"mcq","question":"Opzioni doppie","options":["a","a","b"],"answer":"a"},
          {"kind":"calc","question":"Quanto fa 3/4 in decimale?","answer":0.75},
          {"kind":"calc","question":"Non numerico","answer":"dipende"},
          {"kind":"open","question":"Cos'è il limite?","answer":"Il valore a cui tende la funzione."},
          {"kind":"open","question":"cos'è il limite?","answer":"doppione"},
          {"kind":"health","question":"x","answer":"y"}
        ]}
        ```
        """
        let quizzes = QuizGenerator.parse(answer, nodeID: node, subject: "Analisi 1", difficulty: 3, allowed: Set(QuizKind.allCases), now: day(1))
        #expect(quizzes.map(\.kind) == [.mcq, .calc, .open])
        #expect(quizzes[1].answer == "0.75")
        #expect(quizzes.allSatisfy { $0.review.phase == .new && $0.subject == "Analisi 1" })
        let onlyChoice = QuizGenerator.parse(answer, nodeID: node, subject: "", difficulty: 3, allowed: [.mcq], now: day(1))
        #expect(onlyChoice.count == 1)
        #expect(QuizGenerator.parse("niente", nodeID: node, subject: "", difficulty: 3, allowed: [.mcq], now: day(1)).isEmpty)
    }

    @Test func gradesChoicesAndNumbers() {
        let choice = quiz()
        #expect(QuizGrader.gradeChoice(choice, choice: "A", seconds: 3).rating == .easy)
        #expect(QuizGrader.gradeChoice(choice, choice: "a", seconds: 30).rating == .good)
        #expect(QuizGrader.gradeChoice(choice, choice: "b", seconds: 3).rating == .again)

        let calc = QuizRecord(nodeID: nil, subject: "", kind: .calc, question: "?", answer: "1234.5", difficulty: 2, language: "it", createdAt: day(1))
        #expect(QuizGrader.gradeNumber(calc, input: "1.234,5").correct)
        #expect(QuizGrader.gradeNumber(calc, input: "1234,5").correct)
        #expect(QuizGrader.gradeNumber(calc, input: "1,234.5").correct)
        #expect(QuizGrader.gradeNumber(calc, input: "1240").correct)
        #expect(!QuizGrader.gradeNumber(calc, input: "1300").correct)
        #expect(!QuizGrader.gradeNumber(calc, input: "boh").correct)
        #expect(QuizGrader.number("3/4") == 0.75)
        #expect(QuizGrader.number("-2e-3") == -0.002)
        #expect(QuizGrader.number("\u{2212}2") == -2)
        #expect(QuizGrader.number("1.234.567") == 1_234_567)
        #expect(QuizGrader.number("12 m") == 12)
        #expect(QuizGrader.number("15%") == 15)
        #expect(QuizGrader.number("9,81 m/s²") == nil || QuizGrader.number("9,81 m/s²") == 9.81)
    }

    @Test func parsesOpenGrades() {
        #expect(QuizGrader.parseOpenGrade(#"{"score":3,"feedback":"Completa."}"#)?.rating == .easy)
        #expect(QuizGrader.parseOpenGrade(#"Ecco: {"score":1,"feedback":"Manca la definizione."}"#)?.correct == false)
        #expect(QuizGrader.parseOpenGrade(#"{"score":7}"#) == nil)
        #expect(QuizGrader.parseOpenGrade("bene") == nil)
    }
}
