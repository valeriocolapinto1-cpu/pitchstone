# Runbook operativo

## Token Access scaduto o rifiutato
- **PWA**: la schermata "Connessione" dice "Sessione scaduta"; ricarica la pagina e accedi di nuovo con Google.
- **iPad** (service token): l'app mostra "token scaduto" e la sync si ferma. In Cloudflare Zero Trust → Access → Service Auth crea un nuovo token (o rinnova la scadenza), poi inserisci `CF_ACCESS_CLIENT_ID` e `CF_ACCESS_CLIENT_SECRET` in Impostazioni. Se usi `ACCESS_SYNC_TOKENS`, aggiorna il `common_name` nel Worker.
- Controllo rapido: `curl -H "CF-Access-Client-Id: …" -H "CF-Access-Client-Secret: …" https://<dominio>/sync/config` deve rispondere 200.

## Rotazione dei segreti
1. **Gemini**: crea una chiave nuova, `wrangler secret put GEMINI_API_KEY`, poi revoca la vecchia.
2. **Supabase**: genera una nuova secret key, `wrangler secret put SUPABASE_SECRET_KEY` (e aggiorna il segreto GitHub usato da `restore-drill`), poi revoca la vecchia.
3. **Healthcheck**: `wrangler secret put HEALTHCHECK_URL`.
4. Verifica: `GET /status` dalla PWA ("Connessione") deve mostrare database raggiungibile e Gemini configurato.

## Supabase in pausa
Il piano gratuito mette in pausa il progetto dopo una settimana di inattività. Il workflow `keepalive` lo evita (ogni 3 giorni) e controlla che l'ultimo backup abbia meno di 36 ore. Se il progetto è in pausa: Dashboard → Restore project, attendi, poi lancia a mano il workflow `keepalive` e controlla `/status`. Se il workflow `keepalive` fallisce, GitHub scrive all'amministratore del repository: non ignorare l'email.

## Rollback del Worker
`cd backend/worker-ai && npx wrangler deployments list`, poi `npx wrangler rollback <deployment-id>`. Le migrazioni SQL non si annullano: un rollback del Worker verso una versione precedente è sicuro solo se la migrazione corrispondente è compatibile (le migrazioni del progetto sono additive). In dubbio, ripristina dal backup (`runbook-backup.md`).

## Deploy
- Worker e PWA: la build di Cloudflare (`Workers Builds`) parte da `main`; in locale `npx wrangler deploy --dry-run` verifica la configurazione.
- Database: `supabase db push` dalla cartella `backend`, dopo aver provato le migrazioni su un database locale (`supabase start`, `supabase test db`). Esegui il push da una macchina fidata e controlla `supabase db diff` prima.
- Prima di un deploy che cambia il protocollo: aggiorna `API_VERSION`/`MIN_API_VERSION` e `contract/`.

## Verifiche periodiche
- Ogni mese: `restore-drill` (automatico) deve essere verde.
- `GET /status`: `backup_age_hours` sotto le 36.
