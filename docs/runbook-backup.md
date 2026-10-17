# Runbook: backup e ripristino

## Verificare che il backup ci sia
- Il keep-alive (GitHub Actions, ogni 3 giorni) fallisce se l'ultimo backup ha più di 36 ore.
- Con `HEALTHCHECK_URL` impostato, il servizio di monitoraggio avvisa se il ping manca o arriva `/fail`.
- A mano: `SUPABASE_URL=… SUPABASE_SECRET_KEY=… npm run restore -- --latest --verify` (da `backend/worker-ai`) scarica l'ultimo backup completo e ne controlla sha256, dimensioni e conteggi, senza toccare il database. Lo fa anche ogni mese il workflow `restore-drill` (serve il secret `SUPABASE_SECRET_KEY` nel repository).

## Ripristinare
1. Prima di tutto `--verify` sul backup scelto (`--latest` oppure `AAAA-MM-GG/OOMMSS-xxxx`).
2. Database vuoto o da rifare da zero: `npm run restore -- <backup> --wipe --confirm cancella-tutto`.
3. Database con dati da tenere: `npm run restore -- <backup>` (aggiunge e aggiorna, non cancella).
4. Il comando stampa la nuova epoca di sincronizzazione. Gli iPad e il PC la vedono al prossimo pull e ripartono da cursore 0.
5. Controllare nell'app che note, archi e disegni ci siano. I file degli allegati non sono nel backup: stanno nel bucket `attachments` (quelli cancellati da meno di 15 giorni ci sono ancora).

## Se il backup manca
- Cloudflare → Workers → `ai-proxy` → Logs: cercare `Backup:`.
- Rifarlo subito: Workers → Triggers → Cron → eseguire `30 10 * * *` (rifà il backup solo se oggi manca).
- Un backup rifiutato per calo dei nodi (`Backup rifiutato: nodi da X a Y`) significa che il database ha perso righe: capire perché prima di forzare un nuovo backup.

## Database vicino al limite
Oltre 350 MB il Worker lo segnala (`/fail`). Controllare `node_versions` (`select pg_size_pretty(pg_total_relation_size('node_versions'))`) e abbassare le versioni conservate in `prune_history`.
