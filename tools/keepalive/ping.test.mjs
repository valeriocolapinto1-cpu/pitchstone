import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { ping, pingUrl, TABLE } from "./ping.mjs";

const SUPABASE_URL = "https://progetto.supabase.co";

function fakeFetch(status, body) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url: new URL(url), init });
    return new Response(JSON.stringify(body), { status });
  };
  return { calls, fetchImpl };
}

test("il ping legge solo la tabella keepalive", async () => {
  const { calls, fetchImpl } = fakeFetch(200, []);
  await ping({ supabaseUrl: SUPABASE_URL, anonKey: "anon", fetchImpl });

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url.pathname, "/rest/v1/keepalive");
  assert.equal(calls[0].url.searchParams.get("select"), "id");
});

test("il ping usa solo la chiave pubblica", async () => {
  const { calls, fetchImpl } = fakeFetch(200, []);
  await ping({ supabaseUrl: SUPABASE_URL, anonKey: "anon", fetchImpl });

  assert.deepEqual(Object.keys(calls[0].init.headers).sort(), ["accept", "apikey"]);
  assert.equal(calls[0].init.headers.apikey, "anon");
});

test("lo script non contiene altre route REST né altre chiavi", async () => {
  const source = await readFile(new URL("./ping.mjs", import.meta.url), "utf8");
  assert.equal(TABLE, "keepalive");
  assert.deepEqual(source.match(/\/rest\/v1\/[^`"'\s]*/g), ["/rest/v1/${TABLE}"]);
  assert.doesNotMatch(source, /SERVICE_ROLE|service_role/);
});

test("il workflow passa solo URL e chiave pubblica allo script", async () => {
  const workflow = await readFile(
    new URL("../../.github/workflows/keepalive.yml", import.meta.url),
    "utf8",
  );
  const secrets = [...workflow.matchAll(/secrets\.(\w+)/g)].map((m) => m[1]).sort();
  assert.deepEqual(secrets, ["SUPABASE_ANON_KEY", "SUPABASE_URL"]);
  assert.match(workflow, /node tools\/keepalive\/ping\.mjs/);
  assert.doesNotMatch(workflow, /\/rest\/v1\//);
});

test("pingUrl mantiene l'host del progetto", () => {
  assert.equal(pingUrl(SUPABASE_URL).host, "progetto.supabase.co");
});

test("fallisce con stato diverso da 200", async () => {
  const { fetchImpl } = fakeFetch(404, { code: "PGRST205" });
  await assert.rejects(
    ping({ supabaseUrl: SUPABASE_URL, anonKey: "anon", fetchImpl }),
    /Supabase ha risposto 404/,
  );
});

test("fallisce se la risposta non è un array", async () => {
  const { fetchImpl } = fakeFetch(200, { ok: true });
  await assert.rejects(
    ping({ supabaseUrl: SUPABASE_URL, anonKey: "anon", fetchImpl }),
    /atteso un array JSON/,
  );
});

test("fallisce senza variabili d'ambiente", async () => {
  await assert.rejects(ping({ supabaseUrl: "", anonKey: "" }), /obbligatori/);
});
