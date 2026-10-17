import Foundation
import PitchstoneAI
import PitchstoneNotes
import PitchstoneSync

public enum QuizKind: String, Sendable, Codable, CaseIterable {
    /// Risposta multipla.
    case mcq
    /// Domanda aperta, corretta dall'AI.
    case open
    /// Esercizio di calcolo con risultato numerico.
    case calc
}

/// Un quiz generato da un appunto (tabella `quizzes` dell'architettura).
public struct QuizRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var nodeID: UUID?
    /// Materia: il titolo dell'esame collegato all'appunto, o l'area.
    public var subject: String
    public var kind: QuizKind
    public var question: String
    public var options: [String]
    public var answer: String
    public var explanation: String
    public var difficulty: Int
    public var language: String
    public var createdAt: Date
    public var review: ReviewState

    public init(
        id: UUID = UUID(), nodeID: UUID?, subject: String, kind: QuizKind, question: String, options: [String] = [],
        answer: String, explanation: String = "", difficulty: Int, language: String, createdAt: Date, review: ReviewState? = nil
    ) {
        self.id = id
        self.nodeID = nodeID
        self.subject = subject
        self.kind = kind
        self.question = question
        self.options = options
        self.answer = answer
        self.explanation = explanation
        self.difficulty = min(5, max(1, difficulty))
        self.language = language
        self.createdAt = createdAt
        self.review = review ?? .new(at: createdAt)
    }
}

/// Una risposta data (tabella `review_logs`).
public struct ReviewLogRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var quizID: UUID
    public var rating: Rating
    public var answeredAt: Date
    public var durationMs: Int?

    public init(id: UUID = UUID(), quizID: UUID, rating: Rating, answeredAt: Date, durationMs: Int? = nil) {
        self.id = id
        self.quizID = quizID
        self.rating = rating
        self.answeredAt = answeredAt
        self.durationMs = durationMs
    }
}

/// Esito della correzione di una risposta: giusta o no, e la valutazione per FSRS.
public struct QuizGrade: Sendable, Equatable {
    public var correct: Bool
    public var rating: Rating
    public var feedback: String

    public init(correct: Bool, rating: Rating, feedback: String) {
        self.correct = correct
        self.rating = rating
        self.feedback = feedback
    }
}

public enum QuizGenerator {
    /// Al massimo 200 quiz per materia (ARCHITETTURA.md, sezione 2).
    public static let maxPerSubject = 200
    public static let perNote = 5

    public static func instructions(kinds: [QuizKind], difficulty: Int) -> String {
        let kindsText = kinds.map(\.rawValue).joined(separator: ", ")
        return """
        Crei quiz di studio da un appunto, nella lingua dell'appunto. Rispondi SOLO con un oggetto JSON: \
        {"language":"it","quizzes":[{"kind":"mcq","question":"...","options":["...","...","...","..."],\
        "answer":"...","explanation":"..."}]}. Tipi ammessi: \(kindsText). "mcq": 4 opzioni, "answer" è il testo \
        esatto dell'opzione giusta. "open": domanda aperta, "answer" è la risposta modello in poche frasi. \
        "calc": esercizio con un solo risultato numerico, "answer" è solo il numero, con il punto come separatore \
        decimale e senza separatori delle migliaia. \
        Al massimo \(perNote) quiz, livello di difficoltà \(difficulty) su 5. Usa solo ciò che c'è nell'appunto; \
        "explanation" spiega in una o due frasi perché la risposta è giusta.
        """
    }

    /// Il prompt per un appunto. Mai per un nodo di salute o sospetto: lo decide chi chiama.
    public static func prompt(for node: NodeRecord, kinds: [QuizKind], difficulty: Int, budget: TokenBudget) -> ChatPrompt {
        let instructions = instructions(kinds: kinds, difficulty: difficulty)
        let free = max(200, budget.total - budget.answer - TokenBudget.estimate(instructions) - 40) * 3
        let title = String(node.title.prefix(200))
        let question = "TITOLO: \(title)\nAPPUNTO:\n" + String(node.bodyMD.prefix(max(0, free - title.count - 30)))
        return ChatPrompt(instructions: instructions, sources: [], history: [], question: question, localOnly: false,
                          includesSources: false)
    }

    /// Come `prompt`, ma rifiuta un nodo di salute o sospetto e non ancora giudicato innocuo dall'utente:
    /// ultima difesa prima che il testo parta per un modello.
    public static func checkedPrompt(
        for node: NodeRecord, kinds: [QuizKind], difficulty: Int, budget: TokenBudget, dismissedSignals: Set<String> = []
    ) throws -> ChatPrompt {
        let assessment = HealthDetector.assess(node.title + "\n" + node.bodyMD)
        guard !Privacy.isSensitive(node), !assessment.suspected || assessment.signals.isSubset(of: dismissedSignals) else {
            throw ChatError.sensitiveContent
        }
        return prompt(for: node, kinds: kinds, difficulty: difficulty, budget: budget)
    }

