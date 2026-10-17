import { afterEach, describe, expect, it, vi } from "vitest";
import { UNVERIFIED_SIGNAL } from "../src/health";
import { isLocalOnly, LOCAL_ONLY_TAG } from "../src/model";
import { Privacy } from "../src/privacy";
import { Repository } from "../src/repository";
import { IndexedDBStore, MemoryStore } from "../src/store";
import { SyncClient, type PushResult, type Transport } from "../src/sync";

const DIARY = "Il mio medico dice che la pressione è 150/95, devo prendere ramipril 5 mg ogni mattina.";

/** Server finto con la sola logica che serve qui: versioni, cursore, redazione. */
class Server implements Transport {
  rows: { entity: string; data: Record<string, unknown>; seq: number }[] = [];
  seq = 0;
  pushed: string[] = [];
  redacted: string[] = [];

  async push(body: { device_id: string; changes: unknown[] }): Promise<{ results: PushResult[] }> {
    const results = (body.changes as { entity: string; data: Record<string, unknown> }[]).map((c) => {
      this.pushed.push(`${c.entity}:${String(c.data.id)}`);
      const current = this.rows.filter((r) => r.entity === c.entity && r.data.id === c.data.id).at(-1);
      const record = { ...c.data, version: ((current?.data.version as number) ?? 0) + 1 };
      this.rows.push({ entity: c.entity, data: record, seq: ++this.seq });
      return { entity: c.entity, id: c.data.id as string, status: current ? ("updated" as const) : ("created" as const), record: record as never };
    });
    return { results };
  }

  async pull(body: { cursor: number; limit: number }) {
    const changes = this.rows.filter((r) => r.seq > body.cursor).slice(0, body.limit);
    return { changes: changes.map((r) => ({ entity: r.entity, data: r.data })), cursor: changes.at(-1)?.seq ?? body.cursor, has_more: false };
  }

  async redact(id: string) {
    this.redacted.push(id);
    this.rows = this.rows.filter((r) => r.data.id !== id && r.data.source_id !== id && r.data.target_id !== id && r.data.node_id !== id);
    this.rows.push({ entity: "purged", data: { entity: "node", id }, seq: ++this.seq });
  }
}

