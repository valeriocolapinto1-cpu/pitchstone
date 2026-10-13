# ADR 0005: grafo

Stato: accettata, 2026-10-13. Riferimento: ARCHITETTURA.md, sezioni 2, 4 e 9 (fase 3).

## Contesto

Il grafo deve restare fluido con diverse migliaia di nodi su iPad, con i gesti concordati (pinch, pan, tap, doppio tap, Pencil per collegare), cluster per area, ricerca con filtri e zoom semantico. Il codice iOS si compila solo in CI su macOS, quindi la logica deve essere testabile su Linux.

## Decisioni

**Separazione**
- `PitchstoneGraph` (Foundation pura, testata su Linux): dati del grafo, layout, indice spaziale, camera e significato dei gesti, zoom semantico, ricerca. SpriteKit si limita a disegnare (`ios/Pitchstone/Graph`).

**Layout**
- Fruchterman–Reingold con repulsione Barnes–Hut (quadtree in array piatti, O(n log n) per iterazione) e una gravità verso il centro della propria area: le aree sono settori di un cerchio, quindi i cluster si formano da soli.
- Deterministico (posizioni iniziali ricavate dall'UUID) e incrementale: i nodi già disposti partono dalla posizione precedente con pochi passi piccoli, così il grafo non si rimescola a ogni modifica.
- Calcolato in background e solo quando cambia la struttura (nodi, aree, archi). 3000 nodi e 6000 archi, 100 iterazioni: 0,38 s in release su Linux.

**Disegno**
- Nodi: sprite con un'unica texture circolare colorata per area (un solo draw call). I nodi di salute hanno sempre il colore dedicato (rosa), qualunque sia l'area.
- Archi: un unico percorso, spessore costante sullo schermo.
- Zoom semantico su tre livelli: da lontano bolle delle aree con il numero di nodi, a distanza media i nodi, da vicino i titoli. Le etichette sono un insieme fisso riciclato, al massimo 150, solo per i nodi visibili (indice a griglia), con precedenza ai più collegati.
- Shader Metal (`SKShader`, compilato da SpriteKit per Metal): i risultati della ricerca pulsano. Solo fino a 200 risultati, perché uno shader per sprite interrompe il raggruppamento dei draw call.
- Un salvataggio che non cambia la struttura aggiorna solo dati ed etichette.

**Gesti**
- Pinch: zoom attorno al punto tra le dita (0,05–6). Pan con il dito. Tap: apre il nodo in anteprima; doppio tap: lo apre in modifica. Raggio del tocco costante sullo schermo (24 punti).
- Pencil da un nodo a un altro: arco di tipo `manual`, senza doppioni. La Pencil non sposta il grafo.

**Archi dai link**
- Al salvataggio i `[[Titolo]]` del corpo diventano archi di tipo `link` (creati, ripristinati, messi nel cestino quando spariscono dal testo). Gli archi manuali e dell'AI non vengono toccati. Le regole di privacy della sync valgono anche qui: un arco verso un nodo di salute resta locale.

**Ricerca**
- Testo su titolo, tag e corpo (senza maiuscole e accenti), filtri per area e tipo, risultati ordinati per rilevanza e collegamenti. La ricerca semantica arriva con gli embedding della fase 5.

## Conseguenze

- La fluidità reale (60–120 fps con migliaia di nodi) si verifica sul dispositivo.
- Rinominare un nodo non aggiorna i `[[link]]` degli altri: lo farà un'operazione di rinomina dedicata.
