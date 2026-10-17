import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { type Env } from "../src/index";
import { normalizeTeamDomain, resetCertsCache, verifyAccessJwt } from "../src/access";

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
  if (init.body !== undefined && !headers.has("content-type")) headers.set("content-type", "application/json");
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
    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain("dettaglio interno");
    spy.mockRestore();
  });

  it("distingue il rifiuto del database (502) dal guasto di Supabase (503), senza testo nei log", async () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    upstream.mockImplementation(async (input) => {
      const url = String(input);
      if (url.endsWith("/certs")) return Response.json({ keys: [{ ...jwk, kid: "k1" }] });
      return Response.json({ code: "23514", message: "violazione con il testo della nota segreta" }, { status: 400 });
    });
    expect((await post("/sync/push", { device_id: "ipad", changes: [] })).status).toBe(502);
    const logged = JSON.stringify(spy.mock.calls);
    expect(logged).toContain("400 23514");
    expect(logged).not.toContain("nota segreta");
    upstream.mockImplementation(async (input) => {
      if (String(input).endsWith("/certs")) return Response.json({ keys: [{ ...jwk, kid: "k1" }] });
      throw new TypeError("fetch failed");
    });
    const down = await post("/sync/push", { device_id: "ipad", changes: [] });
    expect(down.status).toBe(503);
    expect(down.headers.get("retry-after")).toBe("30");
    spy.mockRestore();
  });

  it("il pull ripete una volta un guasto transitorio, il push no", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    let calls = 0;
    upstream.mockImplementation(async (input) => {
      if (String(input).endsWith("/certs")) return Response.json({ keys: [{ ...jwk, kid: "k1" }] });
      return ++calls === 1 ? new Response("", { status: 503 }) : Response.json({ ok: true });
    });
    expect((await post("/sync/pull", { cursor: 0 })).status).toBe(200);
    expect(calls).toBe(2);
    calls = 0;
    expect((await post("/sync/push", { device_id: "ipad", changes: [] })).status).toBe(503);
    expect(calls).toBe(1);
  });

  it("firma le parti degli allegati solo con il token di Access", async () => {
    const path = "30000000-0000-4000-8000-0000000000a1/part-000";
    const unauthorized = await call("/storage/sign", { method: "POST", body: JSON.stringify({ action: "upload", path }) });
    expect(unauthorized.status).toBe(401);
    expect((await post("/storage/sign", { action: "upload", path: "../segreto" })).status).toBe(400);
  });

  it("difende dal CSRF senza bloccare l'iPad", async () => {
    const token = await sign(validPayload());
    const body = JSON.stringify({ cursor: 0 });
    // iPad: service token, JSON, niente Origin né Sec-Fetch-Site.
    expect((await call("/sync/pull", { method: "POST", body, token })).status).toBe(200);
    // PWA sulla stessa origine.
    const same = { "sec-fetch-site": "same-origin", "content-type": "application/json; charset=utf-8" };
    expect((await call("/sync/pull", { method: "POST", body, token, headers: same })).status).toBe(200);
    for (const site of ["cross-site", "same-site"]) {
      const headers = { "sec-fetch-site": site, "content-type": "application/json" };
      expect((await call("/sync/push", { method: "POST", body, token, headers })).status).toBe(403);
    }
    for (const type of ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data; boundary=x"]) {
      expect((await call("/sync/push", { method: "POST", body, token, headers: { "content-type": type } })).status).toBe(415);
    }
    const noType = new Request("https://ai-proxy.example/ai/chat", { method: "POST", headers: { "cf-access-jwt-assertion": token } });
    expect((await worker.fetch(noType as Request<unknown, IncomingRequestCfProperties>, env)).status).toBe(415);
    expect(rpcCalls()).toHaveLength(2);
  });

  it("restituisce 503 se Supabase non è configurato", async () => {
    const request = new Request("https://ai-proxy.example/sync/pull", {
      method: "POST",
      body: "{}",
      headers: { "cf-access-jwt-assertion": await sign(validPayload()), "content-type": "application/json" },
    });
    const response = await worker.fetch(
      request as Request<unknown, IncomingRequestCfProperties>,
      { ...env, SUPABASE_SECRET_KEY: "" },
    );
    expect(response.status).toBe(503);
  });
});

