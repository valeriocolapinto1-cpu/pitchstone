import { verifyAccessJwt } from "./access";
import { dailyBackup } from "./backup";
import { chat, DEFAULT_MODEL, validateChat } from "./chat";
import { emptyStorageTrash, signUrl, validateSign } from "./storage";
import { BadRequest, MAX_BODY_BYTES, rpc, validatePull, validatePush } from "./sync";

export interface Env {
  GEMINI_API_KEY: string;
  GEMINI_MODEL?: string;
  SUPABASE_URL: string;
  SUPABASE_SECRET_KEY: string;
  ACCESS_TEAM_DOMAIN: string;
  ACCESS_AUD: string;
}

async function readJson(request: Request): Promise<unknown> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw new BadRequest("body troppo grande");
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) throw new BadRequest("body troppo grande");
  try {
    return JSON.parse(text);
  } catch {
    throw new BadRequest("JSON non valido");
  }
}

/**
 * Difesa CSRF: la PWA è sulla stessa origine e il cookie di Access viaggia da solo.
 * Un form di un altro sito non può mandare `application/json` senza preflight, e un browser
 * moderno dichiara la provenienza in Sec-Fetch-Site. L'iPad (service token) non manda
 * Sec-Fetch-Site ma usa sempre JSON.
 */
function crossSite(request: Request): Response | null {
  const site = request.headers.get("sec-fetch-site");
  if (site !== null && site !== "same-origin" && site !== "none") {
    return Response.json({ error: "richiesta da un altro sito" }, { status: 403 });
  }
  const type = (request.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (type !== "application/json") {
    return Response.json({ error: "serve content-type application/json" }, { status: 415 });
  }
  return null;
}

export default {
  async fetch(request, env): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (request.method === "GET" && pathname === "/health") {
      return Response.json({ status: "ok" });
    }

    if (!["/sync/push", "/sync/pull", "/storage/sign", "/ai/chat"].includes(pathname)) {
      return new Response("Not Found", { status: 404 });
    }

    const authorized = await verifyAccessJwt(request.headers.get("cf-access-jwt-assertion"), {
      teamDomain: env.ACCESS_TEAM_DOMAIN,
      audience: env.ACCESS_AUD,
    });
    if (!authorized) return Response.json({ error: "non autorizzato" }, { status: 401 });

    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405, headers: { allow: "POST" } });
    }
    const rejected = crossSite(request);
    if (rejected) return rejected;
    if (pathname === "/ai/chat") {
      if (!env.GEMINI_API_KEY) return Response.json({ error: "Gemini non configurato" }, { status: 503 });
      try {
        return await chat(env.GEMINI_API_KEY, env.GEMINI_MODEL || DEFAULT_MODEL, validateChat(await readJson(request)));
      } catch (error) {
        if (error instanceof BadRequest) return Response.json({ error: error.message }, { status: 400 });
        throw error;
      }
    }
    if (!env.SUPABASE_URL || !env.SUPABASE_SECRET_KEY) {
      return Response.json({ error: "sync non configurata" }, { status: 503 });
    }
    const supabase = { url: env.SUPABASE_URL, secretKey: env.SUPABASE_SECRET_KEY };

    try {
      const body = await readJson(request);
      if (pathname === "/storage/sign") {
        const { action, path } = validateSign(body);
        return await signUrl(supabase, action, path);
      }
      if (pathname === "/sync/push") {
        const { deviceId, changes } = validatePush(body);
        return await rpc(supabase, "sync_push", { p_device_id: deviceId, p_changes: changes });
      }
      const { cursor, limit } = validatePull(body);
      return await rpc(supabase, "sync_pull", { p_cursor: cursor, p_limit: limit });
    } catch (error) {
      if (error instanceof BadRequest) {
        return Response.json({ error: error.message }, { status: 400 });
      }
      throw error;
    }
  },

  // Ogni giorno, dopo la pulizia del cestino nel database (03:00 UTC): file degli allegati
  // eliminati, poi il backup giornaliero.
  async scheduled(_controller, env, ctx): Promise<void> {
    if (!env.SUPABASE_URL || !env.SUPABASE_SECRET_KEY) return;
    const supabase = { url: env.SUPABASE_URL, secretKey: env.SUPABASE_SECRET_KEY };
    // Il backup parte anche se la pulizia fallisce.
    ctx.waitUntil(Promise.allSettled([emptyStorageTrash(supabase)]).then(() => dailyBackup(supabase)));
  },
} satisfies ExportedHandler<Env>;
