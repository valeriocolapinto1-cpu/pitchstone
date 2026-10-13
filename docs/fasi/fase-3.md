# Fase 3: grafo

Stato: in revisione.

## Obiettivo

Grafo con SpriteKit, shader Metal, cluster per area, gesti, ricerca con filtri, zoom semantico. Decisioni in [ADR 0005](../decisioni/0005-grafo.md).

## Criteri di completamento

- [ ] Il grafo resta fluido con diverse migliaia di nodi: layout in background (3000 nodi in 0,38 s in release), disegno in batch, etichette e query limitate ai nodi visibili; da verificare sul dispositivo.
- [x] I gesti concordati funzionano: pinch, pan, tap, doppio tap, Pencil per collegare (logica testata, da provare sul dispositivo).
- [x] I nodi di salute sono visibili con colore dedicato.

## Test

- [x] Test di prestazioni su un grafo di esempio: layout di 3000 nodi e 6000 archi, query per fotogramma sotto i 16 ms (Linux), caricamento della scena con 3000 nodi (simulatore).
- [x] Test dei gesti principali: pinch con punto fermo e limiti, pan, tap con raggio costante, Pencil tra due nodi, zoom semantico, inquadratura.
- [x] Layout: cluster per area, determinismo, stabilità quando si aggiunge un nodo.
- [x] Ricerca con filtri e archi dai `[[link]]`.

## Verifiche su dispositivo

- [ ] Fluidità con il tuo grafo e con un grafo di prova di qualche migliaio di nodi.
- [ ] Gesti con dita e Pencil.
