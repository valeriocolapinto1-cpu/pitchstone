# ADR 0008: testo ricercabile (PDF, OCR, scrittura a mano)

Stato: accettata, 2026-10-14. Riferimento: ARCHITETTURA.md, sezioni 3 e 9 (fase 4).

## Contesto

PDF, foto di appunti e pagine scritte a penna devono essere ricercabili come le note. Vision e PDFKit lavorano sul dispositivo, gratis e anche offline.

## Decisioni

- Estrazione sul dispositivo, fuori dal thread principale:
  - PDF: il testo incorporato (PDFKit); le pagine senza testo (scansioni, fino a 40 per documento) passano dall'OCR.
  - Foto: OCR con Vision (`VNRecognizeTextRequest`, accurato, italiano e inglese). L'architettura citava `RecognizeDocumentRequest`, che richiede iOS 26: si passa a quella API quando il minimo diventerà iOS 26.
  - Scrittura a mano: il disegno PencilKit (pagine del nodo e annotazioni dei PDF) si rende in nero su bianco e passa dallo stesso OCR.
- Il testo è un dato derivato e solo locale (`ExtractedTextEntity` in SwiftData): non si sincronizza, ogni dispositivo lo ricava dai file e dai disegni. Un'impronta (SHA-256 dell'allegato, FNV-1a del disegno) evita di ricalcolare ciò che non è cambiato; una fonte senza testo tiene una voce vuota.
- L'indicizzazione parte da sola dopo le modifiche (con 2 secondi di attesa per raggruppare un import), una alla volta; le fonti eliminate escono dall'indice.
- Ricerca: tutte le parole, senza maiuscole né accenti. Nell'elenco un nodo trovato nel testo estratto mostra l'estratto e da dove viene; nel grafo il testo estratto conta come corpo del nodo.

## Conseguenze

- La qualità dell'OCR della scrittura a mano in italiano va verificata sull'iPad.
- I PDF molto lunghi di sole scansioni sono letti solo nelle prime 40 pagine.
- Il testo estratto sarà la base dei frammenti per la ricerca semantica e la chat (fase 5).
