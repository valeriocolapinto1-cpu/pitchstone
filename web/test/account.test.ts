import { describe, expect, it, vi } from "vitest";
import { clearLocal, ERASE_CONFIRMATION, eraseServer, exportEverything } from "../src/account";
import { MemoryStore } from "../src/store";
import { AuthError } from "../src/sync";

describe("esportazione completa", () => {
  it("raccoglie tutte le pagine di tutte le tabelle", async () => {
    const calls: { table: string; after: string | null }[] = [];
    const fetchFn = vi.fn(async (_input: string, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body)) as { table: string; after: string | null };
      calls.push(body);
      if (body.table === "nodes" && body.after === null) return Response.json({ rows: [{ id: "a" }, { id: "b" }], last: "b", more: true });
      if (body.table === "nodes") return Response.json({ rows: [{ id: "c" }], last: "c", more: false });
      return Response.json({ rows: body.table === "ink_pages" ? [{ id: "p", ink_data: "QUJD" }] : [], last: null, more: false });
    });
    const file = await exportEverything(fetchFn, () => new Date("2026-10-17T10:00:00Z"));
    expect(file).toMatchObject({ format: "pitchstone-export", version: 1, exported_at: "2026-10-17T10:00:00.000Z" });
    expect(file.tables.nodes.map((r) => r.id)).toEqual(["a", "b", "c"]);
    expect(file.tables.ink_pages[0].ink_data).toBe("QUJD");
    expect(Object.keys(file.tables)).toEqual(["nodes", "edges", "node_versions", "attachments", "ink_pages", "purged"]);
    expect(calls.filter((c) => c.table === "nodes").map((c) => c.after)).toEqual([null, "b"]);
  });

  it("un login scaduto è un AuthError, non un file vuoto", async () => {
    await expect(exportEverything(async () => new Response("", { status: 401 }))).rejects.toBeInstanceOf(AuthError);
    await expect(exportEverything(async () => new Response("", { status: 500 }))).rejects.toThrow("HTTP 500");
  });
});

describe("cancellazione", () => {
  it("dal server manda la parola d'ordine e riporta l'esito", async () => {
    const fetchFn = vi.fn(async (_input: string, init?: RequestInit) => {
      expect(JSON.parse(String(init?.body))).toEqual({ confirm: ERASE_CONFIRMATION });
      return Response.json({ database: true, nodes: 3, epoch: 2, storage: true });
    });
    expect(await eraseServer(fetchFn)).toEqual({ database: true, nodes: 3, epoch: 2, storage: true });
    expect(fetchFn.mock.calls[0][0]).toBe("/account/erase");
  });

  it("dal computer: archivio, preferenze, cache e service worker", async () => {
    const store = new MemoryStore();
    store.saveNode({ id: "a", tags: [] } as never);
    const cleared: string[] = [];
    const deleted: string[] = [];
    const unregistered: string[] = [];
    await clearLocal(store, {
      storage: { clear: () => void cleared.push("local") },
      caches: { keys: async () => ["v1", "v2"], delete: async (key: string) => (deleted.push(key), true) },
      registrations: async () => [{ unregister: async () => (unregistered.push("sw"), true) }],
    });
    expect(store.nodes()).toEqual([]);
    expect(cleared).toEqual(["local"]);
    expect(deleted).toEqual(["v1", "v2"]);
    expect(unregistered).toEqual(["sw"]);
  });

  it("anche se la cache non si cancella, l'archivio sì", async () => {
    const store = new MemoryStore();
    store.saveNode({ id: "a", tags: [] } as never);
    await clearLocal(store, {
      storage: { clear: () => { throw new Error("bloccato"); } },
      caches: { keys: async () => { throw new Error("no"); }, delete: async () => true },
    });
    expect(store.nodes()).toEqual([]);
  });
});
