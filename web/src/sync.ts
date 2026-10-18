import { type EdgeRecord, type Entity, type ExtraRecord, type InkPageRecord, isSafeId, type NodeRecord, type PendingChange } from "./model";
import type { Store } from "./store";

export interface PushResult {
  entity?: string;
  id?: string;
  status: "created" | "updated" | "merged" | "rejected";
  record?: SyncRecord;
  error?: string;
  message?: string;
}

type SyncRecord = NodeRecord | EdgeRecord | InkPageRecord;

/** Ordine del push: un arco e una pagina hanno bisogno del loro nodo sul server. */
const PUSH_ORDER: Record<Entity, number> = { node: 0, ink_page: 1, edge: 2 };

export interface PullPage {
  changes: { entity: string; data: unknown }[];
  cursor: number;
  has_more: boolean;
  /** Epoca della sincronizzazione: cambia quando il server viene ripristinato da un backup. */
  epoch?: number;
}

/** Versione del contratto (contract/README.md), mandata in `X-Pitchstone-Api`. */
export const API_VERSION = 1;

export interface Transport {
  push(body: { device_id: string; changes: unknown[] }): Promise<{ results: PushResult[] }>;
  pull(body: { cursor: number; limit: number }): Promise<PullPage>;
  /** Toglie una nota dal server con storico, archi e pagine (era sincronizzata e non deve più esserlo). */
  redact?(id: string): Promise<void>;
}

/** Sessione di Cloudflare Access scaduta: serve un nuovo login, non è un problema di rete. */
export class AuthError extends Error {}

/** Risposta di errore del Worker: lo stato dice se la richiesta è sbagliata (4xx) o il server è in difficoltà (5xx). */
export class HttpError extends Error {
  constructor(readonly status: number) {
    super(`HTTP ${status}`);
  }
}

/** Il server chiede una versione più recente dell'app (426). */
export class OutdatedError extends Error {
  constructor() {
    super("versione dell'app non più supportata: ricarica la pagina");
  }
}

/** Tempo massimo di una richiesta: una rete che non risponde non deve bloccare la sync per sempre. */
export const REQUEST_TIMEOUT_MS = 30_000;

/** Il Worker sulla stessa origine: Cloudflare Access aggiunge da solo il token del login Google. */
export class HttpTransport implements Transport {
  constructor(private base = "") {}