describe("chat", () => {
  const question = { system: "Sei un tutor.\n\nFONTI\n[1] Cellula", messages: [{ role: "user", text: "Cos'è?" }], maxOutputTokens: 500 };

  function gemini(response: Response) {
    upstream.mockImplementation(async (input) => {
      const url = String(input instanceof Request ? input.url : input);
      if (url === `${TEAM}/cdn-cgi/access/certs`) return Response.json({ keys: [{ ...jwk, kid: "k1" }] });
      if (url.startsWith("https://generativelanguage.googleapis.com/")) return response.clone();
      return new Response("unexpected", { status: 599 });
    });
  }

  function geminiCalls() {
    return upstream.mock.calls.filter(([input]) => String(input).startsWith("https://generativelanguage.googleapis.com/"));
  }

  it("richiede il token di Access", async () => {
    const response = await call("/ai/chat", { method: "POST", body: JSON.stringify(question) });
    expect(response.status).toBe(401);
    expect(geminiCalls()).toHaveLength(0);
  });

  it("chiama Gemini con la chiave del Worker e restituisce il testo", async () => {
    gemini(Response.json({ candidates: [{ content: { parts: [{ text: "Una cellula " }, { text: "[1]." }] } }] }));
    const response = await post("/ai/chat", {
      ...question,
      messages: [
        { role: "user", text: "Prima" },
        { role: "assistant", text: "Risposta" },
        { role: "user", text: "Cos'è?" },
      ],
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ text: "Una cellula [1]." });
    const [[url, init]] = geminiCalls();
    expect(String(url)).toContain("/models/gemini-2.5-flash:generateContent");
    expect(new Headers(init?.headers).get("x-goog-api-key")).toBe("x");
    const body = JSON.parse(String(init?.body));
    expect(body.systemInstruction.parts[0].text).toContain(question.system);
    expect(body.systemInstruction.parts[0].text).toContain("dati non fidati");
    expect(body.contents.map((c: { role: string }) => c.role)).toEqual(["user", "model", "user"]);
    expect(body.generationConfig.maxOutputTokens).toBe(500);
    expect(body.generationConfig.thinkingConfig).toEqual({ thinkingBudget: 0 });
  });

  it("usa il modello configurato", async () => {
    gemini(Response.json({ candidates: [{ content: { parts: [{ text: "ok" }] } }] }));
    const request = new Request("https://ai-proxy.example/ai/chat", {
      method: "POST",
      body: JSON.stringify(question),
      headers: { "cf-access-jwt-assertion": await sign(validPayload()), "content-type": "application/json" },
    });
    await worker.fetch(request as Request<unknown, IncomingRequestCfProperties>, { ...env, GEMINI_MODEL: "gemini-x" });
    expect(String(geminiCalls()[0][0])).toContain("/models/gemini-x:generateContent");
  });

  it("rifiuta richieste non valide prima di Gemini", async () => {
    const bad = [
      {},
      { ...question, messages: [] },
      { ...question, messages: [{ role: "system", text: "x" }] },
      { ...question, messages: [{ role: "assistant", text: "x" }] },
      { ...question, messages: [{ role: "user", text: "" }] },
      { ...question, maxOutputTokens: 100_000 },
      { ...question, system: "x".repeat(200_000) },
    ];
    for (const body of bad) expect((await post("/ai/chat", body)).status).toBe(400);
    expect(geminiCalls()).toHaveLength(0);
  });

  it("segnala il limite gratuito con 429 e nasconde gli altri errori", async () => {
    gemini(new Response("quota", { status: 429 }));
    expect((await post("/ai/chat", question)).status).toBe(429);
    gemini(new Response("dettagli interni con la richiesta", { status: 500 }));
    const failed = await post("/ai/chat", question);
    expect(failed.status).toBe(502);
    expect(JSON.stringify(await failed.json())).not.toContain("dettagli");
  });

  it("segnala una risposta troncata e gestisce gli errori di rete", async () => {
    gemini(Response.json({ candidates: [{ content: { parts: [{ text: "Inizio" }] }, finishReason: "MAX_TOKENS" }] }));
    expect(((await (await post("/ai/chat", question)).json()) as { text: string }).text).toContain("interrotta");
    gemini(new Response("non json", { status: 200 }));
    expect((await post("/ai/chat", question)).status).toBe(502);
  });

  it("tratta una risposta bloccata come errore", async () => {
    gemini(Response.json({ promptFeedback: { blockReason: "SAFETY" } }));
    const response = await post("/ai/chat", question);
    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "nessuna risposta (SAFETY)" });
  });

  it("restituisce 503 senza chiave Gemini", async () => {
    const request = new Request("https://ai-proxy.example/ai/chat", {
      method: "POST",
      body: JSON.stringify(question),
      headers: { "cf-access-jwt-assertion": await sign(validPayload()), "content-type": "application/json" },
    });
    const response = await worker.fetch(request as Request<unknown, IncomingRequestCfProperties>, { ...env, GEMINI_API_KEY: "" });
    expect(response.status).toBe(503);
  });
});

