import { afterEach, describe, expect, it, vi } from "vitest";
import { Repository } from "../src/repository";
import { MemoryStore } from "../src/store";
import { API_VERSION, AuthError, HttpError, HttpTransport, OutdatedError, type PullPage, type PushResult, SyncClient, type Transport } from "../src/sync";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

const node = (id: string, version: number, extra: Record<string, unknown> = {}) => ({
  id, type: "concept", title: id, body_md: "", area: "studio", tags: [], version,
  created_at: "2026-10-01T00:00:00Z", updated_at: "2026-10-01T00:00:00Z", deleted_at: null, device_id: "x", ...extra,
});

/** Transport con pagine a copione. */
function scripted(pages: PullPage[], push: Transport["push"] = async () => ({ results: [] })) {
  const requests: number[] = [];
  let index = 0;
  const transport: Transport = {
    push,
    pull: async (body) => {
      requests.push(body.cursor);
      return pages[Math.min(index++, pages.length - 1)];
    },
  };
  return { transport, requests };
}

describe("pull", () => {
  it("una versione più vecchia di quella locale non la sostituisce", async () => {
    const store = new MemoryStore();
    store.saveNode(node("a", 5, { title: "locale" }) as never);
    const { transport } = scripted([{ changes: [{ entity: "node", data: node("a", 3, { title: "vecchia" }) }], cursor: 10, has_more: false }]);
    await new SyncClient(store, transport, "pc").sync();
    expect(store.node("a")?.title).toBe("locale");
    const newer = scripted([{ changes: [{ entity: "node", data: node("a", 6, { title: "nuova" }) }], cursor: 11, has_more: false }]);
    await new SyncClient(store, newer.transport, "pc").sync();
    expect(store.node("a")?.title).toBe("nuova");
  });

  it("il cursore non torna mai indietro", async () => {
    const store = new MemoryStore();
    store.setCursor(100);
    const { transport } = scripted([{ changes: [{ entity: "node", data: node("a", 1) }], cursor: 7, has_more: false }]);
    await new SyncClient(store, transport, "pc").sync();
    expect(store.cursor()).toBe(100);
  });

  it("una pagina vuota chiude il giro anche se il server dice che ce ne sono altre", async () => {
    const store = new MemoryStore();
    const { transport, requests } = scripted([{ changes: [], cursor: 0, has_more: true }]);
    await new SyncClient(store, transport, "pc").sync();
    expect(requests).toEqual([0]);
  });

  it("un'epoca nuova fa ripartire dal cursore 0, la prima volta si limita a ricordarla", async () => {
    const store = new MemoryStore();
    store.setCursor(40);
    const first = scripted([{ changes: [], cursor: 40, has_more: false, epoch: 1 }]);
    await new SyncClient(store, first.transport, "pc").sync();
    expect(store.epoch()).toBe(1);
    expect(first.requests).toEqual([40]);

    const restored = scripted([
      { changes: [{ entity: "node", data: node("x", 1) }], cursor: 30, has_more: false, epoch: 2 },
      { changes: [{ entity: "node", data: node("a", 1) }], cursor: 12, has_more: false, epoch: 2 },
    ]);
    await new SyncClient(store, restored.transport, "pc").sync();
    expect(store.epoch()).toBe(2);
    expect(restored.requests).toEqual([40, 0]);
    // La pagina arrivata con il cursore vecchio si scarta: dopo il ripristino conta solo la ripartenza.
    expect(store.node("x")).toBeUndefined();
    expect(store.node("a")).toBeDefined();
    expect(store.cursor()).toBe(12);
  });

  it("l'eliminazione definitiva di un nodo porta via i suoi allegati e le annotazioni dei PDF", async () => {
    const store = new MemoryStore();
    store.saveNode(node("n", 1) as never);
    store.saveExtra("attachment", { id: "att", node_id: "n", deleted_at: null });
    store.saveExtra("ink_page", { id: "p1", node_id: "n", deleted_at: null, attachment_id: "att" } as never);
    store.saveExtra("ink_page", { id: "p2", node_id: "other", deleted_at: null, attachment_id: "att" } as never);
    store.saveExtra("ink_page", { id: "p3", node_id: "other", deleted_at: null, attachment_id: null } as never);
    const { transport } = scripted([{ changes: [{ entity: "purged", data: { entity: "node", id: "n" } }], cursor: 5, has_more: false }]);
    await new SyncClient(store, transport, "pc").sync();
    expect(store.node("n")).toBeUndefined();
    expect(store.extra("attachment", "att")).toBeUndefined();
    expect(store.extra("ink_page", "p1")).toBeUndefined();
    expect(store.extra("ink_page", "p2")).toBeUndefined();
    expect(store.extra("ink_page", "p3")).toBeDefined();
  });

  it("l'eliminazione definitiva di un allegato porta via le annotazioni dei suoi PDF", async () => {
    const store = new MemoryStore();
    store.saveExtra("attachment", { id: "att", node_id: null, deleted_at: null });
    store.saveExtra("ink_page", { id: "p", node_id: "n", deleted_at: null, attachment_id: "att" } as never);
    const { transport } = scripted([{ changes: [{ entity: "purged", data: { entity: "attachment", id: "att" } }], cursor: 5, has_more: false }]);
    await new SyncClient(store, transport, "pc").sync();
    expect(store.extra("attachment", "att")).toBeUndefined();
    expect(store.extra("ink_page", "p")).toBeUndefined();
  });
});