  private async post<T>(path: string, body: unknown): Promise<T> {
    const response = await fetch(`${this.base}${path}`, {
      method: "POST",
      body: JSON.stringify(body),
      headers: { "content-type": "application/json", "x-pitchstone-api": String(API_VERSION) },
      credentials: "include",
      // Access manda alla pagina di login con un redirect: lo vediamo invece di seguirlo.
      redirect: "manual",
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (response.type === "opaqueredirect" || response.status === 401 || response.status === 403) {
      throw new AuthError("login scaduto");
    }
    if (response.status === 426) throw new OutdatedError();
    if (!response.ok) throw new HttpError(response.status);
    return (await response.json()) as T;
  }

  push(body: { device_id: string; changes: unknown[] }) { return this.post<{ results: PushResult[] }>("/sync/push", body); }
  pull(body: { cursor: number; limit: number }) {
    return this.post<PullPage>("/sync/pull", body);
  }
  async redact(id: string) { await this.post("/sync/redact", { id }); }
}

/**
 * Sync offline-first come sull'iPad (ADR 0002): push dell'outbox, poi pull dal cursore.
 * Una modifica locale non ancora inviata non viene mai sovrascritta da un pull.
 */
export class SyncClient {
  static readonly batchSize = 200;
  /** Sotto il limite di 5 MB del Worker, come maxBatchBytes dell'iPad. */
  static readonly maxBatchBytes = 3_500_000;
  private running = false;

  constructor(
    private store: Store,
    private transport: Transport,
    private deviceId: string,
    /** Nodi che non devono partire (solo locali o sospetti di salute): le loro modifiche restano in outbox. */
    private blocked: (nodeId: string) => boolean = () => false,
  ) {}

  async sync(): Promise<{ pushed: number; pulled: number } | "skipped"> {
    if (this.running) return "skipped";
    this.running = true;
    let failure: unknown;
    let result: { pushed: number; pulled: number } | undefined;
    try {
      await this.redactAll();
      const pushed = await this.pushAll();
      const pulled = await this.pullAll();
      result = { pushed, pulled };
    } catch (error) {
      failure = error;
    } finally {
      this.running = false;
    }
    // Anche dopo un errore: le risposte già applicate non vanno perse. Ma se anche il salvataggio
    // fallisce, l'errore che si vede è quello della sync, non quello del salvataggio.
    try {
      await this.store.flush();
    } catch (error) {
      failure ??= error;
    }
    if (failure !== undefined) throw failure;
    return result as { pushed: number; pulled: number };
  }

  get rejections(): PendingChange[] {
    return this.store.pending().filter((p) => p.rejection);
  }

  /** La voce rifiutata riparte al prossimo push. */
  retry(entity: Entity, id: string) {
    const pending = this.store.pendingChange(entity, id);
    if (pending) this.store.savePending({ ...pending, rejection: undefined });
  }

  /**
   * Scarta la modifica locale e tiene quella del server. Un record mai arrivato al server
   * sparisce (con archi e pagine di un nodo); per gli altri il pull riparte da capo e riporta
   * la versione del server.
   */
  discard(entity: Entity, id: string) {
    const pending = this.store.pendingChange(entity, id);
    if (!pending) return;
    this.store.removePending(entity, id);
    if (pending.baseVersion === null) {
      if (entity === "node") this.removeNode(id);
      else this.store.remove(entity, id);
    } else {
      this.store.setCursor(0);
    }
  }

  /** Nodo, archi che lo toccano e sue pagine a penna, con le loro voci in outbox. */
  private removeNode(id: string) {
    for (const edge of this.store.edges()) {
      if (edge.source_id === id || edge.target_id === id) {
        this.store.removePending("edge", edge.id);
        this.store.remove("edge", edge.id);
      }
    }
    for (const page of this.store.extras("ink_page")) {
      if (page.node_id === id) {
        this.store.removePending("ink_page", page.id);
        this.store.remove("ink_page", page.id);
      }
    }
    for (const attachment of this.store.extras("attachment")) {
      if (attachment.node_id === id) this.removeAttachment(attachment.id);
    }
    this.store.removePending("node", id);
    this.store.remove("node", id);
  }

  /** Allegato eliminato per sempre: la riga e le annotazioni sui suoi PDF. */
  private removeAttachment(id: string) {
    for (const page of this.store.extras("ink_page")) {
      if (page.attachment_id === id) {
        this.store.removePending("ink_page", page.id);
        this.store.remove("ink_page", page.id);
      }
    }
    this.store.remove("attachment", id);
  }

  /** Toglie dal server le note diventate solo locali; quelle che non ci riescono restano in coda. */
  private async redactAll(): Promise<void> {
    if (!this.transport.redact) return;
    for (const id of this.store.redactQueue()) {
      await this.transport.redact(id);
      this.store.unqueueRedact(id);
      this.forget(id);
    }
  }

  /** Il server non ha più il nodo: in locale diventa un record mai sincronizzato (versione 0, base nulla). */
  private forget(id: string) {
    const node = this.store.node(id);
    if (node) this.store.saveNode({ ...node, version: 0 });
    this.rebase("node", id);
    for (const edge of this.store.edges()) {
      if (edge.source_id !== id && edge.target_id !== id) continue;
      this.store.saveEdge({ ...edge, version: 0 });
      this.rebase("edge", edge.id);
    }
    for (const page of this.store.extras("ink_page")) {
      if (page.node_id !== id) continue;
      this.store.saveExtra("ink_page", { ...page, version: 0 });
      this.rebase("ink_page", page.id);
    }
  }

  private rebase(entity: Entity, id: string) {
    const pending = this.store.pendingChange(entity, id);
    this.store.savePending({ entity, id, baseVersion: null, revision: pending?.revision ?? Date.now(), rejection: undefined });
  }

  /** La voce riguarda un nodo che non deve partire? Un arco o una pagina seguono i loro nodi. */
  private isBlocked(change: PendingChange): boolean {
    switch (change.entity) {
      case "node": return this.blocked(change.id);
      case "edge": {
        const edge = this.store.edge(change.id);
        return !!edge && (this.blocked(edge.source_id) || this.blocked(edge.target_id));
      }
      case "ink_page": {
        const page = this.store.extra("ink_page", change.id);
        return !!page && !!page.node_id && this.blocked(page.node_id);
      }
    }
  }

  private record(change: PendingChange): SyncRecord | undefined {
    switch (change.entity) {
      case "node": return this.store.node(change.id);
      case "edge": return this.store.edge(change.id);
      case "ink_page": return this.store.extra("ink_page", change.id) as InkPageRecord | undefined;
    }
  }

  private async pushAll(): Promise<number> {
    let pushed = 0;
    const sent = new Set<string>();
    for (;;) {
      const batch = this.nextBatch(sent);
      if (batch.length === 0) return pushed;
      for (const item of batch) sent.add(`${item.pending.entity}:${item.pending.id}`);
      const response = await this.pushBatch(batch.map((item) => item.change));
      if (response.results.length !== batch.length) throw new Error("risposta del server non valida");
      batch.forEach((item, i) => this.apply(response.results[i], item.pending));
      pushed += batch.length;
    }
  }

  /**
   * Un 400 (o un 413) sul lotto dice che almeno una voce è sbagliata, non quale: si riprova una per
   * una, così le voci buone passano e quella sbagliata resta parcheggiata come rifiutata.
   */
  private async pushBatch(changes: unknown[]): Promise<{ results: PushResult[] }> {
    try {
      return await this.transport.push({ device_id: this.deviceId, changes });
    } catch (error) {
      if (!(error instanceof HttpError) || (error.status !== 400 && error.status !== 413)) throw error;
      if (changes.length === 1) {
        const message = error.status === 413 ? "too_large" : "invalid";
        return { results: [{ status: "rejected", error: String(error.status), message }] };
      }
      const results: PushResult[] = [];
      for (const change of changes) results.push(...(await this.pushBatch([change])).results);
      return { results };
    }
  }

  /** Il prossimo push: al massimo batchSize voci e maxBatchBytes byte. */
  private nextBatch(sent: Set<string>) {
    const batch: { pending: PendingChange; change: unknown }[] = [];
    let bytes = 0;
    const queue = this.store.pending()
      .filter((p) => !p.rejection && !sent.has(`${p.entity}:${p.id}`))
      .sort((a, b) => PUSH_ORDER[a.entity] - PUSH_ORDER[b.entity] || a.revision - b.revision);
    for (const pending of queue) {
      if (batch.length === SyncClient.batchSize) break;
      const record = this.record(pending);
      if (!record) {
        this.store.removePending(pending.entity, pending.id);
        continue;
      }
      // Resta in outbox finché l'utente non cambia idea: non parte mai.
      if (this.isBlocked(pending)) continue;
      const change = { entity: pending.entity, base_version: pending.baseVersion, data: record };
      const size = new TextEncoder().encode(JSON.stringify(change)).length;
      // Una voce che da sola supera il limite non passerebbe mai dal Worker:
      // resta in outbox come rifiutata invece di bloccare tutta la sync.
      if (size > SyncClient.maxBatchBytes) {
        this.store.savePending({ ...pending, rejection: "troppo grande per la sincronizzazione" });
        continue;
      }
      // Troppo grande per questo push: resta per il prossimo.
      if (bytes + size > SyncClient.maxBatchBytes) break;
      bytes += size;
      batch.push({ pending, change });
    }
    return batch;
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
    if (snapshot.entity === "node") this.retryDependents(snapshot.id);
  }

  /** Archi e pagine rifiutati perché il nodo mancava sul server ripartono quando il nodo arriva. */
  private retryDependents(nodeId: string) {
    for (const pending of this.store.pending()) {
      if (!pending.rejection) continue;
      let dependent = false;
      if (pending.entity === "edge") {
        const edge = this.store.edge(pending.id);
        dependent = !!edge && (edge.source_id === nodeId || edge.target_id === nodeId);
      } else if (pending.entity === "ink_page") {
        dependent = this.store.extra("ink_page", pending.id)?.node_id === nodeId;
      }
      if (dependent) this.store.savePending({ ...pending, rejection: undefined });
    }
  }

  private save(entity: Entity, record: SyncRecord) {
    if (entity === "node") this.store.saveNode(record as NodeRecord);
    else if (entity === "edge") this.store.saveEdge(record as EdgeRecord);
    else this.store.saveExtra("ink_page", record as InkPageRecord);
  }

  private async pullAll(): Promise<number> {
    let pulled = 0;
    // Nodi di salute scartati: anche i loro archi, arrivati prima o dopo nella stessa sync.
    const health = new Set<string>();
    try {
      for (;;) {
        const page = await this.transport.pull({ cursor: this.store.cursor(), limit: 500 });
        // Un'epoca nuova (il server è stato ripristinato da un backup): i cursori non valgono più.
        // Si riparte da zero; la pagina arrivata con il vecchio cursore si scarta.
        if (page.epoch !== undefined && page.epoch !== this.store.epoch()) {
          const known = this.store.epoch() !== 0;
          this.store.setEpoch(page.epoch);
          if (known) {
            this.store.setCursor(0);
            continue;
          }
        }
        for (const change of page.changes) {
          this.incoming(change.entity, change.data, health);
          pulled += 1;
        }
        // Mai all'indietro: una risposta con un cursore più basso non deve far rileggere tutto.
        this.store.setCursor(Math.max(this.store.cursor(), page.cursor));
        // Una pagina vuota chiude il giro anche se il server dice che ce ne sono altre: niente giri infiniti.
        if (!page.has_more || page.changes.length === 0) return pulled;
      }
    } finally {
      for (const edge of this.store.edges()) {
        if (health.has(edge.source_id) || health.has(edge.target_id)) {
          this.store.removePending("edge", edge.id);
          this.store.remove("edge", edge.id);
        }
      }
      for (const page of this.store.extras("ink_page")) {
        if (page.node_id && health.has(page.node_id)) {
          this.store.removePending("ink_page", page.id);
          this.store.remove("ink_page", page.id);
        }
      }
    }
  }

  private incoming(entity: string, data: unknown, health: Set<string>) {
    // Un record senza id valido non entra: mai chiavi come `__proto__` nell'archivio.
    if (!isSafeId((data as { id?: unknown } | null)?.id)) return;
    switch (entity) {
      case "node": {
        const node = data as NodeRecord;
        // Il server non li ha, ma per sicurezza i dati di salute non entrano mai nella PWA.
        if ((node.type as string) === "health" || (node.area as string) === "salute") {
          health.add(node.id);
          this.removeNode(node.id);
          return;
        }
        if (this.store.pendingChange(entity, node.id)) return;
        // Una versione più vecchia di quella che si ha già non la sostituisce.
        if ((this.store.node(node.id)?.version ?? 0) > node.version) return;
        this.save(entity, node);
        return;
      }
      case "edge": {
        const edge = data as EdgeRecord;
        if (health.has(edge.source_id) || health.has(edge.target_id)) return;
        if (this.store.pendingChange(entity, edge.id)) return;
        if ((this.store.edge(edge.id)?.version ?? 0) > edge.version) return;
        this.save(entity, edge);
        return;
      }
      case "ink_page": {
        const page = data as InkPageRecord;
        if (health.has(page.node_id)) return;
        if (this.store.pendingChange(entity, page.id)) return;
        if (((this.store.extra("ink_page", page.id) as InkPageRecord | undefined)?.version ?? 0) > page.version) return;
        this.save(entity, page);
        return;
      }
      case "attachment":
        this.store.saveExtra(entity, data as ExtraRecord);
        return;
      case "purged": {
        const { entity: kind, id } = data as { entity: string; id: string };
        if (kind === "node") {
          // Un nodo tenuto solo in locale è stato tolto dal server apposta: qui resta.
          if (this.blocked(id) && this.store.node(id)) this.forget(id);
          // Anche gli archi solo locali verso il nodo seguono il nodo, come sull'iPad.
          else this.removeNode(id);
        } else if (kind === "edge" || kind === "ink_page") {
          const edge = kind === "edge" ? this.store.edge(id) : undefined;
          const anchors = kind === "edge" ? [edge?.source_id, edge?.target_id] : [this.store.extra("ink_page", id)?.node_id];
          if (!anchors.some((nodeId) => nodeId && this.blocked(nodeId))) {
            this.store.removePending(kind, id);
            this.store.remove(kind, id);
          }
        } else if (kind === "attachment") {
          this.removeAttachment(id);
        }
        return;
      }
      default:
        // Versioni dei nodi ed entità future: non servono alla PWA.
        return;
    }
  }
}
