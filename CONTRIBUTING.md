# Contribuire

- Una PR per fase o per parte di fase; il merge avviene con il controllo `ci` verde.
- Prima di aprire una PR, in locale:
  - Worker: `cd backend/worker-ai && npm ci && npm run lint && npm test && npx wrangler deploy --dry-run`
  - PWA: `cd web && npm ci && npm run lint && npm test && npm run build`
  - Database: `cd backend && supabase start && supabase test db && supabase db lint --level warning --fail-on warning`
  - Kit Swift: `cd ios/PitchstoneKit && swift test`
- Una modifica al protocollo di sync tocca insieme `contract/`, il Worker, la PWA e l'iPad (ADR 0018, 0022).
- Il rilevatore di salute esiste in Swift e in TypeScript: se ne cambia uno, si cambia l'altro e gli esempi dei test.
- Nessun segreto nel repository: vedi `.env.example`; gitleaks gira in CI.
- Commit e commenti in italiano, nello stile del codice circostante. Una decisione che cambia l'architettura va in un ADR in `docs/decisioni/`.
