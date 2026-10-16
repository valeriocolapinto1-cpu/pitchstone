import Foundation
import Observation
import PitchstoneAI
import PitchstoneStore
import PitchstoneStudy
import PitchstoneSync
import SwiftData
import UserNotifications

/// Quiz, ripasso FSRS, streak, obiettivi e promemoria (ADR 0011). Tutto locale.
@MainActor
@Observable
final class StudyModel {
    private(set) var quizzes: [QuizRecord] = []
    private(set) var logs: [ReviewLogRecord] = []
    /// Nodi con domande aperte o di calcolo da generare quando torna la connessione.
    private(set) var queuedGenerations: [UUID] = []
    /// Livello 1-5 per materia: osservato, così il selettore si aggiorna subito.
    private(set) var levels: [String: Int] = [:]
    @ObservationIgnored private var retrying = false

    let store: StudyStore
    @ObservationIgnored let notes: NotesModel
    @ObservationIgnored let fsrs = FSRS()
    @ObservationIgnored var plan = StudyPlan()
    @ObservationIgnored private let defaults: UserDefaults
    /// Nei test: orologio fisso e niente notifiche vere.
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var notificationsEnabled = true

    init(container: ModelContainer, notes: NotesModel, defaults: UserDefaults = .standard) {
        store = StudyStore(container: container)
        self.notes = notes
        self.defaults = defaults
        queuedGenerations = (defaults.array(forKey: "quizQueue") as? [String] ?? []).compactMap(UUID.init(uuidString:))
        levels = defaults.dictionary(forKey: "quizLevels") as? [String: Int] ?? [:]
        goal = StudyGoal(
            targetQuizzes: defaults.object(forKey: "goalQuizzes") as? Int ?? 100,
            targetMinutes: defaults.object(forKey: "goalMinutes") as? Int ?? 120)
        reload()
    }

    func reload() {
        quizzes = store.quizzes()
        logs = store.logs()
        // Quiz di nodi eliminati per sempre: non torneranno, si tolgono con il loro registro.
        let orphans = Set(quizzes.filter { $0.nodeID != nil && notes.store.node($0.nodeID!) == nil }.map(\.id))
        if !orphans.isEmpty {
            store.delete(orphans)
            quizzes = store.quizzes()
            logs = store.logs()
        }
    }

    // MARK: Ripasso

    /// Quiz utilizzabili: il loro nodo esiste ancora e non è un dato di salute.
    var activeQuizzes: [QuizRecord] {
        quizzes.filter { quiz in
            guard let id = quiz.nodeID else { return true }
            guard let node = notes.node(id), node.deletedAt == nil else { return false }
            return !notes.isSensitive(id)
        }
    }

    var queue: [QuizRecord] { plan.queue(activeQuizzes, logs: logs, now: now()) }
    /// Ripassi in anticipo quando non c'è niente da fare: lo streak si tiene anche nei giorni vuoti.
    var practice: [QuizRecord] { plan.practice(activeQuizzes, now: now()) }
    var streak: Int { plan.streak(logs, now: now()) }
    var dueToday: Int { plan.dueCount(activeQuizzes, on: now()) }

    var goal = StudyGoal() {
        didSet {
            defaults.set(goal.targetQuizzes, forKey: "goalQuizzes")
            defaults.set(goal.targetMinutes, forKey: "goalMinutes")
        }
    }

    var week: StudyPlan.WeekProgress { plan.week(logs, goal: goal, now: now()) }

    /// Registra una risposta: FSRS aggiorna la scadenza, il livello della materia si adatta.
    func answer(_ quiz: QuizRecord, rating: Rating, duration: TimeInterval) {
        let date = now()
        let review = fsrs.review(quiz.review, rating: rating, now: date)
        // Un quiz lasciato aperto non gonfia i minuti della settimana: al massimo 5 minuti.
        let ms = Int(min(duration, 300) * 1000)
        store.record(ReviewLogRecord(quizID: quiz.id, rating: rating, answeredAt: date, durationMs: ms), review: review)
        reload()
        let ratings = logs.compactMap { log in
            quizzes.first { $0.id == log.quizID }?.subject == quiz.subject ? log.rating : nil
        }
        // Il livello si rivede ogni 10 risposte della materia, non a ogni risposta.
        if ratings.count % 10 == 0 {
            setLevel(StudyPlan.adaptedLevel(current: level(for: quiz.subject), recentRatings: ratings), for: quiz.subject)
        }
        scheduleReminders()
    }

    // MARK: Livello per materia

    func level(for subject: String) -> Int {
        levels[subject] ?? 3
    }

    func setLevel(_ level: Int, for subject: String) {
        levels[subject] = min(5, max(1, level))
        defaults.set(levels, forKey: "quizLevels")
    }

    var subjects: [String] { Array(Set(activeQuizzes.map(\.subject))).sorted() }

    /// La materia di un appunto: l'esame a cui è collegato, altrimenti l'area.
    func subject(for node: NodeRecord) -> String {
        if node.type == .exam { return node.title }
        let neighbors = notes.edges.filter { $0.deletedAt == nil && ($0.sourceID == node.id || $0.targetID == node.id) }
            .map { $0.sourceID == node.id ? $0.targetID : $0.sourceID }
        if let exam = (neighbors.compactMap { notes.node($0) }).first(where: { $0.type == .exam && $0.deletedAt == nil }) {
            return exam.title
        }
        return node.area.name
    }

