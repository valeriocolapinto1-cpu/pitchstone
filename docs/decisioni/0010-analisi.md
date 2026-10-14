# ADR 0010: analisi automatica e rilevamento della salute

Stato: accettata, 2026-10-14. Riferimento: ARCHITETTURA.md, sezioni 6.2, 7 e 9 (fase 6).

## Contesto

Dagli appunti si estraggono nodi e collegamenti. Persone e dati di salute richiedono conferma, e un appunto che parla di salute non deve arrivare a un prompt né al server prima che l'utente decida.

## Decisioni

- Rilevamento della salute sul dispositivo, senza modelli (`HealthDetector`): termini medici più un indizio personale (prima persona, dosi, valori misurati, visite fissate). Gli appunti di studio impersonali di biologia o medicina non vengono segnalati. Un set di esempi (diari, promemoria, appunti di studio, ricette) fa da test di accettazione.
- Un nodo sospetto è trattenuto: le sue modifiche, archi, pagine e allegati restano in outbox (`SyncEngine.holds`), è escluso dal corpus della chat, la sua chat è solo locale e non viene analizzato. Nel nodo compare un avviso con due scelte:
  - "È salute": un nodo mai sincronizzato passa all'area salute. Uno già sul server non può diventare sensibile (ADR 0001), quindi il contenuto va in un nodo di salute nuovo e l'originale, svuotato e rinominato, va nel cestino: il testo trattenuto non parte mai.
  - "Non lo è": i segnali attuali vengono ricordati come innocui; un segnale nuovo riattiva l'avviso.
- Estrazione: il modello risponde con un JSON di nodi (titolo, tipo, riassunto) e collegamenti. Il parser accetta blocchi di codice e testo intorno; tipi sconosciuti diventano `concept`, `health` non è ammesso. Al massimo 8 nodi per appunto.
- Piano: i titoli già esistenti diventano solo archi; persone e possibili dati di salute (titolo o riassunto con termini medici) vanno in conferma; il resto si crea nell'area del nodo analizzato, con archi di tipo `ai`. Rianalizzare non crea doppioni.
- Modelli: in automatico solo il modello locale (gratis e offline), 20 secondi dopo le modifiche, per i nodi modificati nella sessione con almeno 200 caratteri e testo cambiato dall'ultima analisi. Il pulsante "Analizza" usa il locale e, se manca o risponde male, Gemini.
- Lo stato dell'analisi (segnali giudicati innocui, impronta dell'ultima analisi, proposte in attesa) è locale (`AnalysisStateEntity`) e non si sincronizza.

## Conseguenze

- Il rilevatore è a regole: sbaglia in modo prevedibile. Un falso positivo costa un tocco, un falso negativo è l'errore da evitare. Il set di test va ampliato con gli appunti reali.
- Gli appunti di farmacologia con dosi possono chiedere conferma.
- Su un iPad senza Apple Intelligence l'analisi automatica non parte; resta il pulsante con Gemini.