    /// Quiz validi dalla risposta del modello: le risposte multiple senza 3-6 opzioni distinte
    /// o con una risposta che non è tra le opzioni si scartano, come i calcoli non numerici.
    public static func parse(
        _ answer: String, nodeID: UUID, subject: String, difficulty: Int, allowed: Set<QuizKind>, now: Date
    ) -> [QuizRecord] {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let data = String(answer[start...end]).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let language = (raw["language"] as? String).map { String($0.prefix(5)) } ?? "it"
        var seen = Set<String>()
        var result: [QuizRecord] = []
        for item in raw["quizzes"] as? [[String: Any]] ?? [] {
            guard let kind = (item["kind"] as? String).flatMap(QuizKind.init(rawValue:)), allowed.contains(kind),
                  let question = (item["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !question.isEmpty, question.count <= 1000,
                  let solution = (item["answer"].map { "\($0)" })?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !solution.isEmpty, seen.insert(TextSearch.normalize(question)).inserted
            else { continue }
            let options = (item["options"] as? [Any] ?? []).map { "\($0)".trimmingCharacters(in: .whitespacesAndNewlines) }
            switch kind {
            case .mcq:
                let distinct = Set(options.map(TextSearch.normalize))
                guard (3...6).contains(options.count), distinct.count == options.count,
                      options.contains(where: { TextSearch.normalize($0) == TextSearch.normalize(solution) }) else { continue }
            case .calc:
                guard QuizGrader.number(solution) != nil else { continue }
            case .open:
                break
            }
            // I modelli mettono spesso la risposta giusta per prima: si mescola.
            result.append(QuizRecord(
                nodeID: nodeID, subject: subject, kind: kind, question: question, options: kind == .mcq ? options.shuffled() : [],
                answer: solution, explanation: (item["explanation"] as? String) ?? "", difficulty: difficulty,
                language: language, createdAt: now))
            if result.count == perNote { break }
        }
        return result
    }
}

public enum QuizGrader {
    /// Risposta multipla: giusta è "bene", entro 8 secondi "facile"; sbagliata è "di nuovo".
    public static func gradeChoice(_ quiz: QuizRecord, choice: String, seconds: Double) -> QuizGrade {
        let correct = TextSearch.normalize(choice) == TextSearch.normalize(quiz.answer)
        return QuizGrade(
            correct: correct, rating: correct ? (seconds <= 8 ? .easy : .good) : .again,
            feedback: correct ? "Giusto." : "La risposta giusta è: \(quiz.answer)")
    }

    /// Calcolo: confronto numerico con tolleranza relativa dell'1%, virgola o punto decimale.
    public static func gradeNumber(_ quiz: QuizRecord, input: String) -> QuizGrade {
        guard let expected = number(quiz.answer) else {
            return QuizGrade(correct: false, rating: .again, feedback: "Risultato atteso non valido.")
        }
        guard let given = number(input) else {
            return QuizGrade(correct: false, rating: .again, feedback: "Scrivi solo il numero. Risultato: \(quiz.answer)")
        }
        let tolerance = max(abs(expected) * 0.01, 1e-9)
        let correct = abs(given - expected) <= tolerance
        return QuizGrade(
            correct: correct, rating: correct ? .good : .again,
            feedback: correct ? "Giusto." : "Il risultato è \(quiz.answer).")
    }

    /// "3,5", "3.5", "1.234,5", "1.234.567", "1e-3", "−2", "12 m", "15%"; frazioni semplici "3/4".
    public static func number(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
        // Unità o percentuale in fondo: contano solo le cifre.
        while let last = t.last, last.isLetter || last == "%" || last == "°", !t.hasSuffix("e") {
            t.removeLast()
        }
        // Più punti (o più virgole) sono separatori delle migliaia.
        if t.filter({ $0 == "." }).count > 1 { t = t.replacingOccurrences(of: ".", with: "") }
        if t.filter({ $0 == "," }).count > 1 { t = t.replacingOccurrences(of: ",", with: "") }
        if let slash = t.firstIndex(of: "/"), let a = number(String(t[..<slash])), let b = number(String(t[t.index(after: slash)...])), b != 0 {
            return a / b
        }
        // Con entrambi i separatori, l'ultimo è quello decimale: 1.234,5 e 1,234.5.
        if let comma = t.lastIndex(of: ","), let dot = t.lastIndex(of: ".") {
            t = comma > dot ? t.replacingOccurrences(of: ".", with: "") : t.replacingOccurrences(of: ",", with: "")
        }
        t = t.replacingOccurrences(of: ",", with: ".")
        return Double(t)
    }

    public static func openGradingInstructions() -> String {
        """
        Correggi la risposta di uno studente. Rispondi SOLO con un JSON: \
        {"score":0-3,"feedback":"..."}. 0 sbagliata, 1 parziale con errori importanti, 2 giusta ma incompleta, \
        3 giusta e completa. "feedback" in una o due frasi, nella lingua della domanda, dice cosa manca o cosa è sbagliato.
        """
    }

    public static func openGradingPrompt(_ quiz: QuizRecord, answer: String) -> ChatPrompt {
        ChatPrompt(
            instructions: openGradingInstructions(), sources: [], history: [],
            question: "DOMANDA: \(quiz.question)\nRISPOSTA MODELLO: \(quiz.answer)\nRISPOSTA DELLO STUDENTE: \(String(answer.prefix(4000)))",
            localOnly: false, includesSources: false)
    }

    /// Il voto dell'AI diventa una valutazione: 0 di nuovo, 1 difficile, 2 bene, 3 facile.
    public static func parseOpenGrade(_ answer: String) -> QuizGrade? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let data = String(answer[start...end]).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let score = (raw["score"] as? NSNumber)?.intValue, (0...3).contains(score)
        else { return nil }
        let rating: Rating = [.again, .hard, .good, .easy][score]
        return QuizGrade(correct: score >= 2, rating: rating, feedback: (raw["feedback"] as? String) ?? "")
    }
}
