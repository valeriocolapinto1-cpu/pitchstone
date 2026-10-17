import { describe, expect, it, vi } from "vitest";
import { emptyStorageTrash, removeOrphans, signUrl, validateSign } from "../src/storage";
import { BadRequest } from "../src/sync";

const config = { url: "https://db.example", secretKey: "sb_secret_test" };
const id = "30000000-0000-4000-8000-0000000000a1";

describe("allegati: URL firmati", () => {
  it("accetta solo parti di un allegato", () => {
    expect(validateSign({ action: "upload", path: `${id}/part-000` })).toEqual({ action: "upload", path: `${id}/part-000` });
    for (const path of [`${id}/part-100`, `${id}/../x`, `${id}`, `altro/${id}/part-000`, "x/part-000", `${id}/part-1`]) {
      expect(() => validateSign({ action: "download", path })).toThrow(BadRequest);
    }
    expect(() => validateSign({ action: "delete", path: `${id}/part-000` })).toThrow(BadRequest);
    expect(() => validateSign(null)).toThrow(BadRequest);
  });

  it("caricamento: URL firmato con upsert, chiave segreta solo verso Supabase", async () => {
    const fetchImpl = vi.fn<typeof fetch>(async (input) =>
      String(input).endsWith("/rpc/attachment_upload_allowed")
        ? Response.json(true)
        : Response.json({ url: `/object/upload/sign/attachments/${id}/part-000?token=abc` }),
    );
    const response = await signUrl(config, "upload", `${id}/part-000`, fetchImpl);
    expect(await response.json()).toEqual({
      url: `https://db.example/storage/v1/object/upload/sign/attachments/${id}/part-000?token=abc`,
      method: "PUT",
    });
    const [input, init] = fetchImpl.mock.calls[1];
    expect(String(input)).toBe(`https://db.example/storage/v1/object/upload/sign/attachments/${id}/part-000`);
    const headers = init?.headers as Record<string, string>;
    expect(headers.apikey).toBe("sb_secret_test");
    expect(headers["x-upsert"]).toBe("true");
    expect(headers.authorization).toBeUndefined();
  });

  it("caricamento rifiutato per un allegato che ha già la sua riga", async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => Response.json(false));
    const response = await signUrl(config, "upload", `${id}/part-000`, fetchImpl);
    expect(response.status).toBe(409);
    expect(fetchImpl.mock.calls.some(([input]) => String(input).includes("/storage/"))).toBe(false);
  });

  it("scaricamento: URL firmato di breve durata", async () => {
    const fetchImpl = vi.fn<typeof fetch>(async (input) =>
      String(input).endsWith("/rpc/attachment_download_allowed")
        ? Response.json(true)
        : Response.json({ signedURL: `/object/sign/attachments/${id}/part-001?token=t` }),
    );
    const response = await signUrl(config, "download", `${id}/part-001`, fetchImpl);
    expect(await response.json()).toEqual({
      url: `https://db.example/storage/v1/object/sign/attachments/${id}/part-001?token=t`,
      method: "GET",
    });
    expect(JSON.parse(String(fetchImpl.mock.calls[1][1]?.body))).toEqual({ expiresIn: 300 });
  });

  it("file mancante: 404", async () => {
    const fetchImpl = vi.fn<typeof fetch>(async (input) =>
      String(input).endsWith("/rpc/attachment_download_allowed")
        ? Response.json(true)
        : Response.json({ statusCode: "404", error: "not_found" }, { status: 400 }),
    );
    expect((await signUrl(config, "download", `${id}/part-000`, fetchImpl)).status).toBe(404);
  });

  it("scaricamento rifiutato senza riga o con la riga nel cestino, senza toccare lo storage", async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => Response.json(false));
    expect((await signUrl(config, "download", `${id}/part-000`, fetchImpl)).status).toBe(404);
    expect(fetchImpl.mock.calls.some(([input]) => String(input).includes("/storage/"))).toBe(false);
  });

  it("Supabase irraggiungibile: 503, non 502", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const fetchImpl = vi.fn<typeof fetch>(async () => {
      throw new TypeError("rete");
    });
    expect((await signUrl(config, "download", `${id}/part-000`, fetchImpl)).status).toBe(503);
  });

  it("non espone gli errori dello storage", async () => {
    const fetchImpl = vi.fn<typeof fetch>(async (input) =>
      String(input).endsWith("/rpc/attachment_download_allowed") ? Response.json(true) : new Response("dettaglio interno", { status: 400 }),
    );
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await signUrl(config, "download", `${id}/part-000`, fetchImpl);
    expect(response.status).toBe(502);
    expect(await response.text()).not.toContain("dettaglio interno");
    // Nei log né il corpo dell'errore né il percorso del file.
    expect(JSON.stringify(spy.mock.calls)).not.toContain("dettaglio interno");
    expect(JSON.stringify(spy.mock.calls)).not.toContain(id);
  });
});

