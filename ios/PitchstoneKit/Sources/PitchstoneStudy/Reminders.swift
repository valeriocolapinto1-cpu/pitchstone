import Foundation

/// Una notifica locale da programmare.
public struct PlannedReminder: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Ogni mattina alle 8, se ci sono ripassi.
        case morning
        /// Il primo giorno saltato, a mezzanotte.
        case missed
    }

    public var kind: Kind
    public var fireDate: Date
    public var title: String
    public var body: String
    /// Giorno da oggi, per i promemoria delle 8 (uno per giorno).
    public var day: Int = 0

    public var identifier: String { kind == .morning ? "pitchstone.morning.\(day)" : "pitchstone.\(kind.rawValue)" }

    /// Tutti gli identificatori possibili, per cancellare i promemoria vecchi.
    public static var allIdentifiers: [String] {
        (0...ReminderPlanner.morningDays).map { "pitchstone.morning.\($0)" } + ["pitchstone.missed", "pitchstone.morning"]
    }
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

    /// Giorni coperti dai promemoria delle 8: se l'app non si apre per qualche giorno
    /// i promemoria continuano ad arrivare.
    public static let morningDays = 7

    public func reminders(quizzes: [QuizRecord], logs: [ReviewLogRecord], now: Date) -> [PlannedReminder] {
        let calendar = plan.calendar
        var result: [PlannedReminder] = []
        let today = calendar.startOfDay(for: now)
        let studiedToday = logs.contains { $0.answeredAt >= today }

        // Le prossime mattine alle 8, ognuna con i ripassi di quel giorno. Oggi solo se non
        // sono ancora passate le 8 e non si è già studiato.
        for offset in 0...Self.morningDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let at8 = calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: day),
                  at8 > now, !(offset == 0 && studiedToday) else { continue }
            let due = plan.dueCount(quizzes, on: at8)
            guard due > 0 else { continue }
            result.append(PlannedReminder(
                kind: .morning, fireDate: at8, title: "Ripasso di oggi",
                body: due == 1 ? "Hai 1 ripasso in scadenza." : "Hai \(due) ripassi in scadenza.", day: offset))
        }

        // Il primo giorno saltato: a mezzanotte, nel momento in cui lo streak si perde.
        // Oggi se non si è ancora studiato, altrimenti domani. Una risposta riprogramma tutto,
        // quindi l'avviso sparisce appena si studia; dopo il primo giorno saltato non ce ne sono altri.
        let streak = plan.streak(logs, now: now)
        if streak > 0, !quizzes.isEmpty,
           let midnight = calendar.date(byAdding: .day, value: studiedToday ? 2 : 1, to: today) {
            result.append(PlannedReminder(
                kind: .missed, fireDate: midnight, title: "Streak interrotto",
                body: "Ieri non hai ripassato: lo streak di \(streak) giorni riparte da zero. Riprendi oggi."))
        }
        return result
    }
}
