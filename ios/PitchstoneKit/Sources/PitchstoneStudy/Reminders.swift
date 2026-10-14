import Foundation

/// Una notifica locale da programmare.
public struct PlannedReminder: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Ogni mattina alle 8, se ci sono ripassi.
        case morning
        /// Il primo giorno saltato: subito, o a mezzanotte se oggi non si ripassa.
        case missed
    }

    public var kind: Kind
    public var fireDate: Date
    public var title: String
    public var body: String

    public var identifier: String { "pitchstone.\(kind.rawValue)" }
}

/// Promemoria del ripasso (ARCHITETTURA.md, sezione 2): ogni mattina alle 8 se ci
/// sono ripassi; avviso immediato al primo giorno saltato. Logica pura: l'app
/// riprogramma le notifiche a ogni avvio, uscita e fine sessione.
public struct ReminderPlanner: Sendable {
    public static let morningHour = 8
    public var plan: StudyPlan

    public init(plan: StudyPlan = StudyPlan()) {
        self.plan = plan
    }

    public func reminders(quizzes: [QuizRecord], logs: [ReviewLogRecord], now: Date) -> [PlannedReminder] {
        let calendar = plan.calendar
        var result: [PlannedReminder] = []
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }

        // Prossime 8: oggi se non sono ancora passate, altrimenti domani.
        let todayAt8 = calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: today)!
        let morning = now < todayAt8 ? todayAt8 : calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: tomorrow)!
        let dueThen = plan.dueCount(quizzes, on: morning)
        if dueThen > 0 {
            result.append(PlannedReminder(
                kind: .morning, fireDate: morning, title: "Ripasso di oggi",
                body: dueThen == 1 ? "Hai 1 ripasso in scadenza." : "Hai \(dueThen) ripassi in scadenza."))
        }

        let studiedToday = logs.contains { $0.answeredAt >= today }
        let studiedYesterday = calendar.date(byAdding: .day, value: -1, to: today).map { yesterday in
            logs.contains { $0.answeredAt >= yesterday && $0.answeredAt < today }
        } ?? false
        let streak = plan.streak(logs, now: now)
        // Ieri c'erano ripassi e non si è studiato: avviso subito (lo streak è già perso).
        let hadDueYesterday = quizzes.contains { $0.review.phase != .new && $0.review.due < today }
        if !studiedToday, !studiedYesterday, hadDueYesterday, !logs.isEmpty {
            result.append(PlannedReminder(
                kind: .missed, fireDate: now, title: "Ripasso saltato",
                body: "Ieri non hai ripassato: riprendi oggi con i quiz in scadenza."))
        } else if !studiedToday, streak > 0, plan.dueCount(quizzes, on: now) > 0 {
            // Streak in corso e ripassi di oggi non fatti: avviso a mezzanotte, annullato se si studia.
            result.append(PlannedReminder(
                kind: .missed, fireDate: tomorrow, title: "Streak interrotto",
                body: "Oggi non hai ripassato: lo streak di \(streak) giorni riparte da zero."))
        }
        return result
    }
}
