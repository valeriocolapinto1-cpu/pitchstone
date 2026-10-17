// Rilevamento dei dati di salute personali sul PC (ARCHITETTURA.md, sezione 6.2).
// È il gemello di ios/PitchstoneKit/Sources/PitchstoneAI/HealthDetector.swift: stesse frasi, stessi
// termini, stesse soglie, e gli stessi esempi nei test. Se si cambia uno, si cambia l'altro.
//
// Conta i termini medici, ma segnala solo quando c'è anche un indizio personale: prima persona, dosi,
// valori misurati, visite. Gli appunti di studio di biologia o medicina, scritti in modo impersonale, non
// vengono segnalati. Funziona per italiano, inglese, francese, spagnolo e tedesco; un testo in un'altra
// lingua (o in un'altra scrittura) non si può giudicare e si tratta come sospetto: a chiusura.

export interface HealthAssessment {
  score: number;
  /** Segnali trovati, per spiegare e per ricordare quelli che l'utente ha già giudicato innocui. */
  signals: Set<string>;
  suspected: boolean;
}

/** Punteggio minimo, con almeno un indizio personale. */
export const THRESHOLD = 3;

/** Segnale dei testi in una lingua che il rilevatore non conosce. */
export const UNVERIFIED_SIGNAL = "lingua non verificabile";

/** Senza maiuscole, accenti, accenti di larghezza e spazi doppi (come TextSearch.normalize dell'iPad). */
export function normalize(text: string): string {
  return text.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase().split(/\s+/).filter(Boolean).join(" ");
}

function unique(items: string[]): string[] {
  return [...new Set(items.map(normalize))];
}

/** Frasi che parlano della propria salute: segnale medico e indizio personale insieme. */
const HEALTH_PHRASES = unique([
  "mi hanno diagnosticato", "mi ha diagnosticato", "il mio medico", "la mia dottoressa", "il mio dottore",
  "il mio psicologo", "la mia psicologa", "il mio psichiatra", "la mia psichiatra", "la mia terapia",
  "le mie analisi", "i miei esami", "ho la febbre", "ho mal di", "mi fa male", "mi ha prescritto",
  "mi hanno prescritto", "la mia pressione", "il mio ciclo", "mi sono ammalato", "mi sono ammalata",
  "sono allergico", "sono allergica", "soffro di", "ho avuto un attacco di panico",
  "my doctor", "i was diagnosed", "my therapy", "my therapist", "my medication", "i have a fever",
  "my blood pressure", "i suffer from",
  // Francese, spagnolo, tedesco.
  "mon medecin", "mon docteur", "ma therapie", "mon traitement", "j ai de la fievre", "je souffre de",
  "on m a diagnostique", "ma tension arterielle", "mes analyses",
  "mi medico", "mi terapia", "mi tratamiento", "tengo fiebre", "sufro de", "me diagnosticaron", "mi presion arterial",
  "mein arzt", "meine therapie", "ich habe fieber", "ich leide an", "mein blutdruck", "bei mir wurde diagnostiziert",
]);

/** Frasi personali senza contenuto medico: contano solo insieme a un termine medico. */
const PERSONAL_PHRASES = unique([
  "sto prendendo", "devo prendere", "prendo il", "prendo la", "ho preso", "mi sento", "sto male",
  "stavo male", "mi ha visitato", "i am taking", "i took", "i feel",
  "je prends", "je me sens", "tomo el", "tomo la", "me siento", "ich nehme", "ich fuhle mich",
]);

/** Termini medici. Il confronto è sull'inizio della parola: "farmac" prende farmaco e farmaci. */
export const TERMS = unique([
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
  // Francese, spagnolo, tedesco.
  "medicament", "ordonnance", "diagnostiqu", "douleur", "fievre", "anxiete", "depression", "maladie", "medecin",
  "receta medica", "sintoma", "fiebre", "ansiedad", "embarazo", "enfermedad", "tratamiento",
  "arzt", "medikament", "diagnose", "fieber", "schmerz", "angst", "schwanger", "krankheit", "rezept",
]);

/** Indizi che dicono "personale" ma non "salute": una dose da sola, una data con "controllo dal". */
const CONTEXT_PATTERNS = new Set(["dose", "temperatura", "visita fissata"]);

/** Indizi personali misurabili: dosi, valori, visite fissate. */
const PATTERNS: { name: string; pattern: RegExp; weight: number }[] = [
  // Unità da farmaco, non da cucina o laboratorio di chimica: niente ml.
  { name: "dose", pattern: / \d+([,.]\d+)? ?(mg|mcg|[µμ]g|gocce|ui|compresse|cp)\b/, weight: 2 },
  // Con il contesto: 14/10 da solo è una data.
  {
    name: "pressione misurata",
    pattern: /(pressione|mmhg|max|min)[^0-9]{0,15}\d{2,3}\/\d{2,3}\b(?!\/)|\d{2,3}\/\d{2,3} ?mmhg/,
    weight: 3,
  },
  { name: "valore di laboratorio", pattern: / \d+([,.]\d+)? ?mg\/dl\b/, weight: 2 },
  { name: "temperatura", pattern: / 3[6-9]([,.]\d)? ?°/, weight: 2 },
  { name: "visita fissata", pattern: / (visita|controllo|appuntamento) (dal|dalla|con il|con la|dallo) /, weight: 2 },
];