describe("allegati: pulizia del bucket", () => {
  it("cancella tutte le parti in coda e conferma", async () => {
    const calls: { url: string; method?: string; body?: unknown }[] = [];
    const fetchImpl = vi.fn<typeof fetch>(async (input, init) => {
      const url = String(input);
      calls.push({ url, method: init?.method, body: init?.body ? JSON.parse(String(init.body)) : undefined });
      if (url.endsWith("/rpc/storage_trash_list")) return Response.json(calls.length === 1 ? [{ path: id, part_count: 3 }] : []);
      if (url.endsWith("/rpc/storage_trash_done")) return Response.json(1);
      return Response.json([]);
    });
    expect(await emptyStorageTrash(config, fetchImpl)).toBe(1);
    const removal = calls.find((c) => c.method === "DELETE");
    expect(removal?.url).toBe("https://db.example/storage/v1/object/attachments");
    expect(removal?.body).toEqual({ prefixes: [`${id}/part-000`, `${id}/part-001`, `${id}/part-002`] });
    expect(calls.find((c) => c.url.endsWith("/rpc/storage_trash_done"))?.body).toEqual({ p_paths: [id] });
  });

  it("ripete finché la coda è vuota", async () => {
    let batches = 3;
    const fetchImpl = vi.fn<typeof fetch>(async (input) => {
      const url = String(input);
      if (url.endsWith("/rpc/storage_trash_list")) return Response.json(batches-- > 0 ? [{ path: id, part_count: 1 }] : []);
      return Response.json(1);
    });
    expect(await emptyStorageTrash(config, fetchImpl)).toBe(3);
  });

  it("se la cancellazione fallisce la coda resta", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const fetchImpl = vi.fn<typeof fetch>(async (input) =>
      String(input).endsWith("/rpc/storage_trash_list")
        ? Response.json([{ path: id, part_count: 1 }])
        : new Response("no", { status: 500 }),
    );
    expect(await emptyStorageTrash(config, fetchImpl)).toBe(0);
    expect(fetchImpl.mock.calls.some(([input]) => String(input).endsWith("/rpc/storage_trash_done"))).toBe(false);
    // Ogni giro fallito conta un tentativo, e dopo 20 giri si smette.
    const failed = fetchImpl.mock.calls.filter(([input]) => String(input).endsWith("/rpc/storage_trash_failed"));
    expect(failed).toHaveLength(20);
    expect(JSON.parse(String(failed[0][1]?.body))).toEqual({ p_paths: [id] });
  });
});

describe("allegati: file orfani", () => {
  const orphan = "40000000-0000-4000-8000-0000000000b1";
  const now = new Date("2026-10-17T12:00:00Z");

  function bucket(createdAt: string | null) {
    return vi.fn<typeof fetch>(async (input, init) => {
      const url = String(input);
      if (url.endsWith("/rpc/attachments_without_row")) return Response.json([orphan]);
      if (url.includes("/object/list/attachments")) {
        const { prefix } = JSON.parse(String(init?.body)) as { prefix: string };
        return Response.json(prefix === "" ? [{ name: orphan, id: null }, { name: "altro", id: null }] : [{ name: "part-000", id: "x", created_at: createdAt }]);
      }
      return Response.json([]);
    });
  }

  it("cancella i file senza riga dopo 24 ore", async () => {
    const fetchImpl = bucket("2026-10-15T00:00:00Z");
    expect(await removeOrphans(config, now, fetchImpl)).toBe(1);
    const asked = fetchImpl.mock.calls.find(([input]) => String(input).endsWith("/rpc/attachments_without_row"));
    expect(JSON.parse(String(asked?.[1]?.body))).toEqual({ p_ids: [orphan] });
    const removal = fetchImpl.mock.calls.find(([, init]) => init?.method === "DELETE");
    expect(JSON.parse(String(removal?.[1]?.body))).toEqual({ prefixes: [`${orphan}/part-000`] });
  });

  it("non tocca i caricamenti recenti", async () => {
    const fetchImpl = bucket("2026-10-17T10:00:00Z");
    expect(await removeOrphans(config, now, fetchImpl)).toBe(0);
    expect(fetchImpl.mock.calls.some(([, init]) => init?.method === "DELETE")).toBe(false);
  });

  it("senza data di creazione non cancella per prudenza", async () => {
    expect(await removeOrphans(config, now, bucket(null))).toBe(0);
  });
});
