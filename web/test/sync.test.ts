import { describe, expect, it } from "vitest";
import { titleKey, wikiTargets } from "../src/model";
import { Repository } from "../src/repository";
import { MemoryStore } from "../src/store";
import { type PushResult, SyncClient, type Transport } from "../src/sync";

/** Server finto: versioni, cursore, rifiuta i nodi di salute come il database. */
class FakeServer implements Transport {
  rows: { entity: string; data: Record<string, unknown>; seq: number }[] = [];
  seq = 0;
  online = true;

  async push(body: { device_id: string; changes: unknown[] }): Promise<{ results: PushResult[] }> {
    if (!this.online) throw new Error("offline");
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

describe("link", () => {
  it("riconosce i [[link]] fuori dal codice", () => {
    expect(wikiTargets("[[A]] [[B|testo]] [[C#sez]] `[[D]]`\n```\n[[E]]\n```\n[[a]]")).toEqual(["A", "B", "C"]);
    expect(titleKey("  Perché   Così ")).toBe("perche cosi");
  });
});