describe("normalizeTeamDomain", () => {
  it("aggiunge https:// e toglie la barra finale", () => {
    expect(normalizeTeamDomain("team.cloudflareaccess.com")).toBe("https://team.cloudflareaccess.com");
    expect(normalizeTeamDomain("https://team.cloudflareaccess.com/")).toBe("https://team.cloudflareaccess.com");
    expect(normalizeTeamDomain(" ")).toBe("");
  });
});

describe("Access: robustezza", () => {
  const config = { teamDomain: TEAM, audience: AUD };

  function certs(response: () => Response | Promise<Response>) {
    upstream.mockImplementation(async (input) => {
      if (String(input).endsWith("/certs")) return response();
      return Response.json({ ok: true });
    });
  }

  it("chiavi irraggiungibili: 503, non 401 e nessuna eccezione", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    certs(() => {
      throw new TypeError("rete");
    });
    const response = await post("/sync/pull", { cursor: 0 });
    expect(response.status).toBe(503);
    certs(() => new Response("", { status: 500 }));
    resetCertsCache();
    expect((await post("/sync/pull", { cursor: 0 })).status).toBe(503);
  });

  it("risposta di certs senza `keys` valide: non si usa", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    certs(() => Response.json({ keys: "no" }));
    expect((await post("/sync/pull", { cursor: 0 })).status).toBe(503);
    certs(() => Response.json({}));
    resetCertsCache();
    expect((await post("/sync/pull", { cursor: 0 })).status).toBe(503);
  });

  it("se Access non risponde si usano le ultime chiavi per un giorno, non oltre", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.useFakeTimers({ toFake: ["Date"] });
    try {
      expect(await verifyAccessJwt(await sign(validPayload()), config)).toBe(true);
      upstream.mockImplementation(async () => new Response("", { status: 500 }));
      vi.advanceTimersByTime(2 * 60 * 60 * 1000);
      const payload = { ...validPayload(), exp: Math.floor(Date.now() / 1000) + 600 };
      expect(await verifyAccessJwt(await sign(payload), config)).toBe(true);
      vi.advanceTimersByTime(25 * 60 * 60 * 1000);
      const later = { ...validPayload(), exp: Math.floor(Date.now() / 1000) + 600 };
      expect((await import("../src/access")).authenticate).toBeTypeOf("function");
      const result = await (await import("../src/access")).authenticate(await sign(later), config);
      expect(result).toEqual({ ok: false, reason: "unavailable" });
    } finally {
      vi.useRealTimers();
    }
  });

  it("un kid sconosciuto non rilancia richieste a ogni token", async () => {
    const forged = await sign(validPayload(), keys.privateKey, "falso");
    for (let i = 0; i < 4; i++) expect(await verifyAccessJwt(forged, config)).toBe(false);
    // Una sola richiesta: le chiavi appena scaricate non si riscaricano per lo stesso kid.
    expect(upstream.mock.calls.filter(([input]) => String(input).endsWith("/certs"))).toHaveLength(1);
  });

  it("controlla typ e iat, con tolleranza simmetrica sull'orologio", async () => {
    const now = Math.floor(Date.now() / 1000);
    expect(await verifyAccessJwt(await sign({ ...validPayload(), iat: now + 3600 }), config)).toBe(false);
    expect(await verifyAccessJwt(await sign({ ...validPayload(), iat: now - 10 }), config)).toBe(true);
    expect(await verifyAccessJwt(await sign({ ...validPayload(), exp: now - 30 }), config)).toBe(true);
    expect(await verifyAccessJwt(await sign({ ...validPayload(), exp: now - 120 }), config)).toBe(false);
    expect(await verifyAccessJwt(await sign({ ...validPayload(), nbf: now + 30 }), config)).toBe(true);
    expect(await verifyAccessJwt(await sign({ ...validPayload(), nbf: now + 120 }), config)).toBe(false);
    const head = b64url(JSON.stringify({ alg: "RS256", kid: "k1", typ: "at+jwt" }));
    const body = b64url(JSON.stringify(validPayload()));
    const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", keys.privateKey, new TextEncoder().encode(`${head}.${body}`));
    expect(await verifyAccessJwt(`${head}.${body}.${b64url(signature)}`, config)).toBe(false);
  });

  it("restituisce l'identità del token", async () => {
    const { authenticate } = await import("../src/access");
    const result = await authenticate(await sign({ ...validPayload(), email: "io@example.com", sub: "u1" }), config);
    expect(result).toEqual({ ok: true, identity: { email: "io@example.com", commonName: undefined, sub: "u1" } });
  });
});

