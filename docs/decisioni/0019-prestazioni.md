# 0019 — Prestazioni

## Fatto
- PWA: l'archivio IndexedDB è diviso in nucleo (nodi, archi, coda) ed extra (disegni, allegati); a ogni salvataggio si scrive solo la parte cambiata. Gli archivi nel formato precedente si dividono al primo salvataggio.
- PWA: ricerca con ritardo di 150 ms e testo normalizzato in cache; `wikiTargets` memorizzato; `marked` e `DOMPurify` caricati al primo uso (e a riposo dopo l'avvio, per l'offline).
- iPad: `fingerprints()` e `sourceIDs()` non leggono più il testo estratto; la chiave SHA dei frammenti si calcola una volta in `init`; la repulsione del grafo riusa la pila.
- Database: script di misura in `backend/supabase/bench/`.

## Non fatto (scelta)
Grafo incrementale, allegati in streaming e `VaultExport` fuori da `body` toccano codice SwiftUI e I/O che qui non si può compilare né misurare: senza una misura che li giustifichi il rischio supera il guadagno. Si riprendono con Instruments sull'iPad.
