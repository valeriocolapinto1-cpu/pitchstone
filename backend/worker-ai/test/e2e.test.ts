// Test end-to-end: Worker → PostgREST → Postgres locale (supabase start).
// Gira solo se E2E_SUPABASE_URL, E2E_SUPABASE_SECRET_KEY e E2E_SUPABASE_ANON_KEY sono impostate.
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import worker, { type Env } from "../src/index";
import { resetCertsCache } from "../src/access";
import { dailyBackup } from "../src/backup";
import { emptyStorageTrash } from "../src/storage";

const url = process.env.E2E_SUPABASE_URL;
const secretKey = process.env.E2E_SUPABASE_SECRET_KEY;
const anonKey = process.env.E2E_SUPABASE_ANON_KEY;
const TEAM = "https://pitchstone.cloudflareaccess.com";

// In CI il test è obbligatorio: senza variabili deve fallire, non essere saltato.
if (process.env.E2E_REQUIRED && (!url || !secretKey || !anonKey)) {
  throw new Error("E2E_REQUIRED: mancano E2E_SUPABASE_URL, E2E_SUPABASE_SECRET_KEY o E2E_SUPABASE_ANON_KEY");
}
const AUD = "aud-e2e";

function b64url(data: ArrayBuffer | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

describe.skipIf(!url || !secretKey || !anonKey)("sync end-to-end", () => {
  const env: Env = {
    GEMINI_API_KEY: "x",
    SUPABASE_URL: url ?? "",
    SUPABASE_SECRET_KEY: secretKey ?? "",
    ACCESS_TEAM_DOMAIN: TEAM,
    ACCESS_AUD: AUD,
  };
  let token = "";
  const realFetch = globalThis.fetch;
  const id = crypto.randomUUID();

  beforeAll(async () => {
    const keys = (await crypto.subtle.generateKey(
      { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
      true,
      ["sign", "verify"],
    )) as CryptoKeyPair;
    const jwk = await crypto.subtle.exportKey("jwk", keys.publicKey);
    const head = b64url(JSON.stringify({ alg: "RS256", kid: "e2e" }));
    const body = b64url(JSON.stringify({ iss: TEAM, aud: [AUD], exp: Math.floor(Date.now() / 1000) + 600 }));
    const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", keys.privateKey, new TextEncoder().encode(`${head}.${body}`));
    token = `${head}.${body}.${b64url(signature)}`;

    // Solo le chiavi di Access sono simulate; Supabase è reale.
    resetCertsCache();
    vi.stubGlobal("fetch", (input: RequestInfo | URL, init?: RequestInit) =>
      String(input) === `${TEAM}/cdn-cgi/access/certs`
        ? Promise.resolve(Response.json({ keys: [{ ...jwk, kid: "e2e" }] }))
        : realFetch(input, init),
    );
  });

  afterAll(() => {
    vi.unstubAllGlobals();
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  async function post(path: string, body: unknown): Promise<any> {
    const request = new Request(`https://ai-proxy.example${path}`, {
      method: "POST",
      body: JSON.stringify(body),
      headers: { "cf-access-jwt-assertion": token },
    });
    const response = await worker.fetch(request as Request<unknown, IncomingRequestCfProperties>, env);
    expect(response.status).toBe(200);
    return response.json();
  }

  function node(body: string, extra: Record<string, unknown> = {}) {
    return { id, type: "concept", title: "E2E", body_md: body, area: "studio", tags: [], ...extra };
  }

  it("un nodo creato su A compare su B, i conflitti non perdono dati", async () => {
    const start = (await post("/sync/pull", { cursor: 0, limit: 1000 })) as { cursor: number };

    const created = await post("/sync/push", {
      device_id: "ipad-a",
      changes: [{ entity: "node", base_version: null, data: node("da A") }],
    });
    expect(created.results[0].status).toBe("created");

    const pulledByB = await post("/sync/pull", { cursor: start.cursor, limit: 1000 });
    const seen = pulledByB.changes.find((c: { entity: string; data: { id: string } }) => c.entity === "node" && c.data.id === id);
    expect(seen.data.body_md).toBe("da A");

    // A e B modificano entrambi la versione 1.
    await post("/sync/push", { device_id: "ipad-a", changes: [{ entity: "node", base_version: 1, data: node("A2") }] });
    const merged = await post("/sync/push", {
      device_id: "ipad-b",
      changes: [{ entity: "node", base_version: 1, data: node("B2") }],
    });
    expect(merged.results[0].status).toBe("merged");
    expect(merged.results[0].record.body_md).toContain("A2");
    expect(merged.results[0].record.body_md).toContain("B2");
    expect(merged.results[0].record.version).toBe(3);

    // Disegno: i byte vanno e tornano in base64 attraverso Worker e PostgREST.
    const pageID = crypto.randomUUID();
    const ink = btoa(String.fromCharCode(...Array.from({ length: 300 }, (_, i) => i % 256)));
    const pushedPage = await post("/sync/push", {
      device_id: "ipad-a",
      changes: [{ entity: "ink_page", base_version: null, data: { id: pageID, node_id: id, page_no: 0, background: "grid", ink_data: ink } }],
    });
    expect(pushedPage.results[0].status).toBe("created");
    const pulledPages = await post("/sync/pull", { cursor: start.cursor, limit: 1000 });
    const page = pulledPages.changes.find((c: { entity: string; data: { id: string } }) => c.entity === "ink_page" && c.data.id === pageID);
    expect(page.data.ink_data).toBe(ink);
    expect(page.data.background).toBe("grid");

    // Pulizia: nel cestino, poi eliminazione definitiva lato DB alla prossima purge.
    await post("/sync/push", {
      device_id: "ipad-a",
      changes: [{ entity: "node", base_version: 3, data: node("", { deleted_at: "2000-01-01T00:00:00Z" }) }],
    });
  });

  it("un allegato in due parti va e torna dal bucket privato, poi viene cancellato", async () => {
    const attachmentID = crypto.randomUUID();
    const parts = [new Uint8Array(70_000).map((_, i) => i % 251), new Uint8Array(1_000).fill(7)];
    for (const [i, bytes] of parts.entries()) {
      const path = `${attachmentID}/part-${String(i).padStart(3, "0")}`;
      const signed = await post("/storage/sign", { action: "upload", path });
      expect(signed.method).toBe("PUT");
      const put = await realFetch(signed.url, { method: "PUT", body: bytes, headers: { "content-type": "application/octet-stream" } });
      expect(put.ok).toBe(true);
    }
    // Il bucket è privato: senza URL firmato non si legge.
    const direct = await realFetch(`${url}/storage/v1/object/public/attachments/${attachmentID}/part-000`);
    expect(direct.ok).toBe(false);

    for (const [i, bytes] of parts.entries()) {
      const signed = await post("/storage/sign", { action: "download", path: `${attachmentID}/part-${String(i).padStart(3, "0")}` });
      const got = new Uint8Array(await (await realFetch(signed.url)).arrayBuffer());
      expect(got).toEqual(bytes);
    }

    // Riga dell'allegato, cestino scaduto, purge e pulizia del bucket.
    const hex = "ab".repeat(32);
    const pushed = await post("/sync/push", {
      device_id: "ipad-a",
      changes: [{ entity: "attachment", base_version: null, data: {
        id: attachmentID, node_id: null, kind: "pdf", storage_path: attachmentID, size_bytes: 71_000, sha256: hex,
        file_name: "prova.pdf", part_count: 2, deleted_at: "2000-01-01T00:00:00Z" } }],
    });
    expect(pushed.results[0].status).toBe("created");
    const rpcHeaders = { apikey: secretKey ?? "", "content-type": "application/json" };
    expect((await realFetch(`${url}/rest/v1/rpc/purge_trash`, { method: "POST", headers: rpcHeaders, body: "{}" })).ok).toBe(true);
    expect(await emptyStorageTrash({ url: url ?? "", secretKey: secretKey ?? "" }, fetch, "0 seconds")).toBeGreaterThanOrEqual(1);
    const gone = await worker.fetch(
      new Request("https://ai-proxy.example/storage/sign", {
        method: "POST",
        body: JSON.stringify({ action: "download", path: `${attachmentID}/part-000` }),
        headers: { "cf-access-jwt-assertion": token },
      }) as Request<unknown, IncomingRequestCfProperties>,
      env,
    );
    expect(gone.status).toBe(404);
  });

  it("il backup giornaliero finisce nel bucket privato, senza dati di salute", async () => {
    const config = { url: url ?? "", secretKey: secretKey ?? "" };
    const date = new Date("2030-01-15T04:30:00Z");
    // Senza scadenza: contro un progetto vero non cancella i backup veri.
    expect(await dailyBackup(config, date, fetch, { expire: false })).toBe("saved");
    const saved = await realFetch(`${url}/storage/v1/object/backups/2030-01-15.json`, {
      headers: { apikey: secretKey ?? "" },
    });
    expect(saved.ok).toBe(true);
    const snapshot = (await saved.json()) as { format: string; nodes: { type: string; area: string }[] };
    expect(snapshot.format).toBe("pitchstone-backup");
    expect(snapshot.nodes.some((node) => node.type === "health" || node.area === "salute")).toBe(false);
    const anonymous = await realFetch(`${url}/storage/v1/object/public/backups/2030-01-15.json`);
    expect(anonymous.ok).toBe(false);
  });

  it("la chiave pubblica non può chiamare la sync direttamente", async () => {
    const response = await realFetch(`${url}/rest/v1/rpc/sync_pull`, {
      method: "POST",
      headers: { apikey: anonKey ?? "", "content-type": "application/json" },
      body: JSON.stringify({ p_cursor: 0 }),
    });
    expect(response.ok).toBe(false);
  });
});
