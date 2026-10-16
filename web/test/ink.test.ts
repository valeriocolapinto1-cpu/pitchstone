import { describe, expect, it } from "vitest";
// Lo stesso file lo leggono i test dell'iPad (PortableInkTests): i due codec devono coincidere.
import fixture from "../../docs/fixtures/psink1-esempio.psink?raw";
import {
  base64ToBytes, bytesToBase64, decodeInk, displayColor, encodeInk, inkFormat, InkFormatError, type InkStroke,
  normalizeStroke, pageHeight, strokesHit, widthAt,
} from "../src/ink";
import type { InkPageRecord } from "../src/model";
import { Repository } from "../src/repository";
import { MemoryStore } from "../src/store";
import { type PushResult, SyncClient, type Transport } from "../src/sync";

const bytes = (text: string) => new TextEncoder().encode(text);

describe("formato PSINK1", () => {
  it("legge il file di esempio condiviso con l'iPad", () => {
    const page = decodeInk(bytes(fixture));
    expect(page.width).toBe(800);
    expect(page.height).toBe(1131.2);
    expect(page.strokes.map((s) => s.tool)).toEqual(["pen", "marker", "pencil"]);
    expect(page.strokes[0]).toEqual({
      tool: "pen", color: "#1d1d1fff", width: 2.5,
      points: [[100, 120.5, 0.5, 0], [110.2, 125, 0.62, 0.016], [130, 131.7, 0.8, 0.033], [150.5, 140, 0.4, 0.05]],
    });
    expect(page.strokes[1].color).toBe("#ffcc0080");
    expect(page.strokes[2].points).toEqual([[200, 500, 1, 0]]);
  });

  it("scrive esattamente gli stessi byte del file di esempio (codifica canonica)", () => {
    const encoded = encodeInk(decodeInk(bytes(fixture)));
    expect(new TextDecoder().decode(encoded)).toBe(fixture);
  });

  it("arrotonda coordinate, pressione e tempo, e tiene i valori nei limiti", () => {
    const stroke = normalizeStroke({
      tool: "pen", color: "#FF0000", width: 2.345,
      points: [[10.04, 20.06, 0.123, 0.0004], [-3.25, 5.55, 1.7, -1], [1, 2]],
    })!;
    expect(stroke.color).toBe("#ff0000ff");
    expect(stroke.width).toBe(2.3);
    expect(stroke.points).toEqual([[10, 20.1, 0.12, 0], [-3.3, 5.6, 1, 0], [1, 2, 0.5, 0]]);
    const decoded = decodeInk(encodeInk({ width: 800, height: 1131.2, strokes: [stroke] }));
    expect(decoded.strokes).toEqual([stroke]);
  });

  it("valori sconosciuti diventano predefiniti, tratti senza punti spariscono", () => {
    const text = 'PSINK1\n{"v":1,"width":600,"strokes":[{"tool":"brush","color":"rosso","points":[[1,2,0.3,0]],"extra":true},{"tool":"pen","points":[]}],"futuro":1}';
    const page = decodeInk(bytes(text));
    expect(page.width).toBe(600);
    expect(page.height).toBeCloseTo(600 * 1.414, 1);
    expect(page.strokes).toEqual([{ tool: "pen", color: "#000000ff", width: 2, points: [[1, 2, 0.3, 0]] }]);
  });

  it("pagina vuota: zero byte; un PKDrawing dell'iPad non si legge", () => {
    expect(encodeInk({ width: 800, height: 1131.2, strokes: [] })).toHaveLength(0);
    expect(decodeInk(new Uint8Array()).strokes).toEqual([]);
    expect(inkFormat(new Uint8Array())).toBe("empty");
    expect(inkFormat(bytes(fixture))).toBe("psink1");
    const pkdrawing = new Uint8Array([0x77, 0x72, 0x64, 0xf0, 0x00, 0x01, 0x02]);
    expect(inkFormat(pkdrawing)).toBe("other");
    expect(() => decodeInk(pkdrawing)).toThrow(InkFormatError);
    expect(() => decodeInk(bytes('PSINK1\n{"v":2,"strokes":[]}'))).toThrow(InkFormatError);
    expect(() => decodeInk(bytes("PSINK1\n{rotto"))).toThrow(InkFormatError);
  });

  it("base64 come nel JSON della sync, anche per pagine grandi", () => {
    const big = new Uint8Array(200_000).map((_, i) => i % 256);
    expect(base64ToBytes(bytesToBase64(big))).toEqual(big);
    expect(bytesToBase64(bytes("PSINK1\n"))).toBe("UFNJTksxCg==");
  });

  it("altezza: A4 o i tratti più 200", () => {
    const stroke: InkStroke = { tool: "pen", color: "#000000ff", width: 2, points: [[0, 2000, 0.5, 0]] };
    expect(pageHeight(800, [])).toBe(1131.2);
    expect(pageHeight(800, [stroke])).toBe(2200);
  });

  it("larghezza secondo la pressione; l'evidenziatore è uniforme", () => {
    expect(widthAt({ tool: "pen", width: 3 }, 0.5)).toBeCloseTo(3);
    expect(widthAt({ tool: "pen", width: 3 }, 1)).toBeCloseTo(4.8);
    expect(widthAt({ tool: "pen", width: 3 }, 0)).toBeCloseTo(1.2);
    expect(widthAt({ tool: "marker", width: 16 }, 0.1)).toBe(16);
  });

  it("tema scuro: il nero diventa chiaro, l'alfa resta", () => {
    expect(displayColor("#000000ff", true)).toBe("#ffffffff");
    expect(displayColor("#ffffff80", true)).toBe("#00000080");
    expect(displayColor("#007affff", false)).toBe("#007affff");
  });
});

