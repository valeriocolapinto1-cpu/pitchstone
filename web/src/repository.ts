import {
  type Area, type EdgeRecord, type Entity, type InkBackground, type InkPageRecord, type NodeRecord, type NodeType, titleKey, wikiTargets,
} from "./model";
import type { Store } from "./store";

/** Modifiche locali: salva nell'archivio e mette in outbox, come il Repository dell'iPad. */
export class Repository {
  private revision = Date.now();

  constructor(
    private store: Store,
    readonly deviceId: string,
    private now: () => Date = () => new Date(),
  ) {}

  private enqueue(entity: Entity, id: string, version: number) {
    const existing = this.store.pendingChange(entity, id);
    this.revision += 1;
    this.store.savePending({
      entity,
      id,
      // La base resta quella della prima modifica non inviata.
      baseVersion: existing ? existing.baseVersion : version === 0 ? null : version,
      revision: this.revision,
    });
  }

  createNode(fields: { type?: NodeType; title: string; body?: string; area?: Area; tags?: string[] }): NodeRecord {
    const date = this.now().toISOString();
    const node: NodeRecord = {
      id: crypto.randomUUID(),
      type: fields.type ?? "concept",
      title: fields.title,
      body_md: fields.body ?? "",
      area: fields.area ?? "studio",
      tags: fields.tags ?? [],
      version: 0,
      created_at: date,
      updated_at: date,
      deleted_at: null,
      device_id: this.deviceId,
    };
    this.store.saveNode(node);
    this.enqueue("node", node.id, 0);
    this.syncLinks(node.id);
    this.resyncMentions(node.title);
    return node;
  }

  updateNode(id: string, change: Partial<Pick<NodeRecord, "type" | "title" | "body_md" | "area" | "tags" | "deleted_at">>): NodeRecord {
    const old = this.store.node(id);
    if (!old) throw new Error("nodo non trovato");
    const node: NodeRecord = { ...old, ...change, updated_at: this.now().toISOString(), device_id: this.deviceId };
    this.store.saveNode(node);
    this.enqueue("node", id, old.version);
    if (node.body_md !== old.body_md) this.syncLinks(id);
    if (node.title !== old.title) {
      this.resyncMentions(old.title);
      this.resyncMentions(node.title);
    }
    return node;
  }

  trashNode(id: string) { this.updateNode(id, { deleted_at: this.now().toISOString() }); }
  restoreNode(id: string) { this.updateNode(id, { deleted_at: null }); }

  createEdge(source: string, target: string, kind: EdgeRecord["kind"]): EdgeRecord {
    const edge: EdgeRecord = {
      id: crypto.randomUUID(), source_id: source, target_id: target, kind, label: null, version: 0,
      created_at: this.now().toISOString(), deleted_at: null,
    };
    this.store.saveEdge(edge);
    this.enqueue("edge", edge.id, 0);
    return edge;
  }

  private setEdgeDeleted(edge: EdgeRecord, deleted: boolean) {
    this.store.saveEdge({ ...edge, deleted_at: deleted ? this.now().toISOString() : null });
    this.enqueue("edge", edge.id, edge.version);
  }

  inkPage(id: string): InkPageRecord | undefined {
    return this.store.extra("ink_page", id) as InkPageRecord | undefined;
  }

  /** Pagine a penna del nodo (non le annotazioni sui PDF), in ordine. */
  inkPages(nodeId: string, trashed = false): InkPageRecord[] {
    return (this.store.extras("ink_page") as InkPageRecord[])
      .filter((p) => p.node_id === nodeId && !p.attachment_id && !!p.deleted_at === trashed)
      .sort((a, b) => a.page_no - b.page_no || a.created_at.localeCompare(b.created_at));
  }

