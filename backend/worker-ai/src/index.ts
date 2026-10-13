import { verifyAccessJwt } from "./access";
import { emptyStorageTrash, signUrl, validateSign } from "./storage";
import { BadRequest, MAX_BODY_BYTES, rpc, validatePull, validatePush } from "./sync";

export interface Env {
  GEMINI_API_KEY: string;
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

export default {
  async fetch(request, env): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (request.method === "GET" && pathname === "/health") {
      return Response.json({ status: "ok" });
    }

    if (pathname !== "/sync/push" && pathname !== "/sync/pull" && pathname !== "/storage/sign") {
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

  // Ogni giorno, dopo la pulizia del cestino nel database (03:00 UTC): file degli allegati eliminati.
  async scheduled(_controller, env, ctx): Promise<void> {
    if (!env.SUPABASE_URL || !env.SUPABASE_SECRET_KEY) return;
    ctx.waitUntil(emptyStorageTrash({ url: env.SUPABASE_URL, secretKey: env.SUPABASE_SECRET_KEY }));
  },
} satisfies ExportedHandler<Env>;
