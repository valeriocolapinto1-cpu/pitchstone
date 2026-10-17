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

/** Ore massime dall'ultimo backup riuscito prima di dare l'allarme. */
export const MAX_BACKUP_AGE_HOURS = 36;

// L'unica altra cosa che la chiave pubblica può leggere: da quante ore è stato fatto l'ultimo backup
// (nient'altro dei dati: la funzione restituisce solo data ed età).
export async function checkBackupAge({ supabaseUrl, anonKey, fetchImpl = fetch, maxHours = MAX_BACKUP_AGE_HOURS }) {
  const response = await fetchImpl(new URL("/rest/v1/rpc/backup_status", supabaseUrl), {
    method: "POST",
    headers: { apikey: anonKey, accept: "application/json", "content-type": "application/json" },
    body: "{}",
    signal: AbortSignal.timeout(30_000),
  });
  if (response.status !== 200) throw new Error(`backup_status ha risposto ${response.status}`);
  const status = await response.json();
  if (status?.age_hours === null || status?.age_hours === undefined) {
    throw new Error("nessun backup è mai stato completato");
  }
  if (status.age_hours > maxHours) {
    throw new Error(`l'ultimo backup ha ${status.age_hours} ore (massimo ${maxHours})`);
  }
  return status.age_hours;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    await ping({
      supabaseUrl: process.env.SUPABASE_URL,
      anonKey: process.env.SUPABASE_ANON_KEY,
    });
    console.log("Keep-alive riuscito");
    const hours = await checkBackupAge({
      supabaseUrl: process.env.SUPABASE_URL,
      anonKey: process.env.SUPABASE_ANON_KEY,
    });
    console.log(`Ultimo backup: ${hours} ore fa`);
  } catch (error) {
    console.error(`Keep-alive fallito: ${error.message}`);
    process.exitCode = 1;
  }
}