/**
 * Due di queste parole fanno un testo in prima persona. "sono" e "i" no: in italiano sono anche terza
 * persona plurale e articolo. "ma" non c'è: in italiano è una congiunzione.
 */
const FIRST_PERSON_WORDS = ["ho", "mi", "mio", "mia", "miei", "mie", "sto", "my", "me", "je", "mon", "mes", "tengo", "mis", "ich", "mein", "meine"];

// MARK: Lingua

/**
 * Parole molto comuni delle lingue conosciute: se mancano quasi del tutto, la lingua è un'altra.
 * Niente parole di una lettera ("a", "e", "i", "y"): in polacco e in altre lingue significano altro.
 */
const STOPWORDS = new Set(
  unique([
    "il", "lo", "la", "gli", "le", "un", "una", "uno", "di", "da", "in", "con", "su", "per", "tra", "fra",
    "che", "non", "sono", "ho", "mi", "si", "come", "piu", "ma", "anche", "del", "della", "dei", "delle", "nel", "nella",
    "al", "alla", "questo", "questa",
    "the", "and", "of", "to", "is", "that", "it", "for", "with", "as", "was", "on", "are", "be", "this", "have", "not", "you", "my",
    "les", "des", "du", "et", "est", "pour", "dans", "pas", "qui", "sur", "avec", "je", "il", "elle", "nous", "vous", "mon", "mes",
    "el", "los", "las", "es", "en", "por", "para", "se", "su", "yo", "tengo", "mis",
    "der", "die", "das", "und", "ist", "nicht", "ein", "eine", "zu", "den", "mit", "von", "auf", "fur", "ich", "mein", "meine", "dem",
  ]),
);

/** Lettere oltre il blocco "Latin Extended-B" (cirillico, greco, arabo, CJK…) sono scritture non conosciute. */
const LATIN_LIMIT = 0x24f;
const MIN_NON_LATIN_LETTERS = 5;
const NON_LATIN_SHARE = 0.3;
const MIN_WORDS_FOR_LANGUAGE = 12;
const MIN_STOPWORD_SHARE = 0.1;

/** True se il testo è in una scrittura o una lingua che il rilevatore non sa giudicare. */
export function isUnverifiable(text: string): boolean {
  let letters = 0;
  let other = 0;
  for (const char of text) {
    if (!/\p{L}/u.test(char)) continue;
    letters += 1;
    if ((char.codePointAt(0) ?? 0) > LATIN_LIMIT) other += 1;
  }
  if (other >= MIN_NON_LATIN_LETTERS && other / letters >= NON_LATIN_SHARE) return true;
  const words = normalize(text).split(/[^\p{L}]+/u).filter(Boolean);
  if (words.length < MIN_WORDS_FOR_LANGUAGE) return false;
  const known = words.filter((word) => STOPWORDS.has(word)).length;
  return known / words.length < MIN_STOPWORD_SHARE;
}

// MARK: Valutazione

export const NONE: HealthAssessment = { score: 0, signals: new Set(), suspected: false };

export function assess(text: string): HealthAssessment {
  const tokens = normalize(text)
    .split(/[^\p{L}\p{N}\p{M}/,.°%]+/u)
    // Punteggiatura in fondo alla parola via: "febbre," è "febbre". Dentro resta: 140/90, 38,5°.
    .map((token) => token.replace(/^[,.]+|[,.]+$/g, ""))
    .filter(Boolean);
  const normalized = ` ${tokens.join(" ")} `;
  let score = 0;
  const signals = new Set<string>();
  let personal = false;

  for (const phrase of HEALTH_PHRASES) {
    if (normalized.includes(` ${phrase} `)) {
      score += 3;
      signals.add(phrase);
      personal = true;
    }
  }
  // Frasi comuni ("prendo il", "sto male"): dicono che il testo è personale, non che parla di salute.
  for (const phrase of PERSONAL_PHRASES) {
    if (normalized.includes(` ${phrase} `)) {
      score += 1;
      personal = true;
    }
  }
  for (const term of TERMS) {
    if (normalized.includes(` ${term}`)) {
      score += 1;
      signals.add(term);
    }
  }
  for (const { name, pattern, weight } of PATTERNS) {
    if (pattern.test(normalized)) {
      score += weight;
      signals.add(name);
      personal = true;
    }
  }
  if (FIRST_PERSON_WORDS.filter((word) => normalized.includes(` ${word} `)).length >= 2) personal = true;

  // Serve almeno un segnale medico vero: le dosi o una frase generica da sole non bastano.
  const healthSignals = [...signals].filter((s) => !CONTEXT_PATTERNS.has(s));
  let suspected = personal && score >= THRESHOLD && healthSignals.length > 0;
  // A chiusura: un testo che non si sa leggere non si può dichiarare innocuo.
  if (isUnverifiable(text)) {
    signals.add(UNVERIFIED_SIGNAL);
    suspected = true;
  }
  return { score, signals, suspected };
}

/** Sospetto e con almeno un segnale che l'utente non ha già giudicato innocuo. */
export function isHeld(assessment: HealthAssessment, dismissed: ReadonlySet<string> | readonly string[] = []): boolean {
  if (!assessment.suspected) return false;
  const known = new Set(dismissed);
  return [...assessment.signals].some((signal) => !known.has(signal));
}
