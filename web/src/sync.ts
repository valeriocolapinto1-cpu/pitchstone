import type { EdgeRecord, Entity, ExtraRecord, NodeRecord, PendingChange } from "./model";
import type { Store } from "./store";

export interface PushResult {
  entity?: string;
  id?: string;
  status: "created" | "updated" | "merged" | "rejected";
  record?: NodeRecord | EdgeRecord;
  error?: string;
  message?: string;
}

export interface Transport {
  push(body: { device_id: string; changes: unknown[] }): Promise<{ results: PushResult[] }>;
  pull(body: { cursor: number; limit: number }): Promise<{ changes: { entity: string; data: unknown }[]; cursor: number; has_more: boolean }>;
}

/** Il Worker sulla stessa origine: Cloudflare Access aggiunge da solo il token del login Google. */
export class HttpTransport implements Transport {
  constructor(private base = "") {}

  private async post<T>(path: string, body: unknown): Promise<T> {
    const response = await fetch(`${this.base}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      credentials: "include",
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return (await response.json()) as T;
  }

  push(body: { device_id: string; changes: unknown[] }) { return this.post<{ results: PushResult[] }>("/sync/push", body); }
  pull(body: { cursor: number; limit: number }) {
    return this.post<{ changes: { entity: string; data: unknown }[]; cursor: number; has_more: boolean }>("/sync/pull", body);
  }
}

/**
 * Sync offline-first come sull'iPad (ADR 0002): push dell'outbox, poi pull dal cursore.
 * Una modifica locale non ancora inviata non viene mai sovrascritta da un pull.
 */
export class SyncClient {
  static readonly batchSize = 200;
  private running = false;

  constructor(
    private store: Store,
    private transport: Transport,
    private deviceId: string,
  ) {}

  async sync(): Promise<{ pushed: number; pulled: number } | "skipped"> {
    if (this.running) return "skipped";
    this.running = true;
    try {
      const pushed = await this.pushAll();
      const pulled = await this.pullAll();
      await this.store.flush();
      return { pushed, pulled };
    } finally {
      this.running = false;
    }
  }

  get rejections(): PendingChange[] {
    return this.store.pending().filter((p) => p.rejection);
  }

  private record(change: PendingChange): NodeRecord | EdgeRecord | undefined {
    return change.entity === "node" ? this.store.node(change.id) : this.store.edge(change.id);
  }

  private async pushAll(): Promise<number> {
    let pushed = 0;
    const sent = new Set<string>();
    for (;;) {
      const batch = this.store.pending()
        .filter((p) => !p.rejection && !sent.has(`${p.entity}:${p.id}`))
        // Nodi prima degli archi: un arco ha bisogno dei suoi estremi sul server.
        .sort((a, b) => (a.entity === b.entity ? a.revision - b.revision : a.entity === "node" ? -1 : 1))
        .slice(0, SyncClient.batchSize)
        .map((p) => ({ pending: p, record: this.record(p) }))
        .filter((item) => {
          if (item.record) return true;
          this.store.removePending(item.pending.entity, item.pending.id);
          return false;
        });
      if (batch.length === 0) return pushed;
      for (const item of batch) sent.add(`${item.pending.entity}:${item.pending.id}`);
      const response = await this.transport.push({
        device_id: this.deviceId,
        changes: batch.map((item) => ({ entity: item.pending.entity, base_version: item.pending.baseVersion, data: item.record })),
      });
      if (response.results.length !== batch.length) throw new Error("risposta del server non valida");
      batch.forEach((item, i) => this.apply(response.results[i], item.pending));
      pushed += batch.length;
    }
  }

  private apply(result: PushResult, snapshot: PendingChange) {
    const current = this.store.pendingChange(snapshot.entity, snapshot.id);
    if (!current) return;
    if (result.status === "rejected") {
      if (current.revision === snapshot.revision) {
        this.store.savePending({ ...current, rejection: result.message ?? result.error ?? "rifiutata" });
      }
      return;
    }
    const record = result.record;
    if (current.revision !== snapshot.revision) {
      // Modificato di nuovo durante il push: resta in outbox. Dopo un merge si riparte dalla
      // versione vecchia, così il server unisce di nuovo e niente va perso.
      if (result.status !== "merged" && record) this.store.savePending({ ...current, baseVersion: record.version });
      return;
    }
    if (record) this.save(snapshot.entity, record);
    this.store.removePending(snapshot.entity, snapshot.id);
  }

  private save(entity: Entity, record: NodeRecord | EdgeRecord) {
    if (entity === "node") this.store.saveNode(record as NodeRecord);
    else this.store.saveEdge(record as EdgeRecord);
  }

  private async pullAll(): Promise<number> {
    let pulled = 0;
    for (;;) {
      const page = await this.transport.pull({ cursor: this.store.cursor(), limit: 500 });
      for (const change of page.changes) {
        this.incoming(change.entity, change.data);
        pulled += 1;
      }
      this.store.setCursor(page.cursor);
      if (!page.has_more) return pulled;
    }
  }

  private incoming(entity: string, data: unknown) {
    switch (entity) {
      case "node":
      case "edge": {
        const record = data as NodeRecord | EdgeRecord;
        if (this.store.pendingChange(entity, record.id)) return;
        this.save(entity, record);
        return;
      }
      case "ink_page":
      case "attachment":
        this.store.saveExtra(entity, data as ExtraRecord);
        return;
      case "purged": {
        const { entity: kind, id } = data as { entity: string; id: string };
        if (kind === "node" || kind === "edge") {
          this.store.removePending(kind, id);
          this.store.remove(kind, id);
        } else if (kind === "ink_page" || kind === "attachment") {
          this.store.remove(kind, id);
        }
        return;
      }
      default:
        // Versioni dei nodi ed entità future: non servono alla PWA.
        return;
    }
  }
}