describe("gomma a tratti", () => {
  const line = (y: number, width = 2): InkStroke => ({
    tool: "pen", color: "#000000ff", width, points: [[0, y, 0.5, 0], [100, y, 0.5, 0.1], [200, y, 0.5, 0.2]],
  });

  it("toglie i tratti vicini al punto, non gli altri", () => {
    const strokes = [line(10), line(50), line(53)];
    expect(strokesHit(strokes, 150, 12, 3)).toEqual([0]);
    expect(strokesHit(strokes, 150, 51.5, 3)).toEqual([1, 2]);
    expect(strokesHit(strokes, 150, 30, 3)).toEqual([]);
    // Fuori dagli estremi del tratto.
    expect(strokesHit(strokes, 210, 10, 3)).toEqual([]);
  });

  it("un movimento veloce che attraversa un tratto lo cancella", () => {
    const strokes = [line(100)];
    expect(strokesHit(strokes, 50, 150, 3)).toEqual([]);
    expect(strokesHit(strokes, 50, 150, 3, [50, 40])).toEqual([0]);
  });

  it("un tratto di un solo punto si cancella", () => {
    const dot: InkStroke = { tool: "pen", color: "#000000ff", width: 4, points: [[20, 20, 0.5, 0]] };
    expect(strokesHit([dot], 23, 23, 3)).toEqual([0]);
  });
});

/** Server finto con la regola delle pagine: un conflitto non sovrascrive, il disegno del client diventa una copia. */
class FakeServer implements Transport {
  rows: { entity: string; data: Record<string, unknown>; seq: number }[] = [];
  seq = 0;

  current(entity: string, id: unknown) {
    return this.rows.filter((r) => r.entity === entity && r.data.id === id).at(-1)?.data;
  }

