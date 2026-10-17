# ADR 0018: correttezza della sincronizzazione

Stato: accettata, 2026-10-17. Integra l'ADR 0002 (sincronizzazione).

## Decisioni

- **Contratto condiviso** (`contract/`): JSON Schema e esempi di `/sync/push` e `/sync/pull`, letti dai test dell'iPad (`ContractTests.swift`), della PWA e del Worker. Ogni richiesta porta `X-Pitchstone-Api`; sotto la versione minima il Worker risponde 426 («Aggiorna l'app»); `GET /sync/config` espone i limiti in vigore.
- **Database**: nella risoluzione di un conflitto la base è l'ultima versione dello storico fino a quella del client (anche se la versione esatta non ha una riga); i tag si uniscono a tre vie (una rimozione si propaga, un'aggiunta si tiene; lo storico ricorda i tag); un push ripetuto perché la risposta era andata persa, con lo stesso contenuto già applicato, non crea versioni né conflitti finti (nodi e archi); `merge_bodies` rifiuta un `device_id` che potrebbe chiudere il commento del segnaposto di conflitto.
- **iPad**: i risultati del push si abbinano per entità e id (non per posizione) e un record con un id che non è della voce non si applica; uno stato sconosciuto del server (`.unknown`) lascia la voce in outbox e si riprova; l'intera coda si ordina per entità prima del taglio del lotto (i nodi partono prima di archi e pagine anche con più di 500 voci); un'epoca nuova fa ripartire il pull da zero (la prima volta si ricorda e basta); il pull applica ogni pagina in una transazione e, se il salvataggio fallisce, il cursore non avanza; un salvataggio fallito annulla il contesto e mostra l'errore invece di una `assertionFailure` (`SwiftDataSyncStore`, `StudyStore`); i rifiuti per genitore mancante si riprovano da soli (al massimo 5 volte per sessione, con attese di 30 s, 1 min, 2 min…), gli altri aspettano l'utente; un caricamento di allegato interrotto riprende dalle parti che mancano (segno `<id>.parts` accanto al file, legato allo sha256); «Conferma salute» considera sul server anche un nodo con una modifica in attesa che parte da una base.
- **PWA**: un pull non sostituisce una versione più recente di quella locale; il cursore non torna indietro e una pagina vuota chiude il giro; richieste con timeout di 30 s; un 400 o 413 sul lotto si riprova una voce alla volta (la sbagliata resta parcheggiata, le altre passano); l'errore della sync non è mascherato da quello del salvataggio; l'eliminazione definitiva di un nodo o di un allegato porta via allegati e annotazioni; epoca come sull'iPad; il polling si ferma con la sessione scaduta, rallenta fino a 10 minuti se la rete non va e riposa a scheda nascosta.

## Conseguenze

- Dopo un ripristino i client ripartono dal cursore 0 e rivedono tutto, ma una modifica locale più recente di quella del server ripristinato resta locale (la versione più alta vince): non si perde, ma non torna sul server finché il nodo non viene modificato.
- Lo storico dei nodi cresce di una colonna (`tags`, nulla per le versioni vecchie, che si uniscono come prima).
- I tentativi automatici per i rifiuti si azzerano a ogni avvio dell'app.
