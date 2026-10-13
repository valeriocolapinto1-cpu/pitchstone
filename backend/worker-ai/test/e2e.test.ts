// Test end-to-end: Worker → PostgREST → Postgres locale (supabase start).
// Gira solo se E2E_SUPABASE_URL, E2E_SUPABASE_SECRET_KEY e E2E_SUPABASE_ANON_KEY sono impostate.
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import worker, { type Env } from "../src/index";
import { resetCertsCache } from "../src/access";

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

    // Pulizia: nel cestino, poi eliminazione definitiva lato DB alla prossima purge.
    await post("/sync/push", {
      device_id: "ipad-a",
      changes: [{ entity: "node", base_version: 3, data: node("", { deleted_at: "2000-01-01T00:00:00Z" }) }],
    });
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
