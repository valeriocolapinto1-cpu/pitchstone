import { afterEach, describe, expect, it, vi } from "vitest";
import {
  backupExists, checkDatabaseSize, containsHealth, dailyBackup, dayName, expired, latestManifest, ping, runName,
  type Manifest,
} from "../src/backup";

import { fake, ink, node, sample } from "./fakes";

const config = { url: "https://db.example", secretKey: "sb_secret_test" };
const now = new Date("2026-10-15T04:30:12Z");

afterEach(() => {
  vi.restoreAllMocks();
});

describe("backup giornaliero", () => {
  it("scrive un file per pagina, i disegni a parte e il manifest per ultimo", async () => {
    const { fetchImpl, objects } = fake(sample, { ink });
    expect(await dailyBackup(config, now, fetchImpl, { expire: false })).toBe("saved");
    const paths = [...objects.keys()];
    expect(paths.every((path) => path.startsWith("2026-10-15/043012-"))).toBe(true);
    const names = paths.map((path) => path.split("/")[2]);
    expect(names).toEqual(expect.arrayContaining(["nodes-000.json", "nodes-001.json", "edges-000.json", "node_versions-000.json", "ink_pages-000.json", "purged-000.json", "ink-000.json", "manifest.json"]));
    expect(names.at(-1)).toBe("manifest.json");
    const manifest = JSON.parse(objects.get(paths.at(-1) ?? "") ?? "") as Manifest;
    expect(manifest.counts).toEqual({ nodes: 3, edges: 1, node_versions: 1, attachments: 0, ink_pages: 1, purged: 1 });
    expect(manifest.version).toBe(2);
    // Il disegno è in un file suo, non nelle righe della tabella.
    expect(objects.get(paths.find((path) => path.endsWith("ink_pages-000.json")) ?? "")).not.toContain("QUJDRA");
    expect(objects.get(paths.find((path) => path.endsWith("ink-000.json")) ?? "")).toContain("QUJDRA==");
  });

  it("il manifest ha sha256 e dimensione corretti di ogni file", async () => {
    const { fetchImpl, objects } = fake(sample, { ink });
    await dailyBackup(config, now, fetchImpl, { expire: false });
    const manifestPath = [...objects.keys()].find((path) => path.endsWith("manifest.json")) ?? "";
    const manifest = JSON.parse(objects.get(manifestPath) ?? "") as Manifest;
    expect(manifest.files.length).toBeGreaterThan(5);
    for (const file of manifest.files) {
      const body = objects.get(file.path) ?? "";
      const bytes = new TextEncoder().encode(body);
      const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
      expect(file.sha256).toBe(Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join(""));
      expect(file.bytes).toBe(bytes.byteLength);
      expect(file.rows).toBe((JSON.parse(body) as unknown[]).length);
    }
  });

  it("due backup nello stesso giorno non si sovrascrivono", async () => {
    const { fetchImpl, objects } = fake(sample, { ink });
    await dailyBackup(config, now, fetchImpl, { expire: false });
    await dailyBackup(config, new Date(now.getTime() + 60_000), fetchImpl, { expire: false });
    const runs = new Set([...objects.keys()].map((path) => path.split("/").slice(0, 2).join("/")));
    expect(runs.size).toBe(2);
  });

  it("rifiuta e non salva niente se un nodo è di salute", async () => {
    const { fetchImpl, objects } = fake({ ...sample, nodes: [node(1), node(2, { type: "health", area: "salute" })] }, { ink });
    expect(await dailyBackup(config, now, fetchImpl)).toBe("refused");
    expect(objects.size).toBe(0);
  });

  it("rifiuta un calo dei nodi oltre il 20% rispetto al backup precedente", async () => {
    const many = Array.from({ length: 20 }, (_, i) => node(i + 1));
    const store = fake({ ...sample, nodes: many }, { ink });
    expect(await dailyBackup(config, now, store.fetchImpl, { expire: false })).toBe("saved");
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    // Stesso bucket, ma il database ora ha solo 10 nodi.
    const shrunk = fake({ ...sample, nodes: many.slice(0, 10) }, { ink });
    for (const [path, body] of store.objects) shrunk.objects.set(path, body);
    const before = shrunk.objects.size;
    expect(await dailyBackup(config, new Date(now.getTime() + 86_400_000), shrunk.fetchImpl, { expire: false })).toBe("refused");
    expect(shrunk.objects.size).toBe(before);
    expect(errors).toHaveBeenCalled();
    // Un calo del 10% passa.
    const slight = fake({ ...sample, nodes: many.slice(0, 18) }, { ink });
    for (const [path, body] of store.objects) slight.objects.set(path, body);
    expect(await dailyBackup(config, new Date(now.getTime() + 86_400_000), slight.fetchImpl, { expire: false })).toBe("saved");
  });

  it("se un upload fallisce toglie i file già scritti e non segna il backup", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const store = fake(sample, { ink, failPut: (path) => path.endsWith("edges-000.json") });
    expect(await dailyBackup(config, now, store.fetchImpl)).toBe("failed");
    expect(store.objects.size).toBe(0);
    expect(store.calls.some((call) => call.fn === "backup_mark_done")).toBe(false);
  });

  it("senza il manifest un backup non vale", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const store = fake(sample, { ink, failPut: (path) => path.endsWith("manifest.json") });
    expect(await dailyBackup(config, now, store.fetchImpl)).toBe("failed");
    expect(store.objects.size).toBe(0);
    expect(await latestManifest(config, store.fetchImpl)).toBeUndefined();
  });

  it("fallisce se i conteggi non tornano", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const store = fake(sample, { ink });
    const base = store.fetchImpl.getMockImplementation();
    store.fetchImpl.mockImplementation(async (input, init) => {
      const response = await base?.(input, init);
      // backup_rows dichiara 3 nodi ma ne consegna meno di quelli contati.
      if (String(input).endsWith("/rpc/backup_rows") && String(init?.body).includes('"nodes"') && !String(init?.body).includes("p_after\":null")) {
        return Response.json({ rows: [], last: null, more: false });
      }
      return response ?? new Response("", { status: 500 });
    });
    expect(await dailyBackup(config, now, store.fetchImpl)).toBe("failed");
    expect(store.objects.size).toBe(0);
  });

  it("segna il backup riuscito e cancella quelli oltre 14 giorni, anche in formato vecchio", async () => {
    const store = fake(sample, { ink });
    store.objects.set("2026-09-30/010000-aaaa/nodes-000.json", "[]");
    store.objects.set("2026-09-30/010000-aaaa/manifest.json", "{}");
    store.objects.set("2026-10-01.json", "{}");
    store.objects.set("2026-10-14/010000-bbbb/manifest.json", "{}");
    expect(await dailyBackup(config, now, store.fetchImpl)).toBe("saved");
    expect(store.calls.some((call) => call.fn === "backup_mark_done")).toBe(true);
    const left = [...store.objects.keys()];
    expect(left.some((path) => path.startsWith("2026-09-30/"))).toBe(false);
    expect(left).not.toContain("2026-10-01.json");
    expect(left).toContain("2026-10-14/010000-bbbb/manifest.json");
  });

  it("latestManifest e backupExists", async () => {
    const store = fake(sample, { ink });
    expect(await backupExists(config, now, store.fetchImpl)).toBe(false);
    await dailyBackup(config, now, store.fetchImpl, { expire: false });
    expect(await backupExists(config, now, store.fetchImpl)).toBe(true);
    expect(await backupExists(config, new Date("2026-10-16T04:30:00Z"), store.fetchImpl)).toBe(false);
    expect((await latestManifest(config, store.fetchImpl))?.manifest.counts.nodes).toBe(3);
  });

  it("filtro, nomi e scadenze", () => {
    expect(containsHealth({ nodes: [{ area: "salute" }] })).toBe(true);
    expect(containsHealth({ nodes: [{ type: "concept", area: "studio" }] })).toBe(false);
    expect(dayName(now)).toBe("2026-10-15");
    expect(runName(now, "ab12")).toBe("2026-10-15/043012-ab12");
    expect(expired(["2026-10-01", "2026-09-02.json", "2026-10-02.json", "2026-10-15", "x.json", "2026-10-01.txt"], now)).toEqual(["2026-10-01", "2026-09-02.json"]);
  });
});

describe("segnali", () => {
  it("ping: URL di successo o /fail, mai un'eccezione", async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => new Response("ok"));
    await ping("https://hc.example/uuid", true, undefined, fetchImpl);
    await ping("https://hc.example/uuid/", false, "backup failed", fetchImpl);
    await ping(undefined, true, undefined, fetchImpl);
    expect(fetchImpl.mock.calls.map(([url]) => String(url))).toEqual(["https://hc.example/uuid", "https://hc.example/uuid/fail"]);
    expect(fetchImpl.mock.calls[1][1]?.body).toBe("backup failed");
    await expect(ping("https://hc.example/x", true, undefined, async () => {
      throw new Error("rete");
    })).resolves.toBeUndefined();
  });

  it("dimensione del database", async () => {
    const store = fake(sample);
    expect(await checkDatabaseSize(config, store.fetchImpl)).toBe(400 * 1024 * 1024);
  });
});
