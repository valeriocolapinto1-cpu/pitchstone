# Fase 10: versione PC

Stato: completata ([ADR 0013](../decisioni/0013-pwa.md)).

## Criteri di completamento

- [x] Il PC vede gli stessi dati dell'iPad (`web/test/e2e.test.ts`: nodo e arco dall'iPad, modifica dal PC che torna all'iPad, contro il database locale).
- [x] Il modello locale del PC funziona quando è acceso (`web/test/chat.test.ts`: risponde Ollama su `localhost` quando è acceso; spento, senza modello o in errore passa a Gemini via `/ai/chat`; con "Solo locale" si ferma senza uscire dal PC).

## Test

- [x] Test end-to-end della sincronizzazione tra iPad e PWA.
- [x] Test del motore di sync della PWA (outbox, offline, conflitti, rifiuti, link).
- [x] Test del Tutor della PWA: ricerca, spazio del prompt, citazioni, scelta del modello, esclusione dei nodi di salute (`web/test/chat.test.ts`).

## Azioni manuali: Cloudflare Access su tutto il Worker

La PWA, il Worker e le sue API stanno sullo stesso dominio: Access deve coprirlo tutto, non solo `/sync` e `/ai`.

1. Cloudflare → Workers & Pages → `ai-proxy` → Settings → Domains & Routes: su `workers.dev` (e sui Preview URLs) attivare Cloudflare Access. In alternativa, Zero Trust → Access → Applications → Add → Self-hosted con dominio `ai-proxy.<sottodominio>.workers.dev` e **percorso vuoto**; se esiste già un'applicazione limitata a dei percorsi, togliere il percorso.
2. Policy dell'applicazione, in quest'ordine:
   - **Service Auth** con il service token dell'iPad (azione "Service Auth", non "Allow").
   - **Allow** con "Emails" uguale al proprio indirizzo; metodo di accesso Google o One-time PIN.
3. Settings dell'applicazione: durata della sessione (per esempio 1 mese); cookie con SameSite `Lax`, HttpOnly e "Binding cookie".
4. Copiare l'AUD tag dell'applicazione in `ACCESS_AUD` e `https://<team>.cloudflareaccess.com` in `ACCESS_TEAM_DOMAIN` (`backend/worker-ai/wrangler.toml`), poi fare il deploy. Se l'applicazione è nuova, l'AUD cambia e va aggiornato.
5. Verifica: in una finestra anonima l'indirizzo del Worker apre il login di Access; dopo il login si vede la PWA; `curl https://<dominio>/sync/pull` senza token risponde con il login o 403; l'iPad sincronizza ancora.

Il manifest della PWA si scarica con il cookie di Access (`crossorigin="use-credentials"`), altrimenti l'installazione come app fallisce.
