import { afterEach, describe, expect, it, vi } from "vitest";
import { titleKey, wikiTargets } from "../src/model";
import { Repository } from "../src/repository";
import { MemoryStore } from "../src/store";
import { AuthError, HttpTransport, type PushResult, SyncClient, type Transport } from "../src/sync";

/** Server finto: versioni, cursore, rifiuta i nodi di salute come il database. */
class FakeServer implements Transport {
  rows: { entity: string; data: Record<string, unknown>; seq: number }[] = [];
  seq = 0;
  online = true;
  pushes: number[] = [];

  async push(body: { device_id: string; changes: unknown[] }): Promise<{ results: PushResult[] }> {
    if (!this.online) throw new Error("offline");
    this.pushes.push(new TextEncoder().encode(JSON.stringify(body.changes)).length);
    const results = (body.changes as { entity: string; base_version: number | null; data: Record<string, unknown> }[]).map((c) => {
      if (c.data.type === "health" || c.data.area === "salute") return { status: "rejected" as const, message: "salute" };
      const current = this.rows.filter((r) => r.entity === c.entity && r.data.id === c.data.id).at(-1);
      const version = ((current?.data.version as number) ?? 0) + 1;
      const record = { ...c.data, version };
      this.rows.push({ entity: c.entity, data: record, seq: ++this.seq });
      return { entity: c.entity, id: c.data.id as string, status: current ? ("updated" as const) : ("created" as const), record: record as never };
    });
    return { results };
  }

  async pull(body: { cursor: number; limit: number }) {
    if (!this.online) throw new Error("offline");
    const changes = this.rows.filter((r) => r.seq > body.cursor).slice(0, body.limit);
    return {
      changes: changes.map((r) => ({ entity: r.entity, data: r.data })),
      cursor: changes.at(-1)?.seq ?? body.cursor,
      has_more: this.rows.filter((r) => r.seq > body.cursor).length > body.limit,
    };
  }
}

function device(server: FakeServer, name: string) {
  const store = new MemoryStore();
  return { store, repo: new Repository(store, name), sync: new SyncClient(store, server, name) };
}

describe("sync della PWA", () => {
  it("un nodo scritto sul PC compare sull'altro dispositivo, con i suoi link", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    const other = device(server, "ipad");
    const limits = pc.repo.createNode({ title: "Limiti" });
    const derivative = pc.repo.createNode({ title: "Derivata", body: "È il [[limiti|limite]] del rapporto." });
    expect(pc.store.edges()).toHaveLength(1);
    expect(await pc.sync.sync()).toEqual({ pushed: 3, pulled: 3 });
    expect(pc.store.pending()).toHaveLength(0);
    expect(pc.store.node(derivative.id)?.version).toBe(1);

    await other.sync.sync();
    expect(other.store.node(derivative.id)?.body_md).toContain("[[limiti|limite]]");
    expect(other.store.edges()[0]).toMatchObject({ source_id: derivative.id, target_id: limits.id, kind: "link" });
  });

  it("offline le modifiche restano in outbox e partono dopo", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    const node = pc.repo.createNode({ title: "Bozza" });
    server.online = false;
    await expect(pc.sync.sync()).rejects.toThrow();
    pc.repo.updateNode(node.id, { body_md: "scritto offline" });
    expect(pc.store.pending()).toHaveLength(1);
    server.online = true;
    await pc.sync.sync();
    expect(server.rows.at(-1)?.data.body_md).toBe("scritto offline");
  });

  it("un pull non sovrascrive una modifica locale non inviata", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    const other = device(server, "ipad");
    const node = pc.repo.createNode({ title: "Nota" });
    await pc.sync.sync();
    await other.sync.sync();
    other.repo.updateNode(node.id, { body_md: "dall'iPad" });
    await other.sync.sync();
    pc.repo.updateNode(node.id, { body_md: "dal PC" });
    // Solo il pull: la modifica del PC resta.
    await (pc.sync as unknown as { pullAll(): Promise<number> }).pullAll();
    expect(pc.store.node(node.id)?.body_md).toBe("dal PC");
    expect(pc.store.pendingChange("node", node.id)?.baseVersion).toBe(1);
  });

  it("le voci rifiutate restano parcheggiate senza bloccare le altre", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    const bad = pc.repo.createNode({ title: "x" });
    pc.store.saveNode({ ...pc.store.node(bad.id)!, area: "salute" as never });
    const good = pc.repo.createNode({ title: "y" });
    await pc.sync.sync();
    expect(pc.sync.rejections.map((p) => p.id)).toEqual([bad.id]);
    expect(pc.store.node(good.id)?.version).toBe(1);
  });

  it("il cestino e la rinomina riallineano i link", () => {
    const pc = device(new FakeServer(), "pc");
    const a = pc.repo.createNode({ title: "A", body: "vedi [[B]]" });
    expect(pc.store.edges()).toHaveLength(0);
    const b = pc.repo.createNode({ title: "B" });
    expect(pc.store.edges().filter((e) => !e.deleted_at)).toHaveLength(1);
    pc.repo.updateNode(b.id, { title: "C" });
    expect(pc.store.edges().filter((e) => !e.deleted_at)).toHaveLength(0);
    pc.repo.updateNode(a.id, { body_md: "vedi [[c]]" });
    expect(pc.store.edges().filter((e) => !e.deleted_at)).toHaveLength(1);
  });
});

