# ADR 0004: disegno a penna

Stato: accettata, 2026-10-13. Riferimento: ARCHITETTURA.md, sezioni 2, 5 e 9 (fase 2); ADR 0002 e 0003.

## Contesto

Gli appunti a penna sono il cuore dell'uso su iPad. Il disegno di una pagina (PKDrawing) è un blob binario: non si può fondere riga per riga come il Markdown, e pesa molto più del testo.

## Decisioni

**Modello**
- Nuova tabella `ink_pages`: pagine di disegno di un nodo (`node_id`, `page_no`, `background` tra `blank`, `lines`, `grid`, `ink_data` = `PKDrawing.dataRepresentation()`). È il "nodo di appunti" previsto dalla fase 2; `pdf_pages.ink_data` resta per le annotazioni sui PDF della fase 4.
- Una pagina vuota ha zero byte. Limite di 2 MB per pagina (check sul database).
- In SwiftData i byte stanno fuori dal database (`@Attribute(.externalStorage)`).

**Sync**
- Stesso schema di nodi e archi: `server_seq`, `base_version`, cestino a 30 giorni, eliminazioni definitive in `purged`. Le pagine seguono il nodo: un nodo di salute non sincronizza le sue pagine.
- I byte viaggiano in base64 nel JSON.
- Conflitto (due dispositivi disegnano sulla stessa versione): il server non può fondere due disegni, quindi la pagina del server resta com'è e il disegno del client diventa **una nuova pagina** in fondo al nodo. Nessun tratto va perso; l'utente riunisce le pagine se vuole. Byte uguali: nessuna copia. Pagina eliminata da una parte e modificata dall'altra: vince la modifica.
- Push e pull sono limitati anche in byte: il client manda al massimo circa 3,5 MB per push (il Worker accetta 5 MB), il server risponde con al massimo circa 4 MB per pagina di pull. La prima voce passa sempre, così la sync avanza.

**App**
- Vista "Penna" nel nodo: tela PencilKit con la palette di sistema (penna, evidenziatore, gomma, lazo, righello), pagina in proporzioni A4 che si allunga con i tratti, sfondo bianco, a righe o a quadretti disegnato sotto i tratti nel colore dei separatori (si adatta al tema scuro).
- Con la Pencil il dito scorre la pagina; un interruttore fa disegnare anche il dito.
- Salvataggio un secondo dopo l'ultimo tratto, quando si lascia la pagina e quando l'app va in background. La tela si ricarica da sola se la pagina cambia per una sync e non ci sono tratti da salvare.

## Conseguenze

- Il riconoscimento delle forme di PencilKit e la fluidità della Pencil si verificano sul dispositivo.
- Il testo scritto a mano diventa ricercabile con l'OCR della fase 4.
