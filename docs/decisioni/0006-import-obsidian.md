# ADR 0006: import di vault Obsidian

Stato: accettata, 2026-10-13. Riferimento: ARCHITETTURA.md, sezioni 2 e 9 (fase 4).

## Contesto

Gli appunti esistenti stanno in un vault Obsidian: una cartella di file Markdown con proprietà YAML, tag, alias e link `[[...]]` che possono contenere cartelle, sezioni e un testo alternativo. Nell'app un link è `[[Titolo]]` o `[[Titolo|testo]]` e si risolve sul titolo del nodo, ignorando maiuscole e accenti.

## Decisioni

**Separazione**
- `PitchstoneImport` (Foundation pura, testato su Linux): lettura della cartella, traduzione delle note, applicazione all'archivio tramite `Repository`. L'app aggiunge solo la scelta della cartella e l'anteprima.
- Prima si costruisce un piano senza toccare l'archivio; l'utente vede cosa verrà creato e conferma.

**Lettura**
- Si leggono i file `.md`; le cartelle nascoste (`.obsidian`, `.trash`, `.git`) restano fuori. Le note oltre 2 MB o non in UTF-8 vengono segnalate e saltate.
- Gli altri file (PDF, immagini) sono elencati ma non importati: arrivano con gli allegati (parte 2 della fase).

**Traduzione**
- Titolo: il nome del file. Se due file hanno lo stesso nome, il meno annidato tiene il nome, gli altri prendono la cartella tra parentesi (`Limiti (Analisi)`).
- Link: si risolvono come in Obsidian, cioè percorso, poi nome del file (prima nella stessa cartella, poi il meno annidato), poi alias, infine i nodi già presenti nell'app. Il link viene riscritto con il titolo del nodo: `[[cartella/Nota#Sezione]]` diventa `[[Nota|Nota > Sezione]]`, l'alias resta come testo del link, `\|` nelle tabelle resta. Un link a una sezione della stessa nota diventa testo.
- L'embed di una nota (`![[Nota]]`) diventa un link; l'embed di un allegato resta com'è.
- Il codice (blocchi e inline) non viene mai modificato.
- Tag: dalla proprietà `tags` e dai `#tag` nel testo, come in Obsidian (almeno un carattere non numerico, non nei titoli né nel codice).
- Area: proprietà `area`, poi la prima cartella se ha il nome di un'area, poi quella scelta nell'anteprima. Una nota con il tag `salute` (o `health`) va sempre nell'area salute e resta sul dispositivo: in caso di dubbio prevale la privacy.
- Tipo: proprietà `type` o `tipo`, in italiano o in inglese; altrimenti concetto.
- Le proprietà che l'app non usa restano in fondo alla nota in un blocco `yaml`, per non perdere informazioni.

**Applicazione**
- Un titolo già presente nell'app non viene duplicato: la nota è saltata e i link puntano al nodo esistente. Reimportare lo stesso vault non crea nulla.
- Gli archi `link` si creano dopo tutti i nodi; le note già presenti che citavano i nuovi titoli ricevono i loro archi.
- I nodi di salute e i loro archi seguono le regole di sempre: niente outbox.

## Conseguenze

- Le date di creazione e modifica dei file non vengono conservate: i nodi nascono con la data dell'import.
- Un link irrisolto resta `[[...]]`: toccandolo si crea il nodo, come per un link scritto a mano.
