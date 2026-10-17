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
  dismissed: Record<string, string[]>;
  redact: string[];
}

function empty(): Snapshot {
  return { nodes: {}, edges: {}, ink_page: {}, attachment: {}, pending: {}, cursor: 0, dismissed: {}, redact: [] };
}

export class MemoryStore implements Store {
  protected data: Snapshot = empty();

  async load(): Promise<void> {}
  async flush(): Promise<void> {}
  async wipe(): Promise<void> { this.data = empty(); }

  nodes() { return Object.values(this.data.nodes); }
  edges() { return Object.values(this.data.edges); }
  node(id: string) { return this.data.nodes[id]; }
  edge(id: string) { return this.data.edges[id]; }
  saveNode(node: NodeRecord) { this.data.nodes[node.id] = node; }
  saveEdge(edge: EdgeRecord) { this.data.edges[edge.id] = edge; }
  extras(kind: "ink_page" | "attachment") { return Object.values(this.data[kind]); }
  extra(kind: "ink_page" | "attachment", id: string) { return this.data[kind][id]; }
  saveExtra(kind: "ink_page" | "attachment", record: ExtraRecord) { this.data[kind][record.id] = record; }

  remove(entity: Entity | "attachment", id: string) {
    if (entity === "node") delete this.data.nodes[id];
    else if (entity === "edge") delete this.data.edges[id];
    else delete this.data[entity][id];
  }

  pending() { return Object.values(this.data.pending).sort((a, b) => a.revision - b.revision); }
  pendingChange(entity: Entity, id: string) { return this.data.pending[`${entity}:${id}`]; }
  savePending(change: PendingChange) { this.data.pending[`${change.entity}:${change.id}`] = change; }
  removePending(entity: Entity, id: string) { delete this.data.pending[`${entity}:${id}`]; }
  cursor() { return this.data.cursor; }
  setCursor(cursor: number) { this.data.cursor = cursor; }
  dismissedSignals(id: string) { return this.data.dismissed[id] ?? []; }
  setDismissedSignals(id: string, signals: string[]) { this.data.dismissed[id] = [...new Set(signals)].sort(); }
  redactQueue() { return [...this.data.redact]; }
  queueRedact(id: string) { if (!this.data.redact.includes(id)) this.data.redact.push(id); }
  unqueueRedact(id: string) { this.data.redact = this.data.redact.filter((x) => x !== id); }
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
      const saved = await this.request<Snapshot | undefined>((s) => s.get("snapshot"));
      this.data = { ...empty(), ...saved };
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

  /** Risolve solo a transazione conclusa: il successo della richiesta non vuol dire che sia su disco. */
  override async flush(): Promise<void> {
    if (!this.db) return;
    const snapshot = structuredClone(this.data);
    await new Promise<void>((resolve, reject) => {
      const tx = this.db!.transaction("state", "readwrite");
      tx.objectStore("state").put(snapshot, "snapshot");
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error ?? new Error("salvataggio interrotto"));
    });
  }

  /** Cancella l'archivio dalla memoria e dal disco. */
  override async wipe(): Promise<void> {
    this.data = empty();
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
