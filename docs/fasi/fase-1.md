# Fase 1: dati e sincronizzazione

Stato: in revisione (codice e test pronti, mancano le azioni manuali per la verifica sul dispositivo)

## Obiettivo

Modello dati in SwiftData, outbox, pull e push con Supabase, versioni dei nodi, cestino. Decisioni in [ADR 0002](../decisioni/0002-sincronizzazione.md).

## Criteri di completamento

- [x] Un nodo creato su un dispositivo compare sull'altro: test Swift a due dispositivi e test end-to-end Worker → Supabase in CI.
- [x] Modifiche offline vengono sincronizzate al ritorno della connessione: test Swift; `AutoSync` avvia la sync quando torna la rete.
- [x] Il cestino conserva per 30 giorni: `purge_trash()` con `pg_cron` sul server, `Repository.purgeTrash()` sul client, test su entrambi.
- [ ] Verifica su due dispositivi reali, dopo le azioni manuali e la fase 2 (serve l'app).

## Test

- [x] Test unitari sul sync (`ios/PitchstoneKit/Tests`, `backend/supabase/tests/sync.test.sql`).
- [x] Test di conflitto con due versioni (Swift, pgTAP, end-to-end).
- [x] Verifica del JWT di Access e filtro salute nel Worker (`backend/worker-ai/test`).
- [ ] Test dell'archivio SwiftData su macOS (`ci-ios`, gira su `main` o manualmente).

## Cosa c'è

- `backend/supabase/migrations/20261013120000_sync.sql`: `server_seq`, `purged`, `sync_push`, `sync_pull`, `purge_trash`, job `pg_cron`.
- `backend/worker-ai`: `POST /sync/push` e `POST /sync/pull` dietro Access.
- `ios/PitchstoneKit`: record, outbox, repository, motore di sync, trasporto HTTP, archivio SwiftData, Keychain, `AutoSync`.

## Azioni manuali

- [ ] Applicare la migrazione al progetto Supabase (`supabase db push`) e verificare che `pg_cron` sia attivo.
- [ ] Copiare la chiave segreta di Supabase nel Worker: `wrangler secret put SUPABASE_SECRET_KEY`.
- [ ] Compilare `SUPABASE_URL`, `ACCESS_TEAM_DOMAIN` e `ACCESS_AUD` in `backend/worker-ai/wrangler.toml` e fare il deploy.
- [ ] Applicazione Cloudflare Access sul dominio del Worker, con policy "Service Auth" per il service token dell'iPad (azione ancora aperta dalla fase 0).
