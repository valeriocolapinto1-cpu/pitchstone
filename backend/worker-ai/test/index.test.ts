import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { type Env } from "../src/index";
import { resetCertsCache, verifyAccessJwt } from "../src/access";

const TEAM = "https://pitchstone.cloudflareaccess.com";
const AUD = "aud-test";
const env: Env = {
  GEMINI_API_KEY: "x",
  SUPABASE_URL: "https://db.example",
  SUPABASE_SECRET_KEY: "sb_secret_test",
  ACCESS_TEAM_DOMAIN: TEAM,
  ACCESS_AUD: AUD,
};

let keys: CryptoKeyPair;
let otherKeys: CryptoKeyPair;
let jwk: JsonWebKey;

function b64url(data: ArrayBuffer | Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sign(payload: Record<string, unknown>, key = keys.privateKey, kid = "k1"): Promise<string> {
  const head = b64url(JSON.stringify({ alg: "RS256", kid }));
  const body = b64url(JSON.stringify(payload));
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${head}.${body}`));
  return `${head}.${body}.${b64url(signature)}`;
}

function validPayload(): Record<string, unknown> {
  return { iss: TEAM, aud: [AUD], exp: Math.floor(Date.now() / 1000) + 600 };
}

beforeAll(async () => {
  const params = { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" };
  keys = (await crypto.subtle.generateKey(params, true, ["sign", "verify"])) as CryptoKeyPair;
  otherKeys = (await crypto.subtle.generateKey(params, true, ["sign", "verify"])) as CryptoKeyPair;
  jwk = (await crypto.subtle.exportKey("jwk", keys.publicKey)) as JsonWebKey;
});

const upstream = vi.fn<typeof fetch>();

beforeEach(() => {
  resetCertsCache();
  upstream.mockReset();
  upstream.mockImplementation(async (input) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url === `${TEAM}/cdn-cgi/access/certs`) return Response.json({ keys: [{ ...jwk, kid: "k1" }] });
    if (url.startsWith("https://db.example/rest/v1/rpc/")) return Response.json({ ok: true, url });
    return new Response("unexpected", { status: 599 });
  });
  vi.stubGlobal("fetch", upstream);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

async function call(path: string, init: RequestInit & { token?: string | null } = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("cf-access-jwt-assertion", init.token);
  const request = new Request(`https://ai-proxy.example${path}`, { ...init, headers });
  return worker.fetch(request as Request<unknown, IncomingRequestCfProperties>, env);
}

async function post(path: string, body: unknown): Promise<Response> {
  return call(path, { method: "POST", body: JSON.stringify(body), token: await sign(validPayload()) });
}

function rpcCalls() {
  return upstream.mock.calls.filter(([input]) => String(input).includes("/rest/v1/rpc/"));
}

describe("ai-proxy", () => {
  it("risponde 200 su /health senza autenticazione", async () => {
    const response = await call("/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok" });
  });

  it("risponde 404 sulle altre route", async () => {
    expect((await call("/")).status).toBe(404);
    expect((await call("/health", { method: "POST" })).status).toBe(404);
  });
});