describe("push", () => {
  function twoNodes() {
    const store = new MemoryStore();
    const repo = new Repository(store, "pc");
    return { store, repo, a: repo.createNode({ title: "A" }), b: repo.createNode({ title: "B" }), c: repo.createNode({ title: "C" }) };
  }

  it("un 400 sul lotto: si riprova una voce alla volta, la sbagliata resta parcheggiata e le altre passano", async () => {
    const { store, b } = twoNodes();
    const sizes: number[] = [];
    const push: Transport["push"] = async (body) => {
      const changes = body.changes as { data: { id: string; title: string } }[];
      sizes.push(changes.length);
      if (changes.length > 1 || changes[0].data.id === b.id) throw new HttpError(400);
      return { results: [{ entity: "node", id: changes[0].data.id, status: "created", record: { ...changes[0].data, version: 1 } } as unknown as PushResult] };
    };
    const { transport } = scripted([{ changes: [], cursor: 0, has_more: false }], push);
    const client = new SyncClient(store, transport, "pc");
    await client.sync();
    expect(sizes).toEqual([3, 1, 1, 1]);
    expect(client.rejections.map((r) => r.id)).toEqual([b.id]);
    expect(store.pendingChange("node", b.id)?.rejection).toBe("invalid");
    expect(store.pending().filter((p) => !p.rejection)).toHaveLength(0);
    expect(store.node(b.id)?.title).toBe("B");
  });

  it("un 413 su una sola voce la parcheggia come troppo grande", async () => {
    const store = new MemoryStore();
    const repo = new Repository(store, "pc");
    const only = repo.createNode({ title: "Enorme" });
    const { transport } = scripted([{ changes: [], cursor: 0, has_more: false }], async () => { throw new HttpError(413); });
    await new SyncClient(store, transport, "pc").sync();
    expect(store.pendingChange("node", only.id)?.rejection).toBe("too_large");
  });

  it("gli altri errori non si rimbalzano voce per voce", async () => {
    const { store } = twoNodes();
    const push = vi.fn(async () => { throw new HttpError(500); });
    const { transport } = scripted([{ changes: [], cursor: 0, has_more: false }], push);
    await expect(new SyncClient(store, transport, "pc").sync()).rejects.toThrow("HTTP 500");
    expect(push).toHaveBeenCalledTimes(1);
    expect(store.pending()).toHaveLength(3);
  });
});

describe("salvataggio", () => {
  it("se anche il salvataggio fallisce, l'errore che si vede è quello della sync", async () => {
    const store = new MemoryStore();
    vi.spyOn(store, "flush").mockRejectedValue(new Error("disco pieno"));
    const transport: Transport = { push: async () => ({ results: [] }), pull: async () => { throw new Error("rete assente"); } };
    await expect(new SyncClient(store, transport, "pc").sync()).rejects.toThrow("rete assente");
  });

  it("se la sync riesce ma il salvataggio no, si vede l'errore del salvataggio", async () => {
    const store = new MemoryStore();
    vi.spyOn(store, "flush").mockRejectedValue(new Error("disco pieno"));
    const transport: Transport = { push: async () => ({ results: [] }), pull: async () => ({ changes: [], cursor: 0, has_more: false }) };
    await expect(new SyncClient(store, transport, "pc").sync()).rejects.toThrow("disco pieno");
  });
});

describe("trasporto HTTP", () => {
  it("manda la versione dell'API, ha un timeout e distingue gli errori", async () => {
    const calls: { headers: Record<string, string>; signal?: AbortSignal | null }[] = [];
    const respond = (status: number, body: unknown = {}) => vi.fn(async (_url: string, init?: RequestInit) => {
      calls.push({ headers: init?.headers as Record<string, string>, signal: init?.signal });
      return new Response(JSON.stringify(body), { status });
    });
    vi.stubGlobal("fetch", respond(200, { changes: [], cursor: 0, has_more: false }));
    await new HttpTransport().pull({ cursor: 0, limit: 10 });
    expect(calls[0].headers["x-pitchstone-api"]).toBe(String(API_VERSION));
    expect(calls[0].headers["content-type"]).toBe("application/json");
    expect(calls[0].signal).toBeInstanceOf(AbortSignal);
    vi.stubGlobal("fetch", respond(426));
    await expect(new HttpTransport().pull({ cursor: 0, limit: 10 })).rejects.toBeInstanceOf(OutdatedError);
    vi.stubGlobal("fetch", respond(403));
    await expect(new HttpTransport().pull({ cursor: 0, limit: 10 })).rejects.toBeInstanceOf(AuthError);
    vi.stubGlobal("fetch", respond(400));
    await expect(new HttpTransport().push({ device_id: "x", changes: [] })).rejects.toMatchObject({ status: 400 });
  });
});