describe("autorizzazione per identità", () => {
  async function as(claims: Record<string, unknown>, path: string, extra: Partial<Env> = {}) {
    const request = new Request(`https://ai-proxy.example${path}`, {
      method: "POST",
      body: JSON.stringify(path === "/ai/chat"
        ? { system: "s", messages: [{ role: "user", text: "q" }], maxOutputTokens: 10 }
        : { cursor: 0 }),
      headers: { "cf-access-jwt-assertion": await sign({ ...validPayload(), ...claims }), "content-type": "application/json" },
    });
    upstream.mockImplementation(async (input) => {
      const url = String(input);
      if (url.endsWith("/certs")) return Response.json({ keys: [{ ...jwk, kid: "k1" }] });
      if (url.startsWith("https://generativelanguage.googleapis.com/")) {
        return Response.json({ candidates: [{ content: { parts: [{ text: "ok" }] } }] });
      }
      return Response.json({ ok: true });
    });
    return worker.fetch(request as Request<unknown, IncomingRequestCfProperties>, { ...env, ...extra });
  }

  it("senza allowlist basta il token valido", async () => {
    expect((await as({ email: "chiunque@example.com" }, "/sync/pull")).status).toBe(200);
  });

  it("con l'allowlist delle email entra solo chi c'è, senza badare alle maiuscole", async () => {
    const extra = { ACCESS_ALLOWED_EMAILS: "Io@Example.com, altro@example.com" };
    expect((await as({ email: "io@example.com" }, "/sync/pull", extra)).status).toBe(200);
    expect((await as({ email: "estraneo@example.com" }, "/sync/pull", extra)).status).toBe(403);
    expect((await as({ common_name: "token-qualsiasi" }, "/sync/pull", extra)).status).toBe(403);
  });

  it("i service token sono separati: uno per iPad (/sync, /storage), uno per il PC (/ai)", async () => {
    const extra = { ACCESS_SYNC_TOKENS: "ipad.access", ACCESS_AI_TOKENS: "pc.access" };
    expect((await as({ common_name: "ipad.access" }, "/sync/pull", extra)).status).toBe(200);
    expect((await as({ common_name: "ipad.access" }, "/ai/chat", extra)).status).toBe(403);
    expect((await as({ common_name: "pc.access" }, "/ai/chat", extra)).status).toBe(200);
    expect((await as({ common_name: "pc.access" }, "/sync/pull", extra)).status).toBe(403);
  });

  it("registra l'identità nei log, senza il token", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    await as({ email: "io@example.com" }, "/sync/pull");
    expect(log).toHaveBeenCalledWith("/sync/pull io@example.com ok");
    log.mockRestore();
  });
});

