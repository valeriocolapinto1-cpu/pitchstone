# ADR 0016: backup a file, ripristino e conservazione

Stato: accettata, 2026-10-17. Sostituisce il formato del backup dell'ADR 0012; il resto di quell'ADR resta valido.

## Decisioni

- **Formato**: ogni esecuzione scrive una cartella `AAAA-MM-GG/OOMMSS-xxxx/` nel bucket privato `backups`, con un file JSON per pagina di ogni tabella (`nodes-000.json`, …), i disegni in file a parte (`ink-000.json`) e un `manifest.json` scritto per ultimo con conteggi e sha256 di ogni file. Nessuna sovrascrittura: un'esecuzione ha un nome suo. Un backup senza manifest non è completo e non vale; se un upload fallisce i file già scritti si tolgono.
- **Contenuto**: nodi, archi, storico dei nodi (`node_versions`), righe eliminate definitivamente (`purged`), pagine a penna, metadati degli allegati. Nodi nel cestino e salute esclusi (la salute non arriva mai sul server; il filtro c'è comunque, su ogni pagina).
- **Controlli prima di salvare**: i conteggi scritti stanno tra quelli presi prima e dopo; un calo dei nodi oltre il 20% rispetto all'ultimo backup completo fa rifiutare il backup (si controlla a mano prima di sovrascrivere la storia).
- **Ripristino**: `npm run restore` (in `backend/worker-ai`). Scarica e verifica tutto prima di scrivere; con `--wipe --confirm cancella-tutto` svuota prima le tabelle. Le righe tornano con la loro identità; il trigger di sync assegna `server_seq` nuovi. Alla fine `sync_meta.epoch` aumenta: `sync_pull` restituisce `epoch`, e un client che vede un'epoca diversa dalla sua deve ripartire da cursore 0.
- **Segnali**: ping facoltativo (`HEALTHCHECK_URL`, stile healthchecks.io) a ogni backup e `/fail` se non riesce o se il database supera 350 MB; il keep-alive fallisce se l'ultimo backup ha più di 36 ore; secondo cron alle 10:30 UTC che rifà il backup se manca; prova mensile del ripristino in CI (solo verifica).
- **Conservazione**: `prune_history` tiene le ultime 20 versioni di ogni nodo e toglie le più vecchie di 90 giorni; `prune_purged` toglie le righe `purged` oltre 180 giorni (un client fermo da più tempo deve ripartire da zero); il registro di pg_cron si pulisce dopo 7 giorni.
- **Nota diventata di salute**: `POST /sync/redact` (`redact_node_history`) toglie dal server la nota con storico, archi, pagine e allegati, e la segna come eliminata per gli altri dispositivi. I backup già scritti (14 giorni) non si riscrivono.
- **Schema tolto**: `sync_changes`, `chunks`, `chats`, `messages`, `quizzes`, `reviews`, `review_logs`, `goals`, `exams`, `pdf_pages` e l'estensione `vector` non erano usati; lo studio resta locale (ADR 0011).

## Conseguenze

- Il Worker fa una chiamata per pagina: pagine da 2.000 righe o 8 MB. Sul piano gratuito di Cloudflare ci sono 50 sottorichieste per esecuzione, su quello a pagamento 1.000: oltre qualche decina di MB di dati serve il piano a pagamento.
- I backup della versione 1 (`AAAA-MM-GG.json`) restano finché scadono, ma `npm run restore` legge solo il formato nuovo.
