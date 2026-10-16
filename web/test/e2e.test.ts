// Sync end-to-end tra "iPad" (richieste nel formato del client Swift) e PWA,
// contro il Postgres locale (supabase start). Gira solo con E2E_SUPABASE_URL e
// E2E_SUPABASE_SECRET_KEY, come i test end-to-end del Worker.
import { describe, expect, it } from "vitest";
import { Repository } from "../src/repository";
import { MemoryStore } from "../src/store";
import { SyncClient, type Transport } from "../src/sync";

declare const process: { env: Record<string, string | undefined> };
const url = process.env.E2E_SUPABASE_URL;
const secretKey = process.env.E2E_SUPABASE_SECRET_KEY;
if (process.env.E2E_REQUIRED && (!url || !secretKey)) throw new Error("E2E_REQUIRED: mancano le variabili di Supabase");

/** Le stesse chiamate che fa il Worker dopo aver verificato Cloudflare Access. */
class RpcTransport implements Transport {
  private async rpc<T>(fn: string, args: unknown): Promise<T> {
    const response = await fetch(`${url}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: { apikey: secretKey ?? "", "content-type": "application/json" },
      body: JSON.stringify(args),
    });
    if (!response.ok) throw new Error(`${fn}: ${response.status} ${await response.text()}`);
    return (await response.json()) as T;
  }

  push(body: { device_id: string; changes: unknown[] }) {
    return this.rpc<never>("sync_push", { p_device_id: body.device_id, p_changes: body.changes });
  }

  pull(body: { cursor: number; limit: number }) {
    return this.rpc<never>("sync_pull", { p_cursor: body.cursor, p_limit: body.limit });
  }
}

describe.skipIf(!url || !secretKey)("iPad e PWA vedono gli stessi dati", () => {
  it("un nodo dall'iPad arriva sul PC, una modifica dal PC torna all'iPad", async () => {
    const transport = new RpcTransport();
    const id = crypto.randomUUID();
    const other = crypto.randomUUID();
    const edge = crypto.randomUUID();
    const now = new Date().toISOString();
    // L'iPad: due nodi e un arco, come li codifica il client Swift.
    const ipad = await transport.push({
      device_id: "ipad-e2e",
      changes: [
        { entity: "node", base_version: null, data: { id, type: "concept", title: "Derivata e2e", body_md: "Dall'iPad", area: "studio", tags: ["analisi"], version: 0, created_at: now, updated_at: now, deleted_at: null, device_id: "ipad-e2e" } },
        { entity: "node", base_version: null, data: { id: other, type: "exam", title: "Analisi e2e", body_md: "", area: "studio", tags: ["data:2027-01-20"], version: 0, created_at: now, updated_at: now, deleted_at: null, device_id: "ipad-e2e" } },
        { entity: "edge", base_version: null, data: { id: edge, source_id: id, target_id: other, kind: "manual", label: null, version: 0, created_at: now, deleted_at: null } },
      ],
    }) as unknown as { results: { status: string }[] };
    expect(ipad.results.map((r) => r.status)).toEqual(["created", "created", "created"]);

    const store = new MemoryStore();
    const pc = new SyncClient(store, transport, "pc-e2e");
    await pc.sync();
    expect(store.node(id)).toMatchObject({ title: "Derivata e2e", body_md: "Dall'iPad", version: 1 });
    expect(store.edge(edge)).toMatchObject({ source_id: id, target_id: other });

    new Repository(store, "pc-e2e").updateNode(id, { body_md: "Dall'iPad\n\nE dal PC" });
    expect(await pc.sync()).toMatchObject({ pushed: 1 });
    expect(store.node(id)?.version).toBe(2);

    // L'iPad riceve la versione 2 con il pull.
    const pulled = await transport.pull({ cursor: 0, limit: 1000 }) as unknown as { changes: { entity: string; data: { id: string; body_md?: string; version?: number } }[] };
    const latest = pulled.changes.filter((c) => c.entity === "node" && c.data.id === id).at(-1);
    expect(latest?.data).toMatchObject({ body_md: "Dall'iPad\n\nE dal PC", version: 2 });
  });
});
