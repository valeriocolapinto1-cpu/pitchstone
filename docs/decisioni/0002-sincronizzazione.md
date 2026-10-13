# ADR 0002: sincronizzazione

Stato: accettata, 2026-10-13. Riferimento: ARCHITETTURA.md, sezioni 3, 6.5 e 7; ADR 0001.

## Contesto

L'iPad è offline-first e la fonte di verità per la lettura. Supabase è il punto di sincronizzazione. `anon` non ha accesso a nessuna tabella utente (ADR 0001), quindi la sync ha bisogno di un percorso autorizzato.

## Decisioni

**Percorso**
- iPad → Cloudflare Access (service token nel Keychain) → Worker `ai-proxy` → Supabase.
- Il Worker verifica il JWT di Access (`Cf-Access-Jwt-Assertion`: firma RS256 con le chiavi del team, `iss`, `aud`, scadenza). Senza questa verifica Access si potrebbe aggirare chiamando l'indirizzo `*.workers.dev`. Configurazione mancante: risposta 401, mai accesso aperto.
- Il Worker chiama le funzioni `sync_push` e `sync_pull` con la chiave segreta di Supabase (`SUPABASE_SECRET_KEY`, secret del Worker). Accetta sia le nuove chiavi `sb_secret_` sia la chiave legacy `service_role`.
- Solo `service_role` può eseguire le funzioni di sync; `anon` e `authenticated` no (test pgTAP).

**Pull incrementale**
- Contatore globale `server_seq` (sequence `sync_seq`) su `nodes`, `edges`, `node_versions` e `purged`, assegnato da un trigger.
- Il trigger prende un advisory lock prima di `nextval`: le scritture sono serializzate, quindi l'ordine di `server_seq` coincide con l'ordine di commit e il pull per cursore non salta righe. Per un utente solo il costo è nullo.
- Pagine di al massimo 1000 modifiche (500 dal client), con `has_more`.

**Push e conflitti**
- Ogni modifica porta `base_version`, l'ultima versione del server nota al client. Il server assegna sempre la versione.
- `base_version` uguale alla versione corrente: aggiornamento normale.
- Diversa: conflitto. Il server crea una nuova versione con il corpo di entrambi (separati da un marcatore `<!-- conflitto: versione da … -->`), unisce i tag, prende titolo, tipo e area del client. Un nodo resta nel cestino solo se entrambe le parti lo hanno eliminato: una modifica vince su un'eliminazione concorrente.
- Lo storico (`node_versions`) è scritto dal server a ogni cambio del corpo. Nessuna versione va persa.
- Ogni modifica è applicata in un proprio savepoint: una modifica non valida viene rifiutata (`rejected`) senza bloccare le altre né l'outbox.
- Il push è idempotente: se la risposta si perde, il nuovo invio produce un merge con corpi uguali, quindi nessun duplicato.

**Client (ios/PitchstoneKit)**
- Package Swift separato dal progetto Xcode: `PitchstoneSync` (Foundation pura: record, outbox, repository, motore di sync, trasporto HTTP) si testa su Linux in `ci-linux`, a costo 1x; `PitchstoneStore` (SwiftData, Keychain, monitor di rete) si testa su macOS in `ci-ios`. L'app della fase 2 dipenderà dal package.
- Outbox con una voce per record: le modifiche successive si fondono e la voce conserva la `base_version` di partenza.
- Il pull non sovrascrive mai un record con modifiche locali non ancora inviate: sarà il server a unirle al push successivo.
- Se un record cambia mentre il suo push è in volo, la voce resta in outbox; dopo un merge conserva la versione di partenza, così il server unisce di nuovo invece di sovrascrivere.
- La sync parte al ritorno della rete (`AutoSync`, `NWPathMonitor`) e dopo le modifiche locali.

**Privacy**
- Il filtro principale è sul client: nodi `health` o in area `salute`, e archi che li toccano, non entrano nell'outbox e sono scartati di nuovo al momento del push.
- Il Worker rifiuta con 400 qualsiasi push che contenga `health` o `salute`; il database li rifiuta comunque con i check.
- Un nodo già sincronizzato non può diventare sensibile: la sua storia è già sul server. Va creato un nuovo nodo di salute. Un nodo mai sincronizzato può diventarlo e lascia l'outbox.

**Cestino**
- Eliminare significa impostare `deleted_at`; il ripristino lo riporta a null. Entrambi si sincronizzano.
- Dopo 30 giorni `purge_trash()` elimina definitivamente nodi, archi collegati e storico. Gira ogni giorno alle 03:00 UTC con `pg_cron`. Le eliminazioni definitive sono registrate in `purged` e arrivano ai client con il pull; il client applica la stessa regola in locale, anche ai nodi di salute.

## Conseguenze

- Prima del primo deploy servono: `SUPABASE_SECRET_KEY` come secret del Worker, `SUPABASE_URL`, `ACCESS_TEAM_DOMAIN` e `ACCESS_AUD` in `wrangler.toml`, applicazione Access sul dominio del Worker con la policy del service token.
- Lo storico mostra solo versioni accettate dal server: le modifiche fatte offline compaiono nello storico dopo la sync.
- Le altre tabelle (allegati, chat, quiz) useranno lo stesso schema (`server_seq`, `base_version`) nelle loro fasi.
