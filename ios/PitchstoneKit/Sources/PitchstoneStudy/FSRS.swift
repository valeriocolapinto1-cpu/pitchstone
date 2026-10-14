import Foundation

/// Valutazione di una risposta, come nelle app di ripasso: 1 di nuovo, 2 difficile, 3 bene, 4 facile.
public enum Rating: Int, Sendable, Codable, CaseIterable, Comparable {
    case again = 1, hard, good, easy

    public static func < (a: Rating, b: Rating) -> Bool { a.rawValue < b.rawValue }
}

public enum ReviewPhase: String, Sendable, Codable {
    case new, learning, review, relearning
}

/// Stato di ripasso di un quiz (tabella `reviews` dell'architettura).
public struct ReviewState: Sendable, Equatable, Codable {
    public var due: Date
    public var stability: Double
    public var difficulty: Double
    public var reps: Int
    public var lapses: Int
    public var phase: ReviewPhase
    public var lastReview: Date?

    public init(
        due: Date, stability: Double = 0, difficulty: Double = 0, reps: Int = 0, lapses: Int = 0,
        phase: ReviewPhase = .new, lastReview: Date? = nil
    ) {
        self.due = due
        self.stability = stability
        self.difficulty = difficulty
        self.reps = reps
        self.lapses = lapses
        self.phase = phase
        self.lastReview = lastReview
    }

    public static func new(at date: Date) -> ReviewState { ReviewState(due: date) }
}

/// FSRS-5 (Free Spaced Repetition Scheduler), con i parametri predefiniti.
/// Formule da open-spaced-repetition/fsrs4anki (wiki "The Algorithm", versione 5).
/// Gli intervalli sono in giorni; "di nuovo" fa tornare il quiz dopo 10 minuti.
public struct FSRS: Sendable {
    public static let defaultWeights: [Double] = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
        1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
    ]
    static let decay = -0.5
    static let factor = 19.0 / 81.0

    public var w: [Double]
    /// Probabilità di ricordare al momento del ripasso.
    public var desiredRetention: Double
    public var maximumInterval: Int
    public static let relearnDelay: TimeInterval = 10 * 60

    public init(weights: [Double] = FSRS.defaultWeights, desiredRetention: Double = 0.9, maximumInterval: Int = 365) {
        w = weights
        self.desiredRetention = desiredRetention
        self.maximumInterval = maximumInterval
    }

    /// Probabilità di ricordare dopo `days` giorni con stabilità `stability`.
    public static func retrievability(days: Double, stability: Double) -> Double {
        guard stability > 0 else { return 0 }
        return pow(1 + factor * days / stability, decay)
    }

    /// Giorni dopo i quali la probabilità di ricordare scende a `desiredRetention`.
    public func interval(stability: Double) -> Int {
        let raw = stability / Self.factor * (pow(desiredRetention, 1 / Self.decay) - 1)
        return min(maximumInterval, max(1, Int(raw.rounded())))
    }

    public func initialStability(_ rating: Rating) -> Double {
        max(w[rating.rawValue - 1], 0.1)
    }

    public func initialDifficulty(_ rating: Rating) -> Double {
        clampDifficulty(w[4] - exp(w[5] * Double(rating.rawValue - 1)) + 1)
    }

    func nextDifficulty(_ d: Double, _ rating: Rating) -> Double {
        let delta = -w[6] * Double(rating.rawValue - 3)
        // Smorzamento lineare (FSRS-5): vicino a 10 la difficoltà cresce sempre meno.
        let damped = d + delta * (10 - d) / 9
        // Ritorno verso la difficoltà iniziale di "facile".
        return clampDifficulty(w[7] * initialDifficulty(.easy) + (1 - w[7]) * damped)
    }

    func recallStability(_ d: Double, _ s: Double, _ r: Double, _ rating: Rating) -> Double {
        let hardPenalty = rating == .hard ? w[15] : 1
        let easyBonus = rating == .easy ? w[16] : 1
        return s * (exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp(w[10] * (1 - r)) - 1) * hardPenalty * easyBonus + 1)
    }

    func forgetStability(_ d: Double, _ s: Double, _ r: Double) -> Double {
        let next = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp(w[14] * (1 - r))
        // Dopo un errore la stabilità non può superare quella di prima.
        return min(next, s)
    }

    /// Ripasso nello stesso giorno (FSRS-5).
    func shortTermStability(_ s: Double, _ rating: Rating) -> Double {
        s * exp(w[17] * (Double(rating.rawValue) - 3 + w[18]))
    }

    private func clampDifficulty(_ d: Double) -> Double { min(10, max(1, d)) }

    /// Nuovo stato dopo una risposta data in `now`.
    public func review(_ state: ReviewState, rating: Rating, now: Date) -> ReviewState {
        var next = state
        next.reps += 1
        next.lastReview = now
        if state.phase == .new || state.stability <= 0 {
            next.stability = initialStability(rating)
            next.difficulty = initialDifficulty(rating)
        } else {
            let elapsed = max(0, now.timeIntervalSince(state.lastReview ?? now) / 86_400)
            if elapsed < 1 {
                next.stability = shortTermStability(state.stability, rating)
            } else {
                let r = Self.retrievability(days: elapsed, stability: state.stability)
                next.stability = rating == .again
                    ? forgetStability(state.difficulty, state.stability, r)
                    : recallStability(state.difficulty, state.stability, r, rating)
            }
            next.difficulty = nextDifficulty(state.difficulty, rating)
        }
        next.stability = max(next.stability, 0.1)
        if rating == .again {
            if state.phase == .review { next.lapses += 1 }
            next.phase = state.phase == .new || state.phase == .learning ? .learning : .relearning
            next.due = now.addingTimeInterval(Self.relearnDelay)
        } else {
            next.phase = .review
            next.due = now.addingTimeInterval(Double(interval(stability: next.stability)) * 86_400)
        }
        return next
    }
}
