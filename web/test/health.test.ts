import { describe, expect, it } from "vitest";
import { assess, isHeld, isUnverifiable, NONE, UNVERIFIED_SIGNAL } from "../src/health";

// Gli stessi esempi di ios/PitchstoneKit/Tests/PitchstoneAITests/HealthDetectorTests.swift.
const personal = [
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
  "Oggi mi sento depresso e ho preso lo xanax.",
  "Ho preso 2 tachipirina, stavo male.",
  "Pressione stamattina 150/95, un po' alta.",
];

const notHealth = [
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
  "Domani prendo il treno per Bologna.",
  "Sto prendendo appunti sulla lezione di storia.",
  "Devo prendere il libro in biblioteca.",
  "Prendo la metro alle 8.",
  "Mi ha visitato la nonna ieri.",
  "Lezione di medicina del 14/10: anatomia del cuore.",
  "Laboratorio: ho diluito 25 ml di soluzione, i farmaci si sciolgono in acqua.",
  "In questo momento sto studiando Okinawa e la sua storia.",
];

// Altre lingue conosciute: diari e appunti di studio.
const personalOtherLanguages = [
  "Mon médecin m'a prescrit un traitement, j'ai de la fièvre depuis deux jours.",
  "Mi médico me recetó un tratamiento nuevo. Tengo fiebre y dolor de cabeza desde ayer.",
  "Mein Arzt hat mir ein Medikament verschrieben, ich habe Fieber seit gestern.",
  "Je souffre de migraine, 2 comprimés de 500 mg ce matin.",
  "Sufro de ansiedad y mi terapia empieza el lunes.",
];

const notHealthOtherLanguages = [
  "Le cours de biologie explique comment les médicaments agissent sur les récepteurs de la cellule.",
  "La enfermedad infecciosa se estudia en el curso de medicina de este semestre en la universidad.",
  "Die Vorlesung über Medikamente und ihre Wirkung findet jeden Dienstag in der Universität statt.",
];

describe("HealthDetector", () => {
  it.each(personal)("segnala la salute personale: %s", (text) => {
    const result = assess(text);
    expect(result.suspected, `${result.score} ${[...result.signals].sort()}`).toBe(true);
  });

  it.each(notHealth)("ignora appunti di studio e altro: %s", (text) => {
    const result = assess(text);
    expect(result.suspected, `${result.score} ${[...result.signals].sort()}`).toBe(false);
  });

  it("il testo vuoto va bene", () => {
    expect(assess("")).toEqual(NONE);
  });

  it.each(personalOtherLanguages)("riconosce francese, spagnolo e tedesco: %s", (text) => {
    const result = assess(text);
    expect(result.suspected, `${result.score} ${[...result.signals].sort()}`).toBe(true);
    expect(result.signals.has(UNVERIFIED_SIGNAL)).toBe(false);
  });

  it.each(notHealthOtherLanguages)("non segnala appunti di studio in altre lingue: %s", (text) => {
    const result = assess(text);
    expect(result.suspected, `${result.score} ${[...result.signals].sort()}`).toBe(false);
  });
});

describe("lingue non conosciute: a chiusura", () => {
  it("un testo in un'altra scrittura è sospetto", () => {
    for (const text of ["Сегодня я был у врача, у меня высокая температура", "今日は病院に行きました。熱があります", "اليوم ذهبت إلى الطبيب"]) {
      const result = assess(text);
      expect(result.suspected).toBe(true);
      expect(result.signals.has(UNVERIFIED_SIGNAL)).toBe(true);
      expect(isUnverifiable(text)).toBe(true);
    }
  });

  it("un testo lungo in una lingua latina non conosciuta è sospetto", () => {
    const polish = "Dzisiaj poszedłem do lekarza i opowiedziałem mu o wszystkich objawach, które mam od kilku dni, a potem zapisałem wszystkie rzeczy, które lekarz powiedział, na kartce papieru i wróciłem do domu";
    expect(isUnverifiable(polish)).toBe(true);
    expect(assess(polish).suspected).toBe(true);
  });

  it("i testi brevi o in lingue conosciute non lo sono", () => {
    for (const text of ["Nuovo nodo", "Mario Rossi", "Okinawa", "x = 2y + 3", "Appunti di analisi: le derivate si calcolano con il limite del rapporto incrementale."]) {
      expect(isUnverifiable(text)).toBe(false);
    }
    expect(isUnverifiable("The quick brown fox jumps over the lazy dog and runs to the forest with a friend")).toBe(false);
  });

  it("le formule non sono una lingua sconosciuta", () => {
    expect(isUnverifiable("Regole di derivazione\nLinearità: (af + bg)′ = af′ + bg′. Prodotto: (fg)′ = f′g + fg′. Quoziente: (f/g)′ = (f′g − fg′)/g². Composizione: (f∘g)′ = f′(g)·g′.")).toBe(false);
  });

  it("un po' di cirillico dentro un testo italiano non basta", () => {
    expect(isUnverifiable("Lezione di russo: la parola «привет» significa ciao e si usa tra amici ogni giorno in classe")).toBe(false);
  });

  it("l'utente può dichiarare innocuo il segnale, ma solo quello", () => {
    const text = "Сегодня я был у врача, у меня высокая температура";
    const result = assess(text);
    expect(isHeld(result)).toBe(true);
    expect(isHeld(result, [UNVERIFIED_SIGNAL])).toBe(false);
    // Un segnale medico nuovo, in un testo che si sa leggere, torna a bloccare.
    const medical = assess("Il mio medico dice che la pressione è 150/95.");
    expect(isHeld(medical, [UNVERIFIED_SIGNAL])).toBe(true);
    expect(isHeld(medical, medical.signals)).toBe(false);
    expect(isHeld(assess("Appunti di analisi."))).toBe(false);
  });
});