    // MARK: Generazione

    enum GenerationError: Error, Equatable {
        case subjectFull
        case nothingGenerated
    }

    /// Quiz da un appunto. Online con Gemini: risposta multipla, domande aperte e calcoli.
    /// Senza Gemini: solo risposta multipla con il modello locale; aperte e calcoli restano in coda.
    @discardableResult
    func generate(from nodeID: UUID, onlineOnly: Bool = false) async throws -> Int {
        guard let node = notes.node(nodeID), node.deletedAt == nil, !notes.isSensitive(nodeID) else {
            throw ChatError.sensitiveContent
        }
        let subject = subject(for: node)
        let room = QuizGenerator.maxPerSubject - activeQuizzes.filter { $0.subject == subject }.count
        guard room > 0 else { throw GenerationError.subjectFull }
        let level = level(for: subject)
        let providers = notes.quizProviders
        var made: [QuizRecord] = []
        var lastError: Error = GenerationError.nothingGenerated

        if let online = providers.online, await online.isAvailable() {
            do {
                made = try await ask(online, node: node, subject: subject, level: level, kinds: QuizKind.allCases)
                dequeue(nodeID)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        if made.isEmpty, !onlineOnly, let local = providers.local, await local.isAvailable() {
            do {
                made = try await ask(local, node: node, subject: subject, level: level, kinds: [.mcq])
                // Le domande aperte e di calcolo arriveranno con Gemini.
                if providers.online != nil || notes.workerTransport != nil { enqueue(nodeID) }
            } catch {
                lastError = error
            }
        }
        guard !made.isEmpty else { throw lastError }
        let existing = Set(quizzes.map { $0.question.lowercased() })
        let fresh = made.filter { !existing.contains($0.question.lowercased()) }.prefix(room)
        store.insert(Array(fresh))
        reload()
        scheduleReminders()
        return fresh.count
    }

    private func ask(_ provider: ChatProvider, node: NodeRecord, subject: String, level: Int, kinds: [QuizKind]) async throws -> [QuizRecord] {
        let prompt = QuizGenerator.prompt(for: node, kinds: kinds, difficulty: level, budget: provider.budget)
        let answer = try await provider.reply(to: prompt)
        let quizzes = QuizGenerator.parse(
            answer, nodeID: node.id, subject: subject, difficulty: level, allowed: Set(kinds), now: now())
        guard !quizzes.isEmpty else { throw ChatError.invalidAnswer }
        return quizzes
    }

    private func enqueue(_ id: UUID) {
        guard !queuedGenerations.contains(id) else { return }
        queuedGenerations.append(id)
        defaults.set(queuedGenerations.map(\.uuidString), forKey: "quizQueue")
    }

    private func dequeue(_ id: UUID) {
        queuedGenerations.removeAll { $0 == id }
        defaults.set(queuedGenerations.map(\.uuidString), forKey: "quizQueue")
    }

    /// Riprova le generazioni in coda (all'avvio e dopo una sync riuscita).
    func retryQueued() async {
        guard !retrying, let online = notes.quizProviders.online, await online.isAvailable() else { return }
        retrying = true
        defer { retrying = false }
        for id in queuedGenerations {
            guard let node = notes.node(id), node.deletedAt == nil, !notes.isSensitive(id) else {
                dequeue(id)
                continue
            }
            do {
                // Solo Gemini: le domande a risposta multipla del modello locale ci sono già.
                _ = try await generate(from: id, onlineOnly: true)
            } catch GenerationError.subjectFull {
                dequeue(id)
            } catch {
                continue
            }
        }
    }

    // MARK: Correzione delle domande aperte

    /// Voto dell'AI (Gemini, o il modello locale). Nil se nessun modello risponde:
    /// l'utente si valuta da solo guardando la risposta modello.
    func gradeOpen(_ quiz: QuizRecord, answer: String) async -> QuizGrade? {
        let providers = notes.quizProviders
        for provider in [providers.online, providers.local].compactMap({ $0 }) {
            guard await provider.isAvailable(),
                  let reply = try? await provider.reply(to: QuizGrader.openGradingPrompt(quiz, answer: answer)),
                  let grade = QuizGrader.parseOpenGrade(reply) else { continue }
            return grade
        }
        return nil
    }

    // MARK: Promemoria

    func scheduleReminders() {
        guard notificationsEnabled else { return }
        let reminders = ReminderPlanner(plan: plan).reminders(quizzes: activeQuizzes, logs: logs, now: now())
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: PlannedReminder.allIdentifiers)
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            let interval = reminder.fireDate.timeIntervalSince(now())
            let trigger: UNNotificationTrigger = interval < 5
                ? UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
                : UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate),
                    repeats: false)
            center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger))
        }
    }

    /// Chiesto la prima volta che si usano i quiz, non all'avvio.
    func requestNotificationPermission() async {
        guard notificationsEnabled else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        scheduleReminders()
    }
}
