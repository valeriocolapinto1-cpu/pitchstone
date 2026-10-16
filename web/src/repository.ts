import { type Area, type EdgeRecord, type Entity, type NodeRecord, type NodeType, titleKey, wikiTargets } from "./model";
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
