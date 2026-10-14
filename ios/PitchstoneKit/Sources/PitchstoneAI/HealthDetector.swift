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

        for phrase in healthPhrases where normalized.contains(" \(phrase) ") {
            score += 3
            signals.insert(phrase)
            personal = true
        }
        // Frasi comuni ("prendo il", "sto male"): dicono che il testo è personale, non che parla di salute.
        for phrase in personalPhrases where normalized.contains(" \(phrase) ") {
            score += 1
            personal = true
        }
        for term in terms where normalized.contains(" \(term)") {
            score += 1
            signals.insert(term)
        }
        for (name, pattern, weight) in patterns where matches(pattern, normalized) {
            score += weight
            signals.insert(name)
            personal = true
        }
        let firstPerson = firstPersonWords.filter { normalized.contains(" \($0) ") }.count
        if firstPerson >= 2 { personal = true }

        // Serve almeno un segnale medico vero: le dosi o una frase generica da sole non bastano.
        let healthSignals = signals.subtracting(contextPatterns)
        let suspected = personal && score >= threshold && !healthSignals.isEmpty
        return HealthAssessment(score: score, signals: signals, suspected: suspected)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Frasi che parlano della propria salute: segnale medico e indizio personale insieme.
    static let healthPhrases = unique([
        "mi hanno diagnosticato", "mi ha diagnosticato", "il mio medico", "la mia dottoressa", "il mio dottore",
        "il mio psicologo", "la mia psicologa", "il mio psichiatra", "la mia psichiatra", "la mia terapia",
        "le mie analisi", "i miei esami", "ho la febbre", "ho mal di", "mi fa male", "mi ha prescritto",
        "mi hanno prescritto", "la mia pressione", "il mio ciclo", "mi sono ammalato", "mi sono ammalata",
        "sono allergico", "sono allergica", "soffro di", "ho avuto un attacco di panico",
        "my doctor", "i was diagnosed", "my therapy", "my therapist", "my medication", "i have a fever",
        "my blood pressure", "i suffer from",
    ])

    /// Frasi personali senza contenuto medico: contano solo insieme a un termine medico.
    static let personalPhrases = unique([
        "sto prendendo", "devo prendere", "prendo il", "prendo la", "ho preso", "mi sento", "sto male",
        "stavo male", "mi ha visitato", "i am taking", "i took", "i feel",
    ])

    /// Termini medici. Il confronto è sull'inizio della parola: "farmac" prende farmaco e farmaci.
    static let terms = unique([
        "diagnos", "terapi", "farmac", "medicin", "ricetta medica", "posologia", "compress", "antibiotic",
        "antidepressiv", "ansiolitic", "referto", "esami del sangue", "analisi del sangue", "glicemia",
        "colesterolo", "pressione arteriosa", "ipertension", "diabete", "tiroide", "emicrania", "febbre",
        "sintom", "allerg", "intolleranz", "psicolog", "psichiatr", "ansia", "attacchi di panico", "depress",
        "insonnia", "ciclo mestruale", "gravidanz", "visita medica", "cardiolog", "dermatolog", "ginecolog",
        "pronto soccorso", "ricovero", "ospedale", "intervento chirurgic", "fisioterapi", "medico di base",
        "vaccin", "dolore", "infiammazion", "mal di testa", "mal di gola", "nausea",
        "tachipirina", "paracetamolo", "ibuprofene", "aspirina", "brufen", "xanax", "lexotan",
        "sertralina", "cortison", "antistaminic", "insulina", "ventolin",
        "therap", "medication", "prescription", "symptom", "blood test", "anxiety", "migraine", "hospital",
        "surgery", "doctor", "fever", "headache",
    ])

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.map { TextSearch.normalize($0) }.filter { seen.insert($0).inserted }
    }

    /// Indizi personali misurabili: dosi, valori, visite fissate.
    /// Indizi che dicono "personale" ma non "salute": una dose da sola, una data con "controllo dal".
    static let contextPatterns: Set<String> = ["dose", "temperatura", "visita fissata"]

    static let patterns: [(name: String, pattern: String, weight: Int)] = [
        // Unità da farmaco, non da cucina o laboratorio di chimica: niente ml.
        ("dose", #" \d+([,.]\d+)? ?(mg|mcg|[µμ]g|gocce|ui|compresse|cp)\b"#, 2),
        // Con il contesto: 14/10 da solo è una data.
        ("pressione misurata", #"(pressione|mmhg|max|min)[^0-9]{0,15}\d{2,3}/\d{2,3}\b(?!/)|\d{2,3}/\d{2,3} ?mmhg"#, 3),
        ("valore di laboratorio", #" \d+([,.]\d+)? ?mg/dl\b"#, 2),
        ("temperatura", #" 3[6-9]([,.]\d)? ?°"#, 2),
        ("visita fissata", #" (visita|controllo|appuntamento) (dal|dalla|con il|con la|dallo) "#, 2),
    ]

    /// Due di queste parole fanno un testo in prima persona. "sono" e "i" no:
    /// in italiano sono anche terza persona plurale e articolo.
    static let firstPersonWords = ["ho", "mi", "mio", "mia", "miei", "mie", "sto", "my", "me"]
}
