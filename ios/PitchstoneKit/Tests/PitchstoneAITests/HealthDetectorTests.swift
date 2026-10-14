import Testing
@testable import PitchstoneAI

/// Set di esempi per il rilevamento della salute (criterio della fase 6):
/// diari e promemoria personali da una parte, appunti di studio e altro dall'altra.
@Suite struct HealthDetectorTests {
    static let personal = [
        "Oggi visita dal cardiologo: pressione 145/95. Devo prendere ramipril 5 mg ogni mattina.",
        "Mi hanno diagnosticato l'emicrania. Il neurologo dice di tenere un diario.",
        "Ho mal di testa da tre giorni e un po' di febbre, 38,2°",
        "Glicemia a digiuno 112 mg/dl, colesterolo alto. Ricontrollare tra tre mesi col medico di base.",
        "Seduta con la mia psicologa: abbiamo parlato dell'ansia e degli attacchi di panico.",
        "Sono allergica alle arachidi e al lattice.",
        "Il mio ciclo è in ritardo di una settimana, test di gravidanza negativo.",
        "Started sertraline 50 mg, my therapist says to wait two weeks for effects.",
        "I was diagnosed with type 2 diabetes last year.",
        "Promemoria: controllo dal dermatologo il 12 marzo per il neo sulla schiena.",
        "Antibiotico: amoxicillina 1 g ogni 12 ore per 6 giorni. Mi fa male la gola.",
        "Insonnia anche stanotte, ho dormito tre ore. Il medico mi ha prescritto la melatonina.",
    ]

    static let notHealth = [
        "La farmacologia studia l'assorbimento dei farmaci. La biodisponibilità dipende dalla via di somministrazione.",
        "La pressione è il rapporto tra forza e superficie: 1 Pa = 1 N/m².",
        "Il diabete di tipo 1 è una malattia autoimmune; l'insulina regola la glicemia.",
        "Leopardi descrive il dolore come condizione universale dell'uomo.",
        "Esame di Analisi 1: ho studiato le derivate, mi mancano gli integrali.",
        "Progetto app: la mia idea è usare SwiftUI e SwiftData, ho finito il prototipo.",
        "Riunione con il cliente: controllo dal vivo del prototipo.",
        "The immune system protects against infections; vaccines train adaptive immunity.",
        "Ricetta: 200 g di farina, 100 ml di latte, 2 uova.",
        "Psicologia cognitiva: memoria di lavoro e attenzione (Baddeley).",
        "Ho letto un articolo sull'ansia da prestazione negli atleti, interessante per la tesi.",
        "Il mio cane ha la febbre, domani lo porto dal veterinario.",
        "Chimica: una soluzione 0,5 mol/l; titolazione con 25 ml di NaOH.",
        "Gravidanza e parto nella letteratura dell'Ottocento: Verga e Manzoni.",
        "Ospedale da campo della Croce Rossa nella prima guerra mondiale, i feriti e i sintomi da gas.",
        "I mitocondri sono gli organelli che producono energia; i farmaci possono danneggiarli.",
    ]

    @Test(arguments: personal)
    func flagsPersonalHealth(_ text: String) {
        let result = HealthDetector.assess(text)
        #expect(result.suspected, "\(result.score) \(result.signals.sorted())")
    }

    @Test(arguments: notHealth)
    func ignoresStudyNotesAndOtherText(_ text: String) {
        let result = HealthDetector.assess(text)
        #expect(!result.suspected, "\(result.score) \(result.signals.sorted())")
    }

    @Test func emptyTextIsFine() {
        #expect(HealthDetector.assess("") == .none)
    }
}