describe("revisione della sync", () => {
  it("divide il push sotto il limite di byte e rifiuta in locale una voce troppo grande", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    const text = "x".repeat(1_000_000);
    for (let i = 0; i < 5; i++) pc.repo.createNode({ title: `N${i}`, body: text });
    const huge = pc.repo.createNode({ title: "Enorme", body: "y".repeat(SyncClient.maxBatchBytes) });
    expect(await pc.sync.sync()).toEqual({ pushed: 5, pulled: 5 });
    expect(server.pushes.length).toBe(2);
    for (const bytes of server.pushes) expect(bytes).toBeLessThanOrEqual(SyncClient.maxBatchBytes);
    expect(pc.sync.rejections).toMatchObject([{ id: huge.id, rejection: "troppo grande per la sincronizzazione" }]);
  });

  it("un nodo accettato fa ripartire gli archi rifiutati che dipendono da lui", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    pc.repo.createNode({ title: "A" });
    const b = pc.repo.createNode({ title: "B", body: "[[A]]" });
    const [edge] = pc.store.edges();
    pc.store.savePending({ ...pc.store.pendingChange("edge", edge.id)!, rejection: "nodo mancante" });
    await pc.sync.sync();
    expect(pc.sync.rejections).toHaveLength(0);
    expect(pc.store.edge(edge.id)?.version).toBe(1);
    expect(server.rows.some((r) => r.entity === "edge" && r.data.source_id === b.id)).toBe(true);
  });

  it("Scarta toglie un record mai arrivato al server, con i suoi archi", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    const a = pc.repo.createNode({ title: "A" });
    pc.repo.createNode({ title: "B", body: "[[A]]" });
    pc.store.savePending({ ...pc.store.pendingChange("node", a.id)!, rejection: "no" });
    pc.sync.discard("node", a.id);
    expect(pc.store.node(a.id)).toBeUndefined();
    expect(pc.store.edges()).toHaveLength(0);
    expect(pc.store.pending().map((p) => p.entity)).toEqual(["node"]);
  });

  it("Scarta riporta la versione del server, Riprova rimanda la modifica", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    const node = pc.repo.createNode({ title: "Nota", body: "server" });
    await pc.sync.sync();
    pc.repo.updateNode(node.id, { body_md: "locale" });
    pc.store.savePending({ ...pc.store.pendingChange("node", node.id)!, rejection: "conflitto" });
    pc.sync.retry("node", node.id);
    expect(pc.sync.rejections).toHaveLength(0);
    pc.store.savePending({ ...pc.store.pendingChange("node", node.id)!, rejection: "conflitto" });
    pc.sync.discard("node", node.id);
    await pc.sync.sync();
    expect(pc.store.node(node.id)?.body_md).toBe("server");
    expect(pc.store.pending()).toHaveLength(0);
  });

  it("un nodo eliminato per sempre porta via archi e voci in outbox", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    const a = pc.repo.createNode({ title: "A" });
    await pc.sync.sync();
    pc.repo.createNode({ title: "B", body: "[[A]]" });
    server.rows.push({ entity: "purged", data: { entity: "node", id: a.id }, seq: ++server.seq });
    await (pc.sync as unknown as { pullAll(): Promise<number> }).pullAll();
    expect(pc.store.node(a.id)).toBeUndefined();
    expect(pc.store.edges()).toHaveLength(0);
    expect(pc.store.pending().map((p) => p.entity)).toEqual(["node"]);
  });

  it("scarta i nodi di salute in arrivo e i loro archi", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    const ok = { id: "ok", type: "concept", area: "studio", title: "Ok", version: 1 };
    const edge = (id: string, target: string) => ({ id, source_id: "ok", target_id: target, kind: "link", version: 1 });
    server.rows.push(
      { entity: "node", data: ok, seq: ++server.seq },
      { entity: "edge", data: edge("e1", "h1"), seq: ++server.seq },
      { entity: "node", data: { ...ok, id: "h1", type: "health" }, seq: ++server.seq },
      { entity: "node", data: { ...ok, id: "h2", area: "salute" }, seq: ++server.seq },
      { entity: "edge", data: edge("e2", "h2"), seq: ++server.seq },
    );
    await pc.sync.sync();
    expect(pc.store.nodes().map((n) => n.id)).toEqual(["ok"]);
    expect(pc.store.edges()).toHaveLength(0);
  });

  it("scrive su disco anche quando la sync fallisce", async () => {
    const server = new FakeServer();
    const store = new MemoryStore();
    const flush = vi.spyOn(store, "flush");
    const sync = new SyncClient(store, server, "pc");
    server.online = false;
    await expect(sync.sync()).rejects.toThrow();
    expect(flush).toHaveBeenCalledTimes(1);
  });
});

describe("trasporto HTTP", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("manda JSON e riconosce il login scaduto", async () => {
    const fetch = vi.fn<typeof globalThis.fetch>(async () => new Response(null, { status: 401 }));
    vi.stubGlobal("fetch", fetch);
    await expect(new HttpTransport().pull({ cursor: 0, limit: 1 })).rejects.toBeInstanceOf(AuthError);
    expect(new Headers(fetch.mock.calls[0][1]?.headers).get("content-type")).toBe("application/json");
    fetch.mockResolvedValueOnce(new Response(null, { status: 500 }));
    await expect(new HttpTransport().pull({ cursor: 0, limit: 1 })).rejects.not.toBeInstanceOf(AuthError);
  });
});

describe("link", () => {
  it("riconosce i [[link]] fuori dal codice", () => {
    expect(wikiTargets("[[A]] [[B|testo]] [[C#sez]] `[[D]]`\n```\n[[E]]\n```\n[[a]]")).toEqual(["A", "B", "C"]);
    expect(titleKey("  Perché   Così ")).toBe("perche cosi");
  });
});