describe("Worker: protezioni generali", () => {
  it("ogni risposta è no-store e nosniff", async () => {
    for (const response of [await call("/health"), await call("/altro"), await post("/sync/pull", { cursor: 0 })]) {
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    }
  });

  it("un errore imprevisto diventa JSON 500 con request_id, senza dettagli", async () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    const broken = { ...env };
    Object.defineProperty(broken, "SUPABASE_URL", {
      get() {
        throw new Error("dettaglio segreto");
      },
    });
    const request = new Request("https://ai-proxy.example/sync/pull", {
      method: "POST",
      body: "{}",
      headers: { "cf-access-jwt-assertion": await sign(validPayload()), "content-type": "application/json" },
    });
    const response = await worker.fetch(request as Request<unknown, IncomingRequestCfProperties>, broken);
    expect(response.status).toBe(500);
    const json = (await response.json()) as { error: string; request_id: string };
    expect(json.request_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(JSON.stringify(json)).not.toContain("segreto");
    expect(JSON.stringify(spy.mock.calls)).not.toContain("segreto");
    expect(JSON.stringify(spy.mock.calls)).toContain(json.request_id);
    spy.mockRestore();
  });

  it("controlla Origin e lo fa prima del token", async () => {
    const headers = { origin: "https://evil.example", "content-type": "application/json" };
    expect((await call("/sync/pull", { method: "POST", body: "{}", headers })).status).toBe(403);
    expect(upstream.mock.calls.filter(([input]) => String(input).endsWith("/certs"))).toHaveLength(0);
    const same = { origin: "https://ai-proxy.example", "content-type": "application/json" };
    expect((await call("/sync/pull", { method: "POST", body: JSON.stringify({ cursor: 0 }), headers: same, token: await sign(validPayload()) })).status).toBe(200);
  });

  it("413 per un body troppo grande, contato sui byte reali e senza Content-Length", async () => {
    const token = await sign(validPayload());
    const big = JSON.stringify({ device_id: "ipad", changes: [], pad: "è".repeat(3 * 1024 * 1024) });
    const declared = await call("/sync/push", { method: "POST", body: big, token });
    expect(declared.status).toBe(413);
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        const chunk = new TextEncoder().encode("x".repeat(1024 * 1024));
        for (let i = 0; i < 6; i++) controller.enqueue(chunk);
        controller.close();
      },
    });
    const request = new Request("https://ai-proxy.example/sync/push", {
      method: "POST",
      body: stream,
      duplex: "half",
      headers: { "cf-access-jwt-assertion": token, "content-type": "application/json" },
    } as RequestInit);
    const response = await worker.fetch(request as Request<unknown, IncomingRequestCfProperties>, env);
    expect(response.status).toBe(413);
    expect(rpcCalls()).toHaveLength(0);
  });

  it("limita le richieste alla chat per identità e passa Retry-After", async () => {
    const question = { system: "s", messages: [{ role: "user", text: "q" }], maxOutputTokens: 10 };
    const limit = vi.fn(async () => ({ success: false }));
    const request = new Request("https://ai-proxy.example/ai/chat", {
      method: "POST",
      body: JSON.stringify(question),
      headers: { "cf-access-jwt-assertion": await sign({ ...validPayload(), email: "io@example.com" }), "content-type": "application/json" },
    });
    const response = await worker.fetch(request as Request<unknown, IncomingRequestCfProperties>, { ...env, CHAT_LIMITER: { limit } });
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(limit).toHaveBeenCalledWith({ key: "io@example.com" });

    upstream.mockImplementation(async (input) => {
      if (String(input).endsWith("/certs")) return Response.json({ keys: [{ ...jwk, kid: "k1" }] });
      return new Response("quota", { status: 429, headers: { "retry-after": "17" } });
    });
    const quota = await post("/ai/chat", question);
    expect(quota.status).toBe(429);
    expect(quota.headers.get("retry-after")).toBe("17");
  });

  it("la chat ha un tetto sul testo totale e un timeout", async () => {
    const big = { system: "s".repeat(100_000), messages: [{ role: "user", text: "q".repeat(20_000) }, { role: "assistant", text: "a".repeat(20_000) }, { role: "user", text: "q".repeat(20_000) }], maxOutputTokens: 10 };
    expect((await post("/ai/chat", big)).status).toBe(400);
    let signal: AbortSignal | undefined;
    upstream.mockImplementation(async (input, init) => {
      if (String(input).endsWith("/certs")) return Response.json({ keys: [{ ...jwk, kid: "k1" }] });
      signal = init?.signal ?? undefined;
      return Response.json({ candidates: [{ content: { parts: [{ text: "ok" }] } }] });
    });
    await post("/ai/chat", { system: "s", messages: [{ role: "user", text: "q" }], maxOutputTokens: 10 });
    expect(signal).toBeInstanceOf(AbortSignal);
  });
});

