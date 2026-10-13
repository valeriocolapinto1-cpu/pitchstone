// Ping leggero a Supabase per evitare la pausa del progetto gratuito.
// Usa solo la chiave pubblica e legge solo la tabella di servizio keepalive.
import { pathToFileURL } from "node:url";

export const TABLE = "keepalive";

export function pingUrl(supabaseUrl) {
  const url = new URL(`/rest/v1/${TABLE}`, supabaseUrl);
  url.searchParams.set("select", "id");
  url.searchParams.set("limit", "1");
  return url;
}

// Con RLS senza policy per anon la risposta valida è un array, anche vuoto.
export function assertValidResponse(status, body) {
  if (status !== 200) {
    throw new Error(`Supabase ha risposto ${status}: ${JSON.stringify(body)}`);
  }
  if (!Array.isArray(body)) {
    throw new Error(`Risposta non valida, atteso un array JSON: ${JSON.stringify(body)}`);
  }
}

export async function ping({ supabaseUrl, anonKey, fetchImpl = fetch }) {
  if (!supabaseUrl || !anonKey) {
    throw new Error("SUPABASE_URL e SUPABASE_ANON_KEY sono obbligatori");
  }
  const response = await fetchImpl(pingUrl(supabaseUrl), {
    headers: { apikey: anonKey, accept: "application/json" },
    signal: AbortSignal.timeout(30_000),
  });
  const text = await response.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    body = text;
  }
  assertValidResponse(response.status, body);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    await ping({
      supabaseUrl: process.env.SUPABASE_URL,
      anonKey: process.env.SUPABASE_ANON_KEY,
    });
    console.log("Keep-alive riuscito");
  } catch (error) {
    console.error(`Keep-alive fallito: ${error.message}`);
    process.exitCode = 1;
  }
}
