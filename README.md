# Pitchstone

Secondo cervello personale per iPad: grafo di note, appunti a penna, chat AI sulle proprie fonti e quiz con ripetizione spaziata. Il progetto è descritto in [ARCHITETTURA.md](ARCHITETTURA.md); decisioni in [docs/decisioni](docs/decisioni), stato delle fasi in [docs/fasi](docs/fasi).

## Backend locale

Requisiti: Docker, Node 22, [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started).

```sh
cd backend
supabase db start            # Postgres locale con migrazioni e seed
supabase test db             # test dello schema (pgTAP)
supabase db lint --level warning

cd worker-ai
npm ci
cp .dev.vars.example .dev.vars   # valori solo in locale, mai nel repo
npm run dev                      # Worker su http://localhost:8787/health
npm run lint && npm test
```

Test del keep-alive: `node --test "tools/keepalive/*.test.mjs"`.

## Segreti richiesti

Solo nomi; i valori non vanno mai nel repository (vedi [.env.example](.env.example)).

| Nome | Dove |
|---|---|
| `SUPABASE_URL` | GitHub Secrets (keep-alive) |
| `SUPABASE_ANON_KEY` | GitHub Secrets (keep-alive) |
| `GEMINI_API_KEY` | Secret del Worker Cloudflare (`wrangler secret put`) |
| `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` | Keychain dell'iPad |