  async push(body: { device_id: string; changes: unknown[] }): Promise<{ results: PushResult[] }> {
    const results = (body.changes as { entity: string; base_version: number | null; data: Record<string, unknown> }[]).map((c) => {
      if (c.entity === "ink_page" && !this.current("node", c.data.node_id)) {
        return { status: "rejected" as const, message: "nodo mancante" };
      }
      const current = this.current(c.entity, c.data.id);
      if (current && c.entity === "ink_page" && c.base_version !== current.version && current.ink_data !== c.data.ink_data) {
        const copy = { ...c.data, id: crypto.randomUUID(), version: 1 };
        this.rows.push({ entity: "ink_page", data: copy, seq: ++this.seq });
        return { status: "merged" as const, record: current as never };
      }
      const record = { ...c.data, version: ((current?.version as number) ?? 0) + 1 };
      this.rows.push({ entity: c.entity, data: record, seq: ++this.seq });
      return { status: current ? ("updated" as const) : ("created" as const), record: record as never };
    });
    return { results };
  }

  async pull(body: { cursor: number; limit: number }) {
    const changes = this.rows.filter((r) => r.seq > body.cursor);
    return { changes: changes.map((r) => ({ entity: r.entity, data: r.data })), cursor: changes.at(-1)?.seq ?? body.cursor, has_more: false };
  }
}

function device(server: FakeServer, name: string) {
  const store = new MemoryStore();
  return { store, repo: new Repository(store, name), sync: new SyncClient(store, server, name) };
}

const drawing = (y: number) => bytesToBase64(encodeInk({
  width: 800, height: 1131.2, strokes: [{ tool: "pen", color: "#000000ff", width: 3, points: [[10, y, 0.5, 0], [90, y, 0.6, 0.1]] }],
}));

