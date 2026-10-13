import { describe, expect, it, vi } from "vitest";
import { emptyStorageTrash, signUrl, validateSign } from "../src/storage";
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
    const fetchImpl = vi.fn<typeof fetch>(async () =>
      Response.json({ url: `/object/upload/sign/attachments/${id}/part-000?token=abc` }),
    );
    const response = await signUrl(config, "upload", `${id}/part-000`, fetchImpl);
    expect(await response.json()).toEqual({
      url: `https://db.example/storage/v1/object/upload/sign/attachments/${id}/part-000?token=abc`,
      method: "PUT",
    });
    const [input, init] = fetchImpl.mock.calls[0];
    expect(String(input)).toBe(`https://db.example/storage/v1/object/upload/sign/attachments/${id}/part-000`);
    const headers = init?.headers as Record<string, string>;
    expect(headers.apikey).toBe("sb_secret_test");
    expect(headers["x-upsert"]).toBe("true");
    expect(headers.authorization).toBeUndefined();
  });

  it("scaricamento: URL firmato di breve durata", async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => Response.json({ signedURL: `/object/sign/attachments/${id}/part-001?token=t` }));
    const response = await signUrl(config, "download", `${id}/part-001`, fetchImpl);
    expect(await response.json()).toEqual({
      url: `https://db.example/storage/v1/object/sign/attachments/${id}/part-001?token=t`,
      method: "GET",
    });
    expect(JSON.parse(String(fetchImpl.mock.calls[0][1]?.body))).toEqual({ expiresIn: 300 });
  });

  it("file mancante: 404", async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => Response.json({ statusCode: "404", error: "not_found" }, { status: 400 }));
    expect((await signUrl(config, "download", `${id}/part-000`, fetchImpl)).status).toBe(404);
  });

  it("non espone gli errori dello storage", async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => new Response("dettaglio interno", { status: 400 }));
    vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await signUrl(config, "download", `${id}/part-000`, fetchImpl);
    expect(response.status).toBe(502);
    expect(await response.text()).not.toContain("dettaglio interno");
  });
});

describe("allegati: pulizia del bucket", () => {
  it("cancella tutte le parti in coda e conferma", async () => {
    const calls: { url: string; method?: string; body?: unknown }[] = [];
    const fetchImpl = vi.fn<typeof fetch>(async (input, init) => {
      const url = String(input);
      calls.push({ url, method: init?.method, body: init?.body ? JSON.parse(String(init.body)) : undefined });
      if (url.endsWith("/rpc/storage_trash_list")) return Response.json([{ path: id, part_count: 3 }]);
      if (url.endsWith("/rpc/storage_trash_done")) return Response.json(1);
      return Response.json([]);
    });
    expect(await emptyStorageTrash(config, fetchImpl)).toBe(1);
    const removal = calls.find((c) => c.method === "DELETE");
    expect(removal?.url).toBe("https://db.example/storage/v1/object/attachments");
    expect(removal?.body).toEqual({ prefixes: [`${id}/part-000`, `${id}/part-001`, `${id}/part-002`] });
    expect(calls.at(-1)?.body).toEqual({ p_paths: [id] });
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
  });
});
