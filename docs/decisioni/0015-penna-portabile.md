# ADR 0015: penna anche sul PC (formato PSINK1)

Stato: accettata, 2026-10-16. Riferimento: ADR 0004 (disegno), ADR 0013 (PWA).

## Contesto

Sul PC si vuole scrivere a mano con una tavoletta grafica (Wacom e simili) e ritrovare le stesse pagine sull'iPad, e viceversa. Finora `ink_pages.ink_data` conteneva `PKDrawing.dataRepresentation()`: un formato binario di Apple che il browser non sa leggere né scrivere. Il server e la sync non cambiano: cambia solo il contenuto dei byte.

## Decisioni

**Formato PSINK1**
- `ink_data` = byte UTF-8 di `PSINK1\n` seguiti da un JSON su una riga:
  `{"v":1,"width":W,"height":H,"strokes":[{"tool":"pen"|"marker"|"pencil","color":"#rrggbbaa","width":L,"points":[[x,y,p,t],...]}]}`.
- `width` è la larghezza della pagina e definisce lo spazio delle coordinate; ogni client lo mappa sulla larghezza della sua tela. `height` è l'altezza della pagina: A4 (`width × 1,414`) o il tratto più basso più 200, come la tela dell'iPad.
- Un punto è `[x, y, pressione 0…1, secondi dall'inizio del tratto]`. `width` del tratto è la larghezza a pressione 0,5; la larghezza disegnata è `width × (0,4 + 1,2 × p)`, l'evidenziatore è uniforme.
- Colore `#rrggbbaa` nell'aspetto chiaro, come lo salva PencilKit; in tema scuro i client invertono la luminosità (PencilKit lo fa da sé, la PWA allo stesso modo).
- Codifica canonica, così iPad e PC scrivono gli stessi byte e il confronto dei conflitti sul server resta esatto: chiavi in quest'ordine, coordinate e larghezze arrotondate a 0,1, pressione a 0,01, tempo a 0,001 (arrotondamento simmetrico rispetto allo zero), numeri interi senza decimali. Pagina senza tratti: zero byte, come prima.
- Lettura tollerante: chiavi sconosciute ignorate, strumento sconosciuto → `pen`, colore non valido → nero, punti senza pressione o tempo → 0,5 e 0. `v` diverso da 1 è un errore (un formato nuovo avrà un altro prefisso o un'altra versione).
- Il file di esempio `docs/fixtures/psink1-esempio.psink` lo leggono i test di entrambi i lati (`web/test/ink.test.ts`, `PortableInkTests`): stessa lettura e stessi byte in scrittura.

**iPad**
- Codec puro in `PitchstoneSync/PortableInk.swift` (solo Foundation, testato su Linux); ponte con PencilKit nell'app (`Features/Ink/InkPortable.swift`).
- Le pagine del nodo si salvano in PSINK1; si leggono sia PSINK1 sia i PKDrawing di prima, che diventano PSINK1 alla prima modifica. PSINK1 si scala sulla larghezza della tela e si risalva con quella larghezza come `width`.
- Dalla tela: punti di controllo del tratto con la sua trasformazione (lazo), larghezza media dei punti come `width`, pressione ricavata dalla dimensione di ogni punto. Gli inchiostri che il PC non ha (monoline, stilografica, acquerello, pastello) diventano `pen`.
- La gomma pixel di PencilKit lascia tratti con una maschera che PSINK1 non rappresenta: una pagina con maschere resta PKDrawing, si modifica solo sull'iPad e non perde niente. Per tenerla modificabile dal PC si usa la gomma a tratti.
- Le annotazioni sui PDF restano PKDrawing (sul PC non si vedono). L'OCR della scrittura a mano legge entrambi i formati.

**PWA**
- Vista "Penna" del nodo: pagine come schede, "Nuova pagina", eliminazione nel cestino; strumenti penna, evidenziatore, gomma a tratti; cinque colori, tre spessori, annulla e ripristina (anche Ctrl+Z, Ctrl+Maiusc+Z), sfondo bianco, a righe o a quadretti.
- Pointer Events con `touch-action: none`, cattura del puntatore ed eventi uniti (`getCoalescedEvents`): pressione vera dalla penna (`pointerType` `pen`), 0,5 da mouse e dito. Il retro della penna (gomma della Wacom, tasto 5 / `buttons & 32`) cancella sempre. Tratti con curve quadratiche tra i punti medi e larghezza che segue la pressione.
- Salvataggio un secondo dopo l'ultimo tratto, prima della sync e quando si cambia pagina o nodo, con la stessa outbox di nodi e archi (`entity: "ink_page"`). Come sull'iPad: un pull non sovrascrive una pagina con modifiche non inviate, e se una sync ha cambiato la pagina mentre si disegnava i tratti vanno in una nuova pagina.
- Le pagine in PKDrawing si vedono come "Pagina scritta sull'iPad: si modifica lì".
- Limite di 2 MB per pagina come sul database: oltre, la PWA chiede di continuare in una nuova pagina.

**Salute**: invariato. Le pagine dei nodi di salute non lasciano l'iPad; la PWA crea pagine solo per i nodi che ha (mai di salute) e scarta quelle che arrivassero legate a un nodo di salute.

## Conseguenze

- Il server, il Worker e lo schema non cambiano: `sync_push` accetta già `ink_page` e il Worker controlla solo i dati di salute.
- PSINK1 è più grande di un PKDrawing (testo invece di binario, circa 25 byte per punto); una pagina fitta resta comunque lontana dai 2 MB.
- Una pagina salvata in PSINK1 perde sull'iPad i dettagli che il formato non ha (inclinazione e azimut della Pencil, tipo di inchiostro esotico); forma, pressione e colore restano.
- Il ponte PencilKit dell'app si verifica solo con Xcode (`PitchstoneTests/InkPortableTests.swift`).
