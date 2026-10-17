import type { EdgeRecord, Entity, ExtraRecord, NodeRecord, PendingChange } from "./model";

/** Archivio locale della PWA: IndexedDB nel browser, in memoria nei test. */
export interface Store {
  load(): Promise<void>;
  nodes(): NodeRecord[];
  edges(): EdgeRecord[];
  node(id: string): NodeRecord | undefined;
  edge(id: string): EdgeRecord | undefined;
  saveNode(node: NodeRecord): void;
  saveEdge(edge: EdgeRecord): void;
  extras(kind: "ink_page" | "attachment"): ExtraRecord[];
  extra(kind: "ink_page" | "attachment", id: string): ExtraRecord | undefined;
  saveExtra(kind: "ink_page" | "attachment", record: ExtraRecord): void;
  remove(entity: Entity | "attachment", id: string): void;
  pending(): PendingChange[];
  pendingChange(entity: Entity, id: string): PendingChange | undefined;
  savePending(change: PendingChange): void;
  removePending(entity: Entity, id: string): void;
  cursor(): number;
  setCursor(cursor: number): void;
  /** Epoca della sincronizzazione vista l'ultima volta (0 = ancora sconosciuta). */
  epoch(): number;
  setEpoch(epoch: number): void;
  /** Segnali di salute che l'utente ha giudicato innocui per questo nodo. */
  dismissedSignals(id: string): string[];
  setDismissedSignals(id: string, signals: string[]): void;
  /** Nodi che vanno tolti dal server (erano già stati sincronizzati) e non ci sono ancora riusciti. */
  redactQueue(): string[];
  queueRedact(id: string): void;
  unqueueRedact(id: string): void;
  /** Scrive su disco le modifiche fatte finora. */
  flush(): Promise<void>;
  /** Cancella tutti i dati locali (memoria e disco). */
  wipe(): Promise<void>;
}

interface Snapshot {
  nodes: Record<string, NodeRecord>;
  edges: Record<string, EdgeRecord>;
  ink_page: Record<string, ExtraRecord>;
  attachment: Record<string, ExtraRecord>;
  pending: Record<string, PendingChange>;
  cursor: number;
  epoch: number;
  dismissed: Record<string, string[]>;
  redact: string[];
}

function empty(): Snapshot {
  return { nodes: {}, edges: {}, ink_page: {}, attachment: {}, pending: {}, cursor: 0, epoch: 0, dismissed: {}, redact: [] };
}

/**
 * Le parti dell'archivio che si scrivono a parte: il nucleo (nodi, archi, outbox, cursore…) e gli extra (disegni
 * e allegati, la parte pesante). Una modifica al testo riscrive solo il nucleo, non tutti i disegni.
 */
export type Part = "core" | "extras";

export class MemoryStore implements Store {
  protected data: Snapshot = empty();
  /** Parti modificate dall'ultimo salvataggio. */
  protected dirty = new Set<Part>();

  async load(): Promise<void> {}
  async flush(): Promise<void> { this.dirty.clear(); }
  async wipe(): Promise<void> {
    this.data = empty();
    this.dirty.clear();
  }

  nodes() { return Object.values(this.data.nodes); }
  edges() { return Object.values(this.data.edges); }
  node(id: string) { return this.data.nodes[id]; }
  edge(id: string) { return this.data.edges[id]; }
  saveNode(node: NodeRecord) { this.data.nodes[node.id] = node; this.dirty.add("core"); }
  saveEdge(edge: EdgeRecord) { this.data.edges[edge.id] = edge; this.dirty.add("core"); }
  extras(kind: "ink_page" | "attachment") { return Object.values(this.data[kind]); }
  extra(kind: "ink_page" | "attachment", id: string) { return this.data[kind][id]; }
  saveExtra(kind: "ink_page" | "attachment", record: ExtraRecord) { this.data[kind][record.id] = record; this.dirty.add("extras"); }

  remove(entity: Entity | "attachment", id: string) {
    if (entity === "node") { delete this.data.nodes[id]; this.dirty.add("core"); }
    else if (entity === "edge") { delete this.data.edges[id]; this.dirty.add("core"); }
    else { delete this.data[entity][id]; this.dirty.add("extras"); }
  }