describe("pagine a penna nella sync", () => {
  it("una pagina disegnata sul PC arriva all'altro dispositivo, dopo il suo nodo", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    const other = device(server, "ipad");
    const node = pc.repo.createNode({ title: "Appunti" });
    const page = pc.repo.createInkPage(node.id, "lines");
    expect(page).toMatchObject({ page_no: 0, background: "lines", ink_data: "", attachment_id: null, version: 0 });
    pc.repo.saveDrawing(page.id, drawing(50), "");
    expect(pc.store.pending().map((p) => [p.entity, p.baseVersion])).toEqual([["node", null], ["ink_page", null]]);

    await pc.sync.sync();
    expect(pc.store.pending()).toHaveLength(0);
    expect(server.rows.map((r) => r.entity)).toEqual(["node", "ink_page"]);
    await other.sync.sync();
    const received = other.repo.inkPages(node.id);
    expect(received).toHaveLength(1);
    expect(decodeInk(base64ToBytes(received[0].ink_data)).strokes[0].points[0]).toEqual([10, 50, 0.5, 0]);
  });

  it("le modifiche successive partono dalla versione del server; il cestino toglie la pagina dall'elenco", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    const node = pc.repo.createNode({ title: "Appunti" });
    const page = pc.repo.createInkPage(node.id);
    await pc.sync.sync();
    pc.repo.saveDrawing(page.id, drawing(10), "");
    expect(pc.store.pendingChange("ink_page", page.id)?.baseVersion).toBe(1);
    pc.repo.trashInkPage(page.id);
    expect(pc.repo.inkPages(node.id)).toEqual([]);
    expect(pc.repo.inkPages(node.id, true)).toHaveLength(1);
    await pc.sync.sync();
    expect(server.current("ink_page", page.id)).toMatchObject({ version: 2, ink_data: drawing(10) });
    expect(server.current("ink_page", page.id)?.deleted_at).toBeTruthy();
  });

  it("un pull non sovrascrive una pagina con tratti non inviati", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    const other = device(server, "ipad");
    const node = pc.repo.createNode({ title: "Appunti" });
    const page = pc.repo.createInkPage(node.id);
    await pc.sync.sync();
    await other.sync.sync();
    other.repo.saveDrawing(page.id, drawing(20), "");
    await other.sync.sync();
    pc.repo.saveDrawing(page.id, drawing(30), "");
    // Il push del PC va in conflitto: il server tiene la sua pagina, i tratti del PC diventano una copia.
    await pc.sync.sync();
    const pages = pc.repo.inkPages(node.id).map((p) => p.ink_data).sort();
    expect(pages).toEqual([drawing(20), drawing(30)].sort());
  });

  it("se una sync cambia la pagina mentre si disegna, i tratti vanno in una nuova pagina", () => {
    const store = new MemoryStore();
    const repo = new Repository(store, "pc");
    const node = repo.createNode({ title: "Appunti" });
    const page = repo.createInkPage(node.id);
    // Arriva dal server un disegno dell'iPad.
    store.saveExtra("ink_page", { ...repo.inkPage(page.id)!, ink_data: drawing(70), version: 2 });
    const saved = repo.saveDrawing(page.id, drawing(80), "");
    expect(saved.id).not.toBe(page.id);
    expect(saved.page_no).toBe(1);
    expect(repo.inkPage(page.id)?.ink_data).toBe(drawing(70));
  });

  it("le annotazioni sui PDF non sono pagine del nodo", () => {
    const store = new MemoryStore();
    const repo = new Repository(store, "pc");
    const node = repo.createNode({ title: "Appunti" });
    const annotation = { ...repo.createInkPage(node.id), id: "pdf", attachment_id: "a", pdf_page: 0 } satisfies InkPageRecord;
    store.saveExtra("ink_page", annotation);
    expect(repo.inkPages(node.id).map((p) => p.id)).not.toContain("pdf");
  });

  it("niente pagine per i nodi di salute; una pagina rifiutata riparte quando arriva il nodo", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    pc.store.saveNode({ ...pc.repo.createNode({ title: "x" }), id: "salute", area: "salute" as never });
    expect(() => pc.repo.createInkPage("salute")).toThrow();
    expect(() => pc.repo.createInkPage("inesistente")).toThrow();

    const node = pc.repo.createNode({ title: "Appunti" });
    const page = pc.repo.createInkPage(node.id);
    // Il nodo non è ancora partito: la pagina viene rifiutata, poi riprova.
    pc.store.removePending("node", node.id);
    await pc.sync.sync();
    expect(pc.store.pendingChange("ink_page", page.id)?.rejection).toBe("nodo mancante");
    pc.repo.updateNode(node.id, { title: "Appunti di analisi" });
    await pc.sync.sync();
    await pc.sync.sync();
    expect(pc.store.pendingChange("ink_page", page.id)).toBeUndefined();
    expect(server.current("ink_page", page.id)).toBeTruthy();
  });

  it("le pagine dei nodi di salute in arrivo vengono scartate, anche se arrivano prima del nodo", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    server.rows.push(
      { entity: "ink_page", data: { id: "p", node_id: "h", page_no: 0, ink_data: "", deleted_at: null }, seq: ++server.seq },
      { entity: "node", data: { id: "h", type: "health", area: "salute", title: "x" }, seq: ++server.seq },
    );
    await pc.sync.sync();
    expect(pc.store.extras("ink_page")).toEqual([]);
  });

  it("Scarta toglie una pagina mai arrivata al server; un nodo eliminato per sempre porta via le sue pagine", async () => {
    const server = new FakeServer();
    const pc = device(server, "pc");
    const node = pc.repo.createNode({ title: "Appunti" });
    await pc.sync.sync();
    const page = pc.repo.createInkPage(node.id);
    pc.sync.discard("ink_page", page.id);
    expect(pc.repo.inkPage(page.id)).toBeUndefined();

    const kept = pc.repo.createInkPage(node.id);
    await pc.sync.sync();
    server.rows.push({ entity: "purged", data: { entity: "node", id: node.id }, seq: ++server.seq });
    await pc.sync.sync();
    expect(pc.repo.inkPage(kept.id)).toBeUndefined();
  });
});