  /**
   * Nuova pagina in fondo al nodo. Solo per i nodi dell'archivio del PC, che non ha
   * dati di salute: una pagina di un nodo di salute non può nascere qui.
   */
  createInkPage(nodeId: string, background: InkBackground = "blank"): InkPageRecord {
    const node = this.store.node(nodeId);
    if (!node || (node.type as string) === "health" || (node.area as string) === "salute") throw new Error("nodo non disponibile");
    const all = (this.store.extras("ink_page") as InkPageRecord[]).filter((p) => p.node_id === nodeId);
    const date = this.now().toISOString();
    const page: InkPageRecord = {
      id: crypto.randomUUID(),
      node_id: nodeId,
      page_no: all.reduce((max, p) => Math.max(max, p.page_no), -1) + 1,
      background,
      ink_data: "",
      attachment_id: null,
      pdf_page: null,
      version: 0,
      created_at: date,
      updated_at: date,
      deleted_at: null,
      device_id: this.deviceId,
    };
    this.store.saveExtra("ink_page", page);
    this.enqueue("ink_page", page.id, 0);
    return page;
  }

  updateInkPage(id: string, change: Partial<Pick<InkPageRecord, "background" | "ink_data" | "deleted_at">>): InkPageRecord {
    const old = this.store.extra("ink_page", id) as InkPageRecord | undefined;
    if (!old) throw new Error("pagina non trovata");
    const page: InkPageRecord = { ...old, ...change, updated_at: this.now().toISOString(), device_id: this.deviceId };
    this.store.saveExtra("ink_page", page);
    this.enqueue("ink_page", id, old.version);
    return page;
  }

  /**
   * Salva il disegno partito dai byte `loadedFrom`. Se nel frattempo una sync ha cambiato la
   * pagina, i tratti vanno in una nuova pagina invece di sovrascriverla (come sull'iPad).
   */
  saveDrawing(id: string, inkData: string, loadedFrom: string): InkPageRecord {
    const current = this.store.extra("ink_page", id) as InkPageRecord | undefined;
    if (!current) throw new Error("pagina non trovata");
    if (current.ink_data === loadedFrom || current.ink_data === inkData) {
      return this.updateInkPage(id, { ink_data: inkData });
    }
    const copy = this.createInkPage(current.node_id, current.background);
    return this.updateInkPage(copy.id, { ink_data: inkData });
  }

  trashInkPage(id: string) { this.updateInkPage(id, { deleted_at: this.now().toISOString() }); }
  restoreInkPage(id: string) { this.updateInkPage(id, { deleted_at: null }); }

  /** Archi `link` allineati ai `[[...]]` del corpo, un solo arco attivo per destinazione. */
  syncLinks(id: string) {
    const node = this.store.node(id);
    if (!node) return;
    const index = new Map<string, string>();
    for (const n of this.store.nodes()) {
      if (!n.deleted_at && n.title && !index.has(titleKey(n.title))) index.set(titleKey(n.title), n.id);
    }
    const wanted = new Set(
      wikiTargets(node.body_md).map((t) => index.get(titleKey(t))).filter((t): t is string => !!t && t !== id),
    );
    const existing = new Map<string, EdgeRecord[]>();
    for (const edge of this.store.edges()) {
      if (edge.source_id === id && edge.kind === "link") {
        existing.set(edge.target_id, [...(existing.get(edge.target_id) ?? []), edge]);
      }
    }
    for (const target of wanted) {
      const edges = existing.get(target) ?? [];
      const active = edges.filter((e) => !e.deleted_at).sort((a, b) => a.created_at.localeCompare(b.created_at));
      if (active.length > 0) {
        for (const duplicate of active.slice(1)) this.setEdgeDeleted(duplicate, true);
      } else if (edges.length > 0) {
        this.setEdgeDeleted(edges[edges.length - 1], false);
      } else {
        this.createEdge(id, target, "link");
      }
    }
    for (const [target, edges] of existing) {
      if (!wanted.has(target)) for (const edge of edges) if (!edge.deleted_at) this.setEdgeDeleted(edge, true);
    }
  }

  /** Dopo una rinomina o un nodo nuovo: chi cita quel titolo riallinea i suoi archi. */
  private resyncMentions(title: string) {
    const key = titleKey(title);
    if (!key) return;
    for (const node of this.store.nodes()) {
      if (!node.deleted_at && node.body_md.includes("[[") && wikiTargets(node.body_md).some((t) => titleKey(t) === key)) {
        this.syncLinks(node.id);
      }
    }
  }
}
