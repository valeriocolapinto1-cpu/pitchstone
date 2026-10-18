# 0022 — Duplicazione tra client e contratto

## Contesto
La logica di sync, il rilevatore di salute e il retrieval della chat esistono sia in Swift (iPad) sia in TypeScript (PWA), e il protocollo è applicato dal Worker e dal database.

## Decisione
Si accetta la duplicazione (due piattaforme, nessun linguaggio comune) e la si tiene sotto controllo con artefatti condivisi:
- `contract/` contiene gli schemi JSON e le fixture del protocollo; Worker, PWA e iPad li verificano nei propri test.
- Il rilevatore di salute ha liste di termini generate dal sorgente TypeScript e gli stessi esempi nei test dei due lati.
- Il retrieval dell'iPad e della PWA possono divergere (BM25 solo sulla PWA); sono verificati ciascuno da un proprio set di valutazione.

## Conseguenze
Ogni modifica a un gemello va riportata nell'altro nello stesso PR (regola in `CONTRIBUTING.md`). Le divergenze volute vanno scritte in un ADR.