  pending() { return Object.values(this.data.pending).sort((a, b) => a.revision - b.revision); }
  pendingChange(entity: Entity, id: string) { return this.data.pending[`${entity}:${id}`]; }
  savePending(change: PendingChange) { this.data.pending[`${change.entity}:${change.id}`] = change; this.dirty.add("core"); }
  removePending(entity: Entity, id: string) { delete this.data.pending[`${entity}:${id}`]; this.dirty.add("core"); }
  cursor() { return this.data.cursor; }
  setCursor(cursor: number) { this.data.cursor = cursor; this.dirty.add("core"); }
  epoch() { return this.data.epoch; }
  setEpoch(epoch: number) { this.data.epoch = epoch; this.dirty.add("core"); }
  dismissedSignals(id: string) { return this.data.dismissed[id] ?? []; }
  setDismissedSignals(id: string, signals: string[]) { this.data.dismissed[id] = [...new Set(signals)].sort(); this.dirty.add("core"); }
  redactQueue() { return [...this.data.redact]; }
  queueRedact(id: string) { if (!this.data.redact.includes(id)) { this.data.redact.push(id); this.dirty.add("core"); } }
  unqueueRedact(id: string) { this.data.redact = this.data.redact.filter((x) => x !== id); this.dirty.add("core"); }
}

const DB_NAME = "pitchstone";

/**
 * Tutto l'archivio in un solo valore IndexedDB: per un archivio personale basta e resta semplice.
 * Se il browser non lo permette (navigazione privata, spazio negato, database bloccato) l'archivio
 * resta in memoria e `persistent` è false: la pagina lo dice, invece di perdere i dati in silenzio.
 */
export class IndexedDBStore extends MemoryStore {
  private db?: IDBDatabase;
  /** Falso se non si riesce ad aprire o a scrivere su disco. */
  persistent = true;
  /** Motivo, se `persistent` è falso. */
  failure?: string;

  override async load(): Promise<void> {
    try {
      this.db = await new Promise<IDBDatabase>((resolve, reject) => {
        const request = indexedDB.open(DB_NAME, 1);
        request.onupgradeneeded = () => request.result.createObjectStore("state");
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error ?? new Error("archivio locale non disponibile"));
        request.onblocked = () => reject(new Error("archivio locale bloccato da un'altra scheda"));
      });
      const core = await this.request<Partial<Snapshot> | undefined>((s) => s.get("snapshot"));
      const extras = await this.request<Pick<Snapshot, "ink_page" | "attachment"> | undefined>((s) => s.get("extras"));
      this.data = { ...empty(), ...core };
      if (extras) {
        this.data.ink_page = extras.ink_page ?? {};
        this.data.attachment = extras.attachment ?? {};
      } else if (core && (Object.keys(core.ink_page ?? {}).length > 0 || Object.keys(core.attachment ?? {}).length > 0)) {
        // Archivio nel formato precedente (tutto in un valore): al prossimo salvataggio si divide in due.
        this.dirty.add("core").add("extras");
      }
    } catch (error) {
      this.persistent = false;
      this.failure = error instanceof Error ? error.message : "archivio locale non disponibile";
    }
  }

  /** Chiede al browser di non cancellare l'archivio quando lo spazio scarseggia. */
  async requestPersistence(): Promise<boolean> {
    try {
      return (await navigator.storage?.persist?.()) ?? false;
    } catch {
      return false;
    }
  }

  /**
   * Risolve solo a transazione conclusa: il successo della richiesta non vuol dire che sia su disco.
   * Scrive solo le parti cambiate: il nucleo è piccolo, gli extra (disegni) pesano.
   */
  override async flush(): Promise<void> {
    if (!this.db || this.dirty.size === 0) return;
    const parts = new Set(this.dirty);
    const { ink_page, attachment, ...core } = this.data;
    const writes: [string, unknown][] = [];
    // Il nucleo non porta più i disegni: nel formato nuovo stanno sotto "extras".
    if (parts.has("core")) writes.push(["snapshot", structuredClone({ ...core, ink_page: {}, attachment: {} })]);
    if (parts.has("extras")) writes.push(["extras", structuredClone({ ink_page, attachment })]);
    await new Promise<void>((resolve, reject) => {
      const tx = this.db!.transaction("state", "readwrite");
      for (const [key, value] of writes) tx.objectStore("state").put(value, key);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error ?? new Error("salvataggio interrotto"));
    });
    // Solo a scrittura riuscita: se è fallita le parti restano da salvare.
    for (const part of parts) this.dirty.delete(part);
  }

  /** Cancella l'archivio dalla memoria e dal disco. */
  override async wipe(): Promise<void> {
    this.data = empty();
    this.dirty.clear();
    this.db?.close();
    this.db = undefined;
    await new Promise<void>((resolve) => {
      try {
        const request = indexedDB.deleteDatabase(DB_NAME);
        request.onsuccess = () => resolve();
        request.onerror = () => resolve();
        request.onblocked = () => resolve();
      } catch {
        resolve();
      }
    });
  }

  private request<T>(run: (store: IDBObjectStore) => IDBRequest): Promise<T> {
    return new Promise((resolve, reject) => {
      const tx = this.db!.transaction("state", "readonly");
      const request = run(tx.objectStore("state"));
      request.onsuccess = () => resolve(request.result as T);
      request.onerror = () => reject(request.error);
    });
  }
}
