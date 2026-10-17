import { afterEach, describe, expect, it, vi } from "vitest";
import { dailyBackup } from "../src/backup";
import { loadBackup, restoreBackup, WIPE_CONFIRMATION } from "../src/restore";
import { fake, ink, sample } from "./fakes";

const config = { url: "https://db.example", secretKey: "sb_secret_test" };
const now = new Date("2026-10-15T04:30:12Z");

async function saved() {
  const store = fake(sample, { ink });
  expect(await dailyBackup(config, now, store.fetchImpl, { expire: false })).toBe("saved");
  const run = [...store.objects.keys()][0].split("/").slice(0, 2).join("/");
  store.calls.length = 0;
  return { store, run };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("ripristino", () => {
  it("verifica un backup integro", async () => {
    const { store, run } = await saved();
    const backup = await loadBackup(config, run, store.fetchImpl);
    expect(backup.tables.nodes).toHaveLength(3);
    expect(backup.ink).toHaveLength(1);
    expect(backup.manifest.counts.nodes).toBe(3);
  });

  it("rifiuta un file alterato, mancante o con righe diverse, senza scrivere nel database", async () => {
    for (const tamper of [
      (objects: Map<string, string>, path: string) => objects.set(path, objects.get(path)?.replace("n1", "xx") ?? ""),
      (objects: Map<string, string>, path: string) => objects.delete(path),
      (objects: Map<string, string>, path: string) => objects.set(path, "[]"),
    ]) {
      const { store, run } = await saved();
      tamper(store.objects, [...store.objects.keys()].find((path) => path.endsWith("nodes-000.json")) ?? "");
      await expect(restoreBackup(config, run, {}, store.fetchImpl)).rejects.toThrow();
      expect(store.calls.filter((call) => call.fn.startsWith("backup_restore"))).toHaveLength(0);
    }
  });

  it("rifiuta un backup con dati di salute", async () => {
    const { store, run } = await saved();
    const manifestPath = `${run}/manifest.json`;
    const manifest = JSON.parse(store.objects.get(manifestPath) ?? "");
    const path = `${run}/nodes-000.json`;
    const body = JSON.stringify([{ id: "x", type: "health", area: "salute" }]);
    store.objects.set(path, body);
    const file = manifest.files.find((f: { path: string }) => f.path === path);
    file.bytes = new TextEncoder().encode(body).byteLength;
    file.rows = 1;
    file.sha256 = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body))), (b) => b.toString(16).padStart(2, "0")).join("");
    manifest.counts.nodes = manifest.files.filter((f: { table: string }) => f.table === "nodes").reduce((n: number, f: { rows: number }) => n + f.rows, 0);
    store.objects.set(manifestPath, JSON.stringify(manifest));
    await expect(loadBackup(config, run, store.fetchImpl)).rejects.toThrow(/salute|righe/);
  });

  it("scrive le tabelle nell'ordine delle chiavi esterne, poi i disegni e la nuova epoca", async () => {
    const { store, run } = await saved();
    const logs: string[] = [];
    // Dopo il ripristino i conteggi del database coincidono con il manifest.
    expect(await restoreBackup(config, run, { log: (m) => logs.push(m) }, store.fetchImpl)).toBe(2);
    const order = store.calls.filter((call) => call.fn.startsWith("backup_restore")).map((call) => call.fn === "backup_restore_rows" ? String(call.args.p_table) : call.fn);
    expect(order).toEqual(["nodes", "edges", "node_versions", "ink_pages", "purged", "backup_restore_ink", "backup_restore_finish"]);
    expect(store.calls.find((call) => call.fn === "backup_restore_ink")?.args.p_rows).toEqual(ink);
    expect(logs.at(-1)).toContain("epoca");
  });

  it("lo svuotamento chiede la conferma e viene prima di tutto il resto", async () => {
    const { store, run } = await saved();
    await expect(restoreBackup(config, run, { wipe: true }, store.fetchImpl)).rejects.toThrow(/conferma/);
    await expect(restoreBackup(config, run, { wipe: true, confirm: "sì" }, store.fetchImpl)).rejects.toThrow(/conferma/);
    expect(store.calls).toHaveLength(0);
    await restoreBackup(config, run, { wipe: true, confirm: WIPE_CONFIRMATION }, store.fetchImpl);
    const restoreCalls = store.calls.filter((call) => call.fn.startsWith("backup_restore"));
    expect(restoreCalls[0].fn).toBe("backup_restore_wipe");
    expect(restoreCalls[0].args).toEqual({ p_confirm: WIPE_CONFIRMATION });
  });

  it("fallisce se dopo il ripristino i conteggi non tornano", async () => {
    const { store, run } = await saved();
    const base = store.fetchImpl.getMockImplementation();
    store.fetchImpl.mockImplementation(async (input, init) => {
      if (String(input).endsWith("/rpc/backup_counts")) return Response.json({ nodes: 1, edges: 1, node_versions: 1, ink_pages: 1, attachments: 0, purged: 1 });
      return (await base?.(input, init)) ?? new Response("", { status: 500 });
    });
    await expect(restoreBackup(config, run, { wipe: true, confirm: WIPE_CONFIRMATION }, store.fetchImpl)).rejects.toThrow(/nodes/);
  });
});