describe("verifica di Cloudflare Access", () => {
  const config = { teamDomain: TEAM, audience: AUD };

  it("accetta un token valido", async () => {
    expect(await verifyAccessJwt(await sign(validPayload()), config)).toBe(true);
  });

  it("rifiuta token assente, malformato o con alg diverso", async () => {
    expect(await verifyAccessJwt(null, config)).toBe(false);
    expect(await verifyAccessJwt("a.b", config)).toBe(false);
    const none = `${b64url(JSON.stringify({ alg: "none", kid: "k1" }))}.${b64url(JSON.stringify(validPayload()))}.`;
    expect(await verifyAccessJwt(none, config)).toBe(false);
  });

  it("rifiuta firma di un'altra chiave", async () => {
    expect(await verifyAccessJwt(await sign(validPayload(), otherKeys.privateKey), config)).toBe(false);
  });

  it("rifiuta audience, issuer o scadenza sbagliati", async () => {
    expect(await verifyAccessJwt(await sign({ ...validPayload(), aud: ["altra"] }), config)).toBe(false);
    expect(await verifyAccessJwt(await sign({ ...validPayload(), iss: "https://evil.example" }), config)).toBe(false);
    expect(await verifyAccessJwt(await sign({ ...validPayload(), exp: 1 }), config)).toBe(false);
  });

  it("rifiuta tutto se la configurazione manca", async () => {
    expect(await verifyAccessJwt(await sign(validPayload()), { teamDomain: TEAM, audience: "" })).toBe(false);
  });

  it("ricarica le chiavi per un kid sconosciuto, al massimo una volta al minuto", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    try {
      expect(await verifyAccessJwt(await sign(validPayload()), config)).toBe(true);
      vi.advanceTimersByTime(2 * 60 * 1000);
      for (let i = 0; i < 3; i++) {
        expect(await verifyAccessJwt(await sign(validPayload(), keys.privateKey, "k2"), config)).toBe(false);
      }
      const certCalls = upstream.mock.calls.filter(([input]) => String(input).endsWith("/certs"));
      expect(certCalls).toHaveLength(2);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("sync", () => {
  it("richiede il token di Access", async () => {
    const response = await call("/sync/pull", { method: "POST", body: "{}" });
    expect(response.status).toBe(401);
    expect(rpcCalls()).toHaveLength(0);
  });

  it("accetta solo POST", async () => {
    const response = await call("/sync/pull", { token: await sign(validPayload()) });
    expect(response.status).toBe(405);
  });

  it("inoltra il push a sync_push con la chiave segreta", async () => {
    const changes = [{ entity: "node", base_version: null, data: { id: "a", type: "concept", area: "studio" } }];
    const response = await post("/sync/push", { device_id: "ipad", changes });
    expect(response.status).toBe(200);
    const [[input, init]] = rpcCalls();
    expect(String(input)).toBe("https://db.example/rest/v1/rpc/sync_push");
    const headers = new Headers(init?.headers);
    expect(headers.get("apikey")).toBe("sb_secret_test");
    expect(headers.get("authorization")).toBeNull();
    expect(JSON.parse(String(init?.body))).toEqual({ p_device_id: "ipad", p_changes: changes });
  });

  it("inoltra il pull a sync_pull", async () => {
    const response = await post("/sync/pull", { cursor: 42, limit: 10 });
    expect(response.status).toBe(200);
    const [[input, init]] = rpcCalls();
    expect(String(input)).toBe("https://db.example/rest/v1/rpc/sync_pull");
    expect(JSON.parse(String(init?.body))).toEqual({ p_cursor: 42, p_limit: 10 });
  });

  it("rifiuta i dati di salute prima del database", async () => {
    for (const data of [{ id: "a", type: "health", area: "studio" }, { id: "a", type: "concept", area: "salute" }]) {
      const response = await post("/sync/push", { device_id: "ipad", changes: [{ entity: "node", data }] });
      expect(response.status).toBe(400);
    }
    expect(rpcCalls()).toHaveLength(0);
  });

  it("rifiuta body non validi", async () => {
    expect((await post("/sync/push", { changes: [] })).status).toBe(400);
    expect((await post("/sync/push", { device_id: "ipad", changes: "x" })).status).toBe(400);
    expect((await post("/sync/push", { device_id: "ipad", changes: Array(501).fill({}) })).status).toBe(400);
    expect((await post("/sync/pull", { cursor: -1 })).status).toBe(400);
    expect((await post("/sync/pull", { cursor: 0, limit: 5000 })).status).toBe(400);
    const raw = await call("/sync/pull", { method: "POST", body: "{", token: await sign(validPayload()) });
    expect(raw.status).toBe(400);
    expect(rpcCalls()).toHaveLength(0);
  });

  it("non espone gli errori del database", async () => {
    upstream.mockImplementation(async (input) => {
      const url = String(input);
      if (url.endsWith("/certs")) return Response.json({ keys: [{ ...jwk, kid: "k1" }] });
      return new Response("dettaglio interno", { status: 500 });
    });
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await post("/sync/pull", { cursor: 0 });
    expect(response.status).toBe(502);
    expect(await response.text()).not.toContain("dettaglio interno");
    spy.mockRestore();
  });

  it("firma le parti degli allegati solo con il token di Access", async () => {
    const path = "30000000-0000-4000-8000-0000000000a1/part-000";
    const unauthorized = await call("/storage/sign", { method: "POST", body: JSON.stringify({ action: "upload", path }) });
    expect(unauthorized.status).toBe(401);
    expect((await post("/storage/sign", { action: "upload", path: "../segreto" })).status).toBe(400);
  });

  it("restituisce 503 se Supabase non è configurato", async () => {
    const request = new Request("https://ai-proxy.example/sync/pull", {
      method: "POST",
      body: "{}",
      headers: { "cf-access-jwt-assertion": await sign(validPayload()) },
    });
    const response = await worker.fetch(
      request as Request<unknown, IncomingRequestCfProperties>,
      { ...env, SUPABASE_SECRET_KEY: "" },
    );
    expect(response.status).toBe(503);
  });
});
