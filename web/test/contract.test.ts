// Il contratto condiviso (../contract): gli stessi esempi che leggono l'iPad e il Worker.
import { describe, expect, it } from "vitest";
import pullFixture from "../../contract/fixtures/pull-response.json";
import pushRequest from "../../contract/fixtures/push-request.json";
import pushResponse from "../../contract/fixtures/push-response.json";
import { Repository } from "../src/repository";
import { MemoryStore } from "../src/store";
import { type PullPage, type PushResult, SyncClient, type Transport } from "../src/sync";

describe("contratto con il server", () => {
  it("la PWA legge la risposta di pull di esempio: entità note applicate, sconosciute ignorate", async () => {
    const store = new MemoryStore();
    const transport: Transport = {
      push: async () => ({ results: [] }),
      pull: async () => structuredClone(pullFixture) as unknown as PullPage,
    };
    const client = new SyncClient(store, transport, "pc-test");
    await client.sync();
    expect(store.node("10000000-0000-4000-8000-000000000001")).toMatchObject({ title: "Derivata", version: 3, tags: ["analisi"] });
    expect(store.edge("10000000-0000-4000-8000-0000000000e1")).toMatchObject({ kind: "link", label: null });
    expect(store.extra("ink_page", "10000000-0000-4000-8000-0000000000a1")).toMatchObject({ background: "blank", ink_data: "QUJDRA==" });
    expect(store.extra("attachment", "10000000-0000-4000-8000-0000000000b1")).toMatchObject({ file_name: "Analisi.pdf", part_count: 3 });
    expect(store.cursor()).toBe(56);
    expect(store.epoch()).toBe(1);
  });

  it("le voci rifiutate dell'esempio di push restano parcheggiate con il codice del server, le altre si applicano", async () => {
    const store = new MemoryStore();
    const repo = new Repository(store, "pc-test");
    const node = repo.createNode({ title: "Derivata" });
    const other = repo.createNode({ title: "Integrale" });
    const edge = repo.createEdge(node.id, other.id, "manual");
    const results = (pushResponse.results as unknown as PushResult[]).map((r) => structuredClone(r));
    // Gli id dell'esempio sono quelli del server: si riallineano alle voci locali, nello stesso ordine.
    const sent: string[] = [];
    const transport: Transport = {
      push: async (body) => {
        const changes = body.changes as { entity: string; data: { id: string } }[];
        sent.push(...changes.map((c) => c.entity));
        return {
          results: changes.map((change) => {
            const found = results.find((r) => r.entity === change.entity) ?? { status: "rejected" as const, message: "invalid" };
            return { ...found, id: change.data.id, record: found.record ? { ...found.record, id: change.data.id } : undefined } as PushResult;
          }),
        };
      },
      pull: async () => ({ changes: [], cursor: 0, has_more: false }),
    };
    const client = new SyncClient(store, transport, "pc-test");
    await client.sync();
    expect(sent).toEqual(["node", "node", "edge"]);
    expect(store.pendingChange("edge", edge.id)?.rejection).toBe("missing_parent");
    expect(client.rejections.map((r) => r.id)).toEqual([edge.id]);
  });

  it("le richieste della PWA hanno le chiavi dell'esempio di push", () => {
    const store = new MemoryStore();
    const repo = new Repository(store, "pc-test");
    const node = repo.createNode({ title: "Derivata", tags: ["a"] });
    const edge = repo.createEdge(node.id, node.id, "manual");
    const page = repo.createInkPage(node.id);
    const sample = (entity: string) => Object.keys((pushRequest.changes.find((c) => c.entity === entity) as { data: object }).data);
    for (const key of sample("node")) expect(node, `node.${key}`).toHaveProperty(key);
    for (const key of sample("edge")) expect(edge, `edge.${key}`).toHaveProperty(key);
    for (const key of sample("ink_page")) expect(page, `ink_page.${key}`).toHaveProperty(key);
  });
});
