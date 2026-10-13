# Fase 0: base

Stato: in corso

## Obiettivo

Repository, CI, Supabase, Cloudflare Access, keep-alive, documentazione.

## Criteri di completamento

- [x] Struttura del repository come da ARCHITETTURA.md, sezione 8.
- [x] Schema vuoto con RLS attiva, migrazione applicata in locale senza errori.
- [ ] CI Linux verde su una PR, poi merge.
- [ ] Workflow keep-alive eseguito una volta con successo.
- [ ] Revisione del subagente completata e correzioni applicate.

## Test

- [x] Lint e test del backend in CI (`ci-linux.yml`).
- [x] Il keep-alive non tocca tabelle utente (`tools/keepalive/ping.test.mjs`).
- [x] Lo schema non contiene policy per `anon` (`backend/supabase/tests/schema.test.sql`).

## Verifiche

- Service token di Cloudflare Access disponibili nel piano Free: confermato dalla documentazione (vedi ADR 0001).

## Azioni manuali aperte

- [ ] Repository GitHub privato con i secret `SUPABASE_URL` e `SUPABASE_ANON_KEY`.
- [ ] Progetto Supabase in regione Europa, con la migrazione applicata (`supabase db push` o SQL editor).
- [ ] Cloudflare Access con login Google per l'email autorizzata.
- [ ] Service token di Cloudflare Access per l'iPad.
- [ ] Verifica nella dashboard Supabase del comportamento di pausa per inattività.
