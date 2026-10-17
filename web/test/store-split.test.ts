import { afterEach, describe, expect, it, vi } from "vitest";
import { IndexedDBStore } from "../src/store";

/** IndexedDB minimale: un solo object store "state", transazioni che si chiudono subito. */
function fakeIndexedDB(initial: Record<string, unknown> = {}) {
  const values = new Map<string, unknown>(Object.entries(initial));
  const puts: string[] = [];
  const db = {
    transaction() {
      const tx: { oncomplete?: () => void; objectStore: () => unknown } = {
        objectStore: () => ({
          get(key: string) {
            const request: { result?: unknown; onsuccess?: () => void } = {};
            queueMicrotask(() => { request.result = values.get(key); request.onsuccess?.(); });
            return request;
          },
          put(value: unknown, key: string) {
            puts.push(key);
            values.set(key, value);
          },
        }),
      };
      queueMicrotask(() => queueMicrotask(() => tx.oncomplete?.()));
      return tx;
    },
  };
  vi.stubGlobal("indexedDB", {
    open() {
      const request: { result: unknown; onsuccess?: () => void; onupgradeneeded?: () => void } = { result: db };
      queueMicrotask(() => request.onsuccess?.());
      return request;
    },
  });
  return { values, puts };
}

const node = { id: "n1", tags: [] } as never;
const ink = { id: "i1", node_id: "n1" } as never;

afterEach(() => vi.unstubAllGlobals());

describe("archivio locale diviso in nucleo ed extra", () => {
  it("scrive solo le parti cambiate", async () => {
    const idb = fakeIndexedDB();
    const store = new IndexedDBStore();
    await store.load();
    store.saveNode(node);
    await store.flush();
    expect(idb.puts).toEqual(["snapshot"]);
    store.saveExtra("ink_page", ink);
    await store.flush();
    expect(idb.puts).toEqual(["snapshot", "extras"]);
    await store.flush();
    expect(idb.puts).toHaveLength(2);
  });

  it("i disegni stanno negli extra e tornano al caricamento", async () => {
    const idb = fakeIndexedDB();
    const first = new IndexedDBStore();
    await first.load();
    first.saveNode(node);
    first.saveExtra("ink_page", ink);
    await first.flush();
    expect(Object.keys((idb.values.get("snapshot") as { ink_page: object }).ink_page)).toEqual([]);
    const second = new IndexedDBStore();
    await second.load();
    expect(second.node("n1")).toBeDefined();
    expect(second.extra("ink_page", "i1")).toBeDefined();
  });

  it("migra l'archivio nel formato precedente al primo salvataggio", async () => {
    const idb = fakeIndexedDB({ snapshot: { nodes: { n1: { id: "n1", tags: [] } }, ink_page: { i1: { id: "i1" } } } });
    const store = new IndexedDBStore();
    await store.load();
    expect(store.extra("ink_page", "i1")).toBeDefined();
    await store.flush();
    expect(idb.puts.sort()).toEqual(["extras", "snapshot"]);
    expect(idb.values.get("extras")).toEqual({ ink_page: { i1: { id: "i1" } }, attachment: {} });
  });
});