function pc() {
  const store = new MemoryStore();
  const privacy = new Privacy(store);
  const server = new Server();
  return { store, privacy, server, repo: new Repository(store, "pc"), sync: new SyncClient(store, server, "pc", (id) => privacy.isBlockedId(id)) };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("blocco di salute e solo locale", () => {
  it("un appunto che sembra un diario è trattenuto finché l'utente non lo dichiara innocuo", () => {
    const { repo, privacy, store } = pc();
    const diary = repo.createNode({ title: "Diario", body: DIARY });
    const study = repo.createNode({ title: "Analisi", body: "Le derivate misurano la pendenza." });
    expect(privacy.isHeld(store.node(diary.id)!)).toBe(true);
    expect(privacy.isBlocked(store.node(study.id)!)).toBe(false);
    privacy.dismiss(store.node(diary.id)!);
    expect(privacy.isHeld(store.node(diary.id)!)).toBe(false);
    // Un segnale nuovo, mai giudicato, blocca di nuovo.
    const edited = repo.updateNode(diary.id, { body_md: `${DIARY} Ho anche un'allergia grave e sintomi da giorni, mi hanno diagnosticato l'asma.` });
    expect(privacy.isHeld(edited)).toBe(true);
  });

  it("il tag solo-locale blocca senza bisogno del rilevatore", () => {
    const { repo, privacy } = pc();
    const note = repo.createNode({ title: "Nota", body: "Una cosa qualunque.", tags: ["x", LOCAL_ONLY_TAG] });
    expect(isLocalOnly(note)).toBe(true);
    expect(privacy.isBlocked(note)).toBe(true);
    expect(privacy.isHeld(note)).toBe(false);
  });

  it("un testo in una lingua sconosciuta è trattenuto, e si sblocca solo con il giudizio dell'utente", () => {
    const { repo, privacy, store } = pc();
    const note = repo.createNode({ title: "Дневник", body: "Сегодня я был у врача, у меня высокая температура" });
    expect(privacy.isHeld(store.node(note.id)!)).toBe(true);
    expect(privacy.assessment(store.node(note.id)!).signals.has(UNVERIFIED_SIGNAL)).toBe(true);
    privacy.dismiss(store.node(note.id)!);
    expect(privacy.isHeld(store.node(note.id)!)).toBe(false);
  });

  it("la sync non manda i nodi bloccati, né i loro archi e le loro pagine, e manda gli altri", async () => {
    const { repo, privacy, store, server, sync } = pc();
    const open = repo.createNode({ title: "Aperto", body: "Appunti di analisi." });
    const diary = repo.createNode({ title: "Diario", body: DIARY });
    const edge = repo.createEdge(open.id, diary.id, "manual");
    const page = repo.createInkPage(diary.id);
    await sync.sync();
    expect(server.pushed).toEqual([`node:${open.id}`]);
    // Restano in outbox, e non sono rifiutate.
    expect(store.pending().map((p) => `${p.entity}:${p.id}`).sort()).toEqual([`edge:${edge.id}`, `ink_page:${page.id}`, `node:${diary.id}`].sort());
    expect(sync.rejections).toHaveLength(0);
    // Dichiarato innocuo, parte tutto.
    privacy.dismiss(store.node(diary.id)!);
    await sync.sync();
    expect(server.pushed).toEqual(expect.arrayContaining([`node:${diary.id}`, `edge:${edge.id}`, `ink_page:${page.id}`]));
    expect(store.pending()).toHaveLength(0);
  });

  it("un nodo già sul server, reso solo locale, viene tolto dal server e resta sul PC", async () => {
    const { repo, store, server, sync } = pc();
    const other = repo.createNode({ title: "Altro" });
    const note = repo.createNode({ title: "Riservata", body: "Contenuto che non deve restare sul server." });
    repo.createEdge(note.id, other.id, "manual");
    await sync.sync();
    expect(server.rows.some((r) => r.data.id === note.id)).toBe(true);

    repo.updateNode(note.id, { tags: [LOCAL_ONLY_TAG] });
    store.queueRedact(note.id);
    await sync.sync();

    expect(server.redacted).toEqual([note.id]);
    expect(server.rows.some((r) => r.entity !== "purged" && r.data.id === note.id)).toBe(false);
    expect(store.redactQueue()).toEqual([]);
    // Il PC la tiene, come un record mai sincronizzato, e il "purged" di ritorno non la cancella.
    expect(store.node(note.id)).toMatchObject({ title: "Riservata", version: 0 });
    expect(store.edges()).toHaveLength(1);
    expect(store.pendingChange("node", note.id)).toMatchObject({ baseVersion: null });
    // E non è ripartita verso il server.
    expect(server.pushed.filter((p) => p === `node:${note.id}`)).toHaveLength(1);
    // Dopo una sync completa è ancora lì.
    await sync.sync();
    expect(store.node(note.id)?.title).toBe("Riservata");
  });

  it("se la redazione non riesce resta in coda e riprova alla sync dopo", async () => {
    const { repo, store, server, sync } = pc();
    const note = repo.createNode({ title: "Riservata", tags: [LOCAL_ONLY_TAG] });
    store.queueRedact(note.id);
    const redact = vi.spyOn(server, "redact").mockRejectedValueOnce(new Error("offline"));
    await expect(sync.sync()).rejects.toThrow("offline");
    expect(store.redactQueue()).toEqual([note.id]);
    redact.mockRestore();
    await sync.sync();
    expect(store.redactQueue()).toEqual([]);
    expect(server.redacted).toEqual([note.id]);
  });
});

describe("archivio locale", () => {
  it("ricorda i segnali giudicati e la coda di redazione, e si cancella", async () => {
    const store = new MemoryStore();
    store.setDismissedSignals("a", ["febbre", "dose", "febbre"]);
    store.queueRedact("a");
    store.queueRedact("a");
    expect(store.dismissedSignals("a")).toEqual(["dose", "febbre"]);
    expect(store.redactQueue()).toEqual(["a"]);
    store.unqueueRedact("a");
    expect(store.redactQueue()).toEqual([]);
    store.saveNode({ id: "a" } as never);
    await store.wipe();
    expect(store.nodes()).toEqual([]);
    expect(store.dismissedSignals("a")).toEqual([]);
  });

  it("se IndexedDB non si apre l'archivio resta in memoria e lo dice", async () => {
    vi.stubGlobal("indexedDB", {
      open() {
        const request: { onerror?: () => void; error?: Error } = {};
        queueMicrotask(() => { request.error = new Error("spazio negato"); request.onerror?.(); });
        return request;
      },
    });
    const store = new IndexedDBStore();
    await store.load();
    expect(store.persistent).toBe(false);
    expect(store.failure).toBe("spazio negato");
    store.saveNode({ id: "a", tags: [] } as never);
    await expect(store.flush()).resolves.toBeUndefined();
    expect(store.nodes()).toHaveLength(1);
  });

  it("senza IndexedDB (navigazione privata) non lancia", async () => {
    vi.stubGlobal("indexedDB", undefined);
    const store = new IndexedDBStore();
    await store.load();
    expect(store.persistent).toBe(false);
  });

  it("chiede la persistenza del browser, se c'è", async () => {
    const persist = vi.fn(async () => true);
    vi.stubGlobal("navigator", { storage: { persist } });
    expect(await new IndexedDBStore().requestPersistence()).toBe(true);
    vi.stubGlobal("navigator", {});
    expect(await new IndexedDBStore().requestPersistence()).toBe(false);
  });

  it("la cancellazione elimina il database", async () => {
    const deleted: string[] = [];
    vi.stubGlobal("indexedDB", {
      deleteDatabase(name: string) {
        deleted.push(name);
        const request: { onsuccess?: () => void } = {};
        queueMicrotask(() => request.onsuccess?.());
        return request;
      },
    });
    const store = new IndexedDBStore();
    store.saveNode({ id: "a", tags: [] } as never);
    await store.wipe();
    expect(deleted).toEqual(["pitchstone"]);
    expect(store.nodes()).toEqual([]);
  });
});
