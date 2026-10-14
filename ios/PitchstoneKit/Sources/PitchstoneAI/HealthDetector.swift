import Foundation
import PitchstoneNotes

/// Esito del controllo: i segnali trovati e se il testo sembra un dato di salute
/// personale. Gira sul dispositivo, senza modelli: decide prima di qualsiasi prompt.
public struct HealthAssessment: Sendable, Equatable {
    public var score: Int
    /// Segnali trovati (parole o forme normalizzate), per spiegare e per ricordare
    /// quelli che l'utente ha già giudicato innocui.
    public var signals: Set<String>
    public var suspected: Bool

    public static let none = HealthAssessment(score: 0, signals: [], suspected: false)
}

/// Rilevamento dei dati di salute personali (ARCHITETTURA.md, sezione 6.2).
/// Conta i termini medici, ma segnala solo quando c'è anche un indizio personale:
/// prima persona, dosi, valori misurati, visite. Gli appunti di studio di biologia
/// o medicina, scritti in modo impersonale, non vengono segnalati.
public enum HealthDetector {
    /// Punteggio minimo, con almeno un indizio personale.
    public static let threshold = 3

    public static func assess(_ text: String) -> HealthAssessment {
        let normalized = " " + TextSearch.normalize(text)
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/,.°%")).inverted)
            // Punteggiatura in fondo alla parola via: "febbre," è "febbre". Dentro resta: 140/90, 38,5°.
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
        var score = 0
        var signals = Set<String>()
        var personal = false

        for phrase in personalPhrases where normalized.contains(" \(phrase) ") {
            score += 3
            signals.insert(phrase)
            personal = true
        }
        for term in terms where normalized.contains(" \(term)") {
            score += 1
            signals.insert(term)
        }
        for (name, pattern) in patterns where matches(pattern, normalized) {
            score += 2
            signals.insert(name)
            personal = true
        }
        let firstPerson = firstPersonWords.filter { normalized.contains(" \($0) ") }.count
        if firstPerson >= 2 { personal = true }

        let healthSignals = signals.subtracting(patterns.map(\.name))
        let suspected = personal && score >= threshold && !healthSignals.isEmpty
        return HealthAssessment(score: score, signals: signals, suspected: suspected)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Frasi che parlano della propria salute: bastano da sole come indizio personale.
    static let personalPhrases = [
        "mi hanno diagnosticato", "mi ha diagnosticato", "il mio medico", "la mia dottoressa", "il mio dottore",
        "il mio psicologo", "la mia psicologa", "il mio psichiatra", "la mia psichiatra", "la mia terapia",
        "le mie analisi", "i miei esami", "ho la febbre", "ho mal di", "mi fa male", "sto prendendo",
        "devo prendere", "mi ha prescritto", "mi hanno prescritto", "mi ha visitato", "prendo il", "prendo la", "la mia pressione", "il mio ciclo", "mi sono ammalato",
        "mi sono ammalata", "sono allergico", "sono allergica", "soffro di", "ho avuto un attacco",
        "my doctor", "i was diagnosed", "my therapy", "my therapist", "my medication", "i am taking",
        "i have a fever", "my blood pressure", "i suffer from",
    ].map { TextSearch.normalize($0) }

    /// Termini medici. Il confronto è sull'inizio della parola: "farmac" prende farmaco e farmaci.
    static let terms = [
        "diagnosi", "terapi", "farmac", "medicin", "ricetta medica", "posologia", "compress", "antibiotic",
        "antidepressiv", "ansiolitic", "referto", "esami del sangue", "analisi del sangue", "glicemia",
        "colesterolo", "pressione arteriosa", "ipertension", "diabete", "tiroide", "emicrania", "febbre",
        "sintom", "allergi", "intolleranz", "psicolog", "psichiatr", "ansia", "attacchi di panico",
        "depression", "insonnia", "ciclo mestruale", "gravidanz", "visita medica", "cardiolog", "dermatolog",
        "ginecolog", "pronto soccorso", "ricovero", "ospedale", "intervento chirurgic", "fisioterapi",
        "medico di base", "vaccin", "dolore", "infiammazion",
        "diagnos", "therap", "medication", "prescription", "symptom", "blood test", "anxiety", "depression",
        "migraine", "allerg", "hospital", "surgery", "doctor", "fever",
    ].map { TextSearch.normalize($0) }

    /// Indizi personali misurabili: dosi, valori, visite fissate.
    static let patterns: [(name: String, pattern: String)] = [
        ("dose", #" \d+([,.]\d+)? ?(mg|mcg|µg|ml|gocce|ui)\b"#),
        ("pressione misurata", #" \d{2,3}/\d{2,3}\b"#),
        ("valore di laboratorio", #" \d+([,.]\d+)? ?mg/dl\b"#),
        ("temperatura", #" 3[6-9]([,.]\d)? ?°"#),
        ("visita fissata", #" (visita|controllo|appuntamento) (dal|dalla|con il|con la|dallo) "#),
    ]

    /// Due di queste parole fanno un testo in prima persona. "sono" e "i" no:
    /// in italiano sono anche terza persona plurale e articolo.
    static let firstPersonWords = ["ho", "mi", "mio", "mia", "miei", "mie", "sto", "my", "me"]
}
