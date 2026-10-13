# ADR 0006: import di vault Obsidian

Stato: accettata, 2026-10-13. Riferimento: ARCHITETTURA.md, sezioni 2 e 9 (fase 4).

## Contesto

Gli appunti esistenti stanno in un vault Obsidian: una cartella di file Markdown con proprietà YAML, tag, alias e link `[[...]]` che possono contenere cartelle, sezioni e un testo alternativo. Nell'app un link è `[[Titolo]]` o `[[Titolo|testo]]` e si risolve sul titolo del nodo, ignorando maiuscole e accenti.

## Decisioni

**Separazione**
- `PitchstoneImport` (Foundation pura, testato su Linux): lettura della cartella, traduzione delle note, applicazione all'archivio tramite `Repository`. L'app aggiunge solo la scelta della cartella e l'anteprima.
- Prima si costruisce un piano senza toccare l'archivio; l'utente vede cosa verrà creato e conferma.

**Lettura**
- Si leggono i file `.md`; le cartelle nascoste (`.obsidian`, `.trash`, `.git`) restano fuori. Le note oltre 2 MB, non in UTF-8, non leggibili o non ancora scaricate da iCloud (`.Nota.md.icloud`) vengono segnalate nell'anteprima, mai saltate in silenzio; un file illeggibile non blocca gli altri.
- Gli altri file (PDF, immagini) sono elencati ma non importati: arrivano con gli allegati (parte 2 della fase).

**Traduzione**
- Titolo: il nome del file. Se due file hanno lo stesso nome, il meno annidato tiene il nome, gli altri prendono la cartella tra parentesi (`Limiti (Analisi)`).
- Link: si risolvono come in Obsidian, cioè percorso, poi nome del file (prima nella stessa cartella, poi il meno annidato), poi alias, infine i nodi già presenti nell'app. Il link viene riscritto con il titolo del nodo: `[[cartella/Nota#Sezione]]` diventa `[[Nota|Nota > Sezione]]`, l'alias resta come testo del link, `\|` nelle tabelle resta. Un link a una sezione della stessa nota diventa testo.
- L'embed di una nota (`![[Nota]]`, anche `![[Lezione 3.2]]`) diventa un link; l'embed di un allegato resta com'è. Un titolo con `#` (`C#`) si prova intero prima di separare la sezione.
- Il codice (blocchi, anche indentati o dentro le liste, codice inline) e l'HTML non vengono mai modificati né producono link o tag. Si riconoscono con swift-markdown, lo stesso parser che usa l'app: l'import non crea archi che l'app toglierebbe alla prima modifica.
- Tag: dalla proprietà `tags` e dai `#tag` nel testo, come in Obsidian (almeno un carattere non numerico, non nei titoli né nel codice).
- Salute, prima di tutto: una nota con il tag `salute` o `health` (anche annidato, `salute/visite`), con tipo salute o dentro una cartella Salute/Health a qualsiasi livello va nell'area salute e resta sul dispositivo, qualunque area dichiari. In caso di dubbio prevale la privacy.
- Area: proprietà `area`, poi la prima cartella se ha il nome di un'area, poi quella scelta nell'anteprima.
- Tipo: proprietà `type` o `tipo`, in italiano o in inglese; altrimenti concetto.
- Le proprietà che l'app non assorbe (alias, date, aree o tipi sconosciuti...) restano in fondo alla nota in un blocco `yaml`, con un recinto più lungo di qualsiasi sequenza di backtick nei valori. Un blocco in testa che non è YAML (per esempio due righe orizzontali) resta testo: niente si perde.

**Applicazione**
- Un titolo già presente nell'app non viene duplicato: la nota è saltata e i link puntano al nodo esistente. Reimportare lo stesso vault non crea nulla.
- Gli archi `link` si creano dopo tutti i nodi, direttamente (i nodi nuovi non hanno archi da riallineare); le note già presenti che citavano i nuovi titoli ricevono i loro archi.
- Il piano si calcola fuori dal thread principale; l'applicazione è un blocco unico con salvataggi SwiftData ogni 200 operazioni. 2000 note con 10.000 link: circa 1 s su Linux in debug con l'archivio in memoria.
- I nodi di salute e i loro archi seguono le regole di sempre: niente outbox.

## Conseguenze

- Le date di creazione e modifica dei file non vengono conservate: i nodi nascono con la data dell'import.
- Un link irrisolto resta `[[...]]`: toccandolo si crea il nodo, come per un link scritto a mano.
