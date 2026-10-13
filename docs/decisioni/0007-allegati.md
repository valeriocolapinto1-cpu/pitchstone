# ADR 0007: allegati e PDF

Stato: accettata, 2026-10-14. Riferimento: ARCHITETTURA.md, sezioni 3, 5, 7 e 9 (fase 4).

## Contesto

PDF e immagini devono stare nel piano gratuito di Supabase (50 MB per file, 1 GB in tutto), restare privati e arrivare su ogni dispositivo. Il client non ha chiavi di Supabase: parla solo con il Worker dietro Cloudflare Access. I dati di salute non lasciano l'iPad.

## Decisioni

**File**
- Ogni allegato è un file intero sul dispositivo (Application Support/Allegati) e, se può lasciare l'iPad, è diviso in parti da 45 MiB nel bucket privato `attachments`: `<id>/part-000`, `<id>/part-001`... Un PDF di 100 MB diventa tre parti.
- Divisione per byte, non per pagine: la ricomposizione è esatta (SHA-256 del file intero) e funziona anche con pagine enormi.
- Il Worker firma URL di breve durata (`POST /storage/sign`): caricamento con upsert (ripetibile), scaricamento valido 5 minuti. Il percorso deve essere una parte di un allegato: nessun altro oggetto del bucket è raggiungibile.
- Prima le parti, poi la riga: un altro dispositivo non vede mai un allegato senza file. Offline l'allegato aspetta in outbox.
- Il file si scarica solo quando si apre; un file che non torna identico non viene salvato.

**Database**
- `attachments` si sincronizza come nodi e pagine. Il contenuto (hash, dimensione, parti, tipo) non cambia; nome, nodo e cestino sì, con un ripristino che vince su un'eliminazione. Il percorso nel bucket è l'id.
- Le annotazioni a penna di un PDF sono `ink_pages` con `attachment_id` e `pdf_page`. In un conflitto la copia resta sulla stessa pagina del PDF come secondo strato; il client unisce gli strati la prima volta che apre la pagina. Nessun tratto va perso.
- Dopo 30 giorni nel cestino `purge_trash` elimina riga e annotazioni e mette i file in `storage_trash`; ogni notte il Worker li cancella con la Storage API (che non si chiama da SQL) e svuota la coda.

**Privacy**
- Un allegato segue il suo nodo: con un nodo di salute resta sul dispositivo, file compreso.

**App**
- Allegati dal pulsante a forma di graffetta del nodo, oppure "Importa → PDF e immagini" (un nodo per file).
- Lettore PDF (PDFKit) con uno strato PencilKit per pagina (`PDFPageOverlayViewProvider`); "Nodo dalla selezione" crea un nodo con la citazione e il link `[[nodo del PDF]]`, quindi un arco nel grafo.

## Conseguenze

- Lo spazio è limitato a 1 GB: allegati grandi vanno usati con giudizio (avviso all'80% in fase 9).
- Un allegato più grande di 100 parti (circa 4,4 GB) non si può aggiungere.
- Il testo dei PDF per la ricerca arriva con la parte 3 (OCR).
