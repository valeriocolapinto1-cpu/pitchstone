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

Test end-to-end della sync (Worker → Supabase locale):

```sh
cd backend
supabase start -x realtime,storage-api,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor
eval "$(supabase status -o env)"
cd worker-ai
E2E_SUPABASE_URL=$API_URL E2E_SUPABASE_SECRET_KEY=$SECRET_KEY E2E_SUPABASE_ANON_KEY=$ANON_KEY npm run test:e2e
```

Keep-alive: `cd tools/keepalive && npm ci && npm run lint && npm test`.

## Client iOS

La logica sta nel package [ios/PitchstoneKit](ios/PitchstoneKit): `PitchstoneSync` (sync, outbox, privacy) si testa anche su Linux, `PitchstoneStore` (SwiftData, Keychain, rete) solo su macOS.

```sh
cd ios/PitchstoneKit
swift test
```

## Segreti richiesti

Solo nomi; i valori non vanno mai nel repository (vedi [.env.example](.env.example)).

| Nome | Dove |
|---|---|
| `SUPABASE_URL` | GitHub Secrets (keep-alive) |
| `SUPABASE_ANON_KEY` | GitHub Secrets (keep-alive) |
| `GEMINI_API_KEY` | Secret del Worker Cloudflare (`wrangler secret put`) |
| `SUPABASE_SECRET_KEY` | Secret del Worker Cloudflare (`wrangler secret put`) |
| `SUPABASE_URL`, `ACCESS_TEAM_DOMAIN`, `ACCESS_AUD` | `[vars]` di `backend/worker-ai/wrangler.toml` (valori pubblici); `[previews.vars]` resta vuoto, così le anteprime dei branch non raggiungono la produzione |
| `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` | Keychain dell'iPad |