describe("validatePush", () => {
  const push = (changes: unknown[], device_id = "ipad-1a2b") =>
    post("/sync/push", { device_id, changes });
  const node = { id: "a", type: "concept", area: "studio", title: "t" };

  it("device_id: solo [A-Za-z0-9._-], 1-64 caratteri", async () => {
    for (const bad of ["", "a b", "../x", "è", "a".repeat(65), "ipad/1"]) {
      expect((await push([], bad)).status).toBe(400);
    }
    for (const good of ["ipad-1a2b", "pc-1.2_3", "a".repeat(64)]) expect((await push([], good)).status).toBe(200);
  });

  it("entity solo node, edge, ink_page, attachment; data deve essere un oggetto", async () => {
    expect((await push([{ entity: "chat", data: node }])).status).toBe(400);
    expect((await push([{ data: node }])).status).toBe(400);
    expect((await push([{ entity: "node", data: "x" }])).status).toBe(400);
    expect((await push([{ entity: "node", data: [node] }])).status).toBe(400);
    expect((await push([{ entity: "node", data: null }])).status).toBe(400);
    for (const entity of ["node", "edge", "ink_page", "attachment"]) {
      expect((await push([{ entity, data: node }])).status).toBe(200);
    }
  });

  it("riconosce la salute anche con maiuscole, spazi e forme Unicode equivalenti", async () => {
    for (const data of [
      { ...node, type: "Health" }, { ...node, type: " health " }, { ...node, area: "SALUTE" },
      { ...node, area: "Salute\n" }, { ...node, area: "ｓａｌｕｔｅ" },
    ]) {
      expect((await push([{ entity: "node", data }])).status).toBe(400);
    }
    expect(rpcCalls()).toHaveLength(0);
  });

  it("tetti su title, tag e file_name", async () => {
    expect((await push([{ entity: "node", data: { ...node, title: "t".repeat(501) } }])).status).toBe(400);
    expect((await push([{ entity: "node", data: { ...node, title: 5 } }])).status).toBe(400);
    expect((await push([{ entity: "node", data: { ...node, tags: Array(51).fill("a") } }])).status).toBe(400);
    expect((await push([{ entity: "node", data: { ...node, tags: ["a".repeat(101)] } }])).status).toBe(400);
    expect((await push([{ entity: "node", data: { ...node, tags: [1] } }])).status).toBe(400);
    expect((await push([{ entity: "node", data: { ...node, tags: "x" } }])).status).toBe(400);
    expect((await push([{ entity: "attachment", data: { ...node, file_name: "f".repeat(256) } }])).status).toBe(400);
    expect((await push([{ entity: "node", data: { ...node, title: "t".repeat(500), tags: Array(50).fill("a".repeat(100)) } }])).status).toBe(200);
  });
});

