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
  saveExtra(kind: "ink_page" | "attachment", record: ExtraRecord): void;
  remove(entity: Entity | "ink_page" | "attachment", id: string): void;
  pending(): PendingChange[];
  pendingChange(entity: Entity, id: string): PendingChange | undefined;
  savePending(change: PendingChange): void;
  removePending(entity: Entity, id: string): void;
  cursor(): number;
  setCursor(cursor: number): void;
  /** Scrive su disco le modifiche fatte finora. */
  flush(): Promise<void>;
}

interface Snapshot {
  nodes: Record<string, NodeRecord>;
  edges: Record<string, EdgeRecord>;
  ink_page: Record<string, ExtraRecord>;
  attachment: Record<string, ExtraRecord>;
  pending: Record<string, PendingChange>;
  cursor: number;
}

function empty(): Snapshot {
  return { nodes: {}, edges: {}, ink_page: {}, attachment: {}, pending: {}, cursor: 0 };
}

export class MemoryStore implements Store {
  protected data: Snapshot = empty();

  async load(): Promise<void> {}
  async flush(): Promise<void> {}

  nodes() { return Object.values(this.data.nodes); }
  edges() { return Object.values(this.data.edges); }
  node(id: string) { return this.data.nodes[id]; }
  edge(id: string) { return this.data.edges[id]; }
  saveNode(node: NodeRecord) { this.data.nodes[node.id] = node; }
  saveEdge(edge: EdgeRecord) { this.data.edges[edge.id] = edge; }
  extras(kind: "ink_page" | "attachment") { return Object.values(this.data[kind]); }
  saveExtra(kind: "ink_page" | "attachment", record: ExtraRecord) { this.data[kind][record.id] = record; }

  remove(entity: Entity | "ink_page" | "attachment", id: string) {
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
}

/** Tutto l'archivio in un solo valore IndexedDB: per un archivio personale basta e resta semplice. */
export class IndexedDBStore extends MemoryStore {
  private db?: IDBDatabase;

  override async load(): Promise<void> {
    this.db = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open("pitchstone", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("state");
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    const saved = await this.request<Snapshot | undefined>((s) => s.get("snapshot"));
    this.data = { ...empty(), ...saved };
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

  private request<T>(run: (store: IDBObjectStore) => IDBRequest): Promise<T> {
    return new Promise((resolve, reject) => {
      const tx = this.db!.transaction("state", "readonly");
      const request = run(tx.objectStore("state"));
      request.onsuccess = () => resolve(request.result as T);
      request.onerror = () => reject(request.error);
    });
  }
}
