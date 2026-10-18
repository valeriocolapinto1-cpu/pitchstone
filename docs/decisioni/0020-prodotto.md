# 0020 — Prodotto: cosa si taglia, cosa si aggiunge

## Fatto
- Retrieval della chat sul PC: BM25 sulle radici delle parole (stemmer italiano leggero) fuso con la corrispondenza letterale (RRF), al più 3 frammenti per nodo, fonti delimitate da `<<<`/`>>>` e dichiarate dati non fidati. Set di valutazione in `web/test/eval/` (corpus + domande, soglie su top-1 e top-3 nel test).
- Cestino sul web: elenco dei nodi eliminati, ripristino, "Annulla" per 8 secondi dopo lo spostamento.
- Connessione: `GET /status` nel Worker (database, Gemini, ultimo backup) e schermata "Connessione" nella PWA, con testi propri per sessione scaduta, versione vecchia, server e rete.
- iPad: l'analisi automatica in background è spenta di default (interruttore nelle impostazioni). Il rilevamento dei dati di salute resta sempre attivo.
- Corretto `run_worker_first`: `/account/*` e `/status` ora passano dal Worker (prima l'export e la cancellazione sarebbero stati serviti dal fallback SPA).

## Non fatto (scelta)
Casella di revisione dei quiz, vista di preparazione all'esame, sync dei dati di studio, share extension, blocco biometrico, indicatore di conflitto, token di citazione `[S2]`, condensazione dei follow-up e chunk per intestazioni: sono funzioni di prodotto grandi, per lo più SwiftUI, che senza compilatore né dispositivo non si possono verificare qui. Obiettivi settimanali, difficoltà adattiva, `importPlan` duplicato e calendario esami non sono stati toccati: tagliare funzioni esistenti senza poterle provare sull'iPad rischia di rompere dati degli utenti. Il set di valutazione ha 32 domande, non 80-120: va ampliato con domande vere dagli appunti dell'utente.