describe("redact", () => {
  it("toglie una nota dal server chiamando redact_node_history", async () => {
    const id = "60000000-0000-4000-8000-000000000001";
    const response = await post("/sync/redact", { id: id.toUpperCase() });
    expect(response.status).toBe(200);
    const [[input, init]] = rpcCalls();
    expect(String(input)).toBe("https://db.example/rest/v1/rpc/redact_node_history");
    expect(JSON.parse(String(init?.body))).toEqual({ p_id: id });
  });

  it("rifiuta id non validi e richiede il token", async () => {
    expect((await post("/sync/redact", { id: "../x" })).status).toBe(400);
    expect((await post("/sync/redact", {})).status).toBe(400);
    expect((await call("/sync/redact", { method: "POST", body: "{}" })).status).toBe(401);
    expect(rpcCalls()).toHaveLength(0);
  });
});

describe("cron", () => {
  const controller = (cron: string) => ({ cron, scheduledTime: Date.parse("2026-10-17T04:30:00Z"), noRetry() {} }) as ScheduledController;

  function backendDown() {
    const hits: string[] = [];
    upstream.mockImplementation(async (input) => {
      const url = String(input);
      hits.push(url);
      if (url.startsWith("https://hc.example")) return new Response("ok");
      if (url.endsWith("/rpc/db_size_bytes")) return Response.json(1024);
      return new Response("giù", { status: 500 });
    });
    return hits;
  }

  it("senza Supabase non fa niente", async () => {
    await worker.scheduled?.(controller("30 4 * * *"), { ...env, SUPABASE_URL: "" });
    expect(upstream).not.toHaveBeenCalled();
  });

  it("avvisa con /fail se il backup non riesce", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const hits = backendDown();
    await worker.scheduled?.(controller("30 4 * * *"), { ...env, HEALTHCHECK_URL: "https://hc.example/abc" });
    expect(hits).toContain("https://hc.example/abc/fail");
    expect(hits).not.toContain("https://hc.example/abc");
  });

  it("il secondo cron rifà il backup solo se manca", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const hits = backendDown();
    await worker.scheduled?.(controller("30 10 * * *"), { ...env, HEALTHCHECK_URL: "https://hc.example/abc" });
    expect(hits.some((url) => url.endsWith("/rpc/backup_counts"))).toBe(true);
    expect(hits).toContain("https://hc.example/abc/fail");
  });
});

describe("account: esporta e cancella", () => {
  it("l'esportazione è a pagine, per tabella", async () => {
    const response = await post("/account/export", { table: "node_versions", after: "60000000-0000-4000-8000-000000000001" });
    expect(response.status).toBe(200);
    const [[input, init]] = rpcCalls();
    expect(String(input)).toBe("https://db.example/rest/v1/rpc/export_rows");
    expect(JSON.parse(String(init?.body))).toEqual({
      p_table: "node_versions", p_after: "60000000-0000-4000-8000-000000000001", p_limit: 500, p_max_bytes: 3000000,
    });
  });

  it("rifiuta tabelle e cursori non validi, e richiede il token", async () => {
    expect((await post("/account/export", { table: "chats" })).status).toBe(400);
    expect((await post("/account/export", { table: "nodes", after: "x" })).status).toBe(400);
    expect((await post("/account/export", {})).status).toBe(400);
    expect((await call("/account/export", { method: "POST", body: JSON.stringify({ table: "nodes" }) })).status).toBe(401);
    expect(rpcCalls()).toHaveLength(0);
  });

  it("cancellare tutto vuole la parola d'ordine e non tocca niente senza", async () => {
    expect((await post("/account/erase", {})).status).toBe(400);
    expect((await post("/account/erase", { confirm: "sì" })).status).toBe(400);
    expect(rpcCalls()).toHaveLength(0);
  });

  it("cancella il database, poi i file dei due bucket", async () => {
    const removed: string[] = [];
    upstream.mockImplementation(async (input, init) => {
      const url = String(input);
      if (url.endsWith("/certs")) return Response.json({ keys: [{ ...jwk, kid: "k1" }] });
      if (url.endsWith("/rpc/account_erase")) return Response.json({ nodes: 3, epoch: 2 });
      if (url.includes("/object/list/")) {
        const { prefix } = JSON.parse(String(init?.body)) as { prefix: string };
        return Response.json(prefix === "" ? [{ name: "uno", id: "f" }, { name: "dir", id: null }] : [{ name: "due", id: "f" }]);
      }
      if (init?.method === "DELETE") {
        removed.push(`${url.split("/").pop()}:${(JSON.parse(String(init.body)) as { prefixes: string[] }).prefixes.join(",")}`);
        return Response.json([]);
      }
      return new Response("inatteso", { status: 599 });
    });
    const response = await post("/account/erase", { confirm: "cancella-tutto" });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ database: true, nodes: 3, epoch: 2, storage: true });
    expect(removed).toEqual(["attachments:uno,dir/due", "backups:uno,dir/due"]);
  });

  it("se i file non si riescono a togliere lo dichiara", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    upstream.mockImplementation(async (input) => {
      const url = String(input);
      if (url.endsWith("/certs")) return Response.json({ keys: [{ ...jwk, kid: "k1" }] });
      if (url.endsWith("/rpc/account_erase")) return Response.json({ nodes: 0, epoch: 2 });
      return new Response("no", { status: 500 });
    });
    const response = await post("/account/erase", { confirm: "cancella-tutto" });
    expect(await response.json()).toMatchObject({ database: true, storage: false });
  });
});

describe("versione e configurazione", () => {
  it("risponde con la versione dell'API e rifiuta con 426 un client troppo vecchio", async () => {
    const ok = await post("/sync/pull", { cursor: 0 });
    expect(ok.headers.get("x-pitchstone-api")).toBe("1");
    expect(ok.status).toBe(200);
    const token = await sign(validPayload());
    const old = await call("/sync/pull", { method: "POST", body: JSON.stringify({ cursor: 0 }), token, headers: { "x-pitchstone-api": "0" } });
    expect(old.status).toBe(426);
    expect(old.headers.get("x-pitchstone-api")).toBe("1");
    expect(await old.json()).toMatchObject({ min_api: 1 });
    // Il controllo viene prima del database.
    expect(rpcCalls()).toHaveLength(1);
    const current = await call("/sync/pull", { method: "POST", body: JSON.stringify({ cursor: 0 }), token, headers: { "x-pitchstone-api": "1" } });
    expect(current.status).toBe(200);
  });

  it("GET /sync/config dà i limiti, ma solo con il token", async () => {
    expect((await call("/sync/config")).status).toBe(401);
    const token = await sign(validPayload());
    const response = await call("/sync/config", { token });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ api: 1, max_changes: 500, max_body_bytes: 5 * 1024 * 1024, max_pull_limit: 1000 });
    expect((await call("/sync/config", { token, headers: { "sec-fetch-site": "cross-site" } })).status).toBe(403);
    expect((await call("/sync/config", { method: "POST", body: "{}", token })).status).toBe(404);
  });
});
