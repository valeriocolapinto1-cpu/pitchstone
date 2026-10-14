import { describe, expect, it, vi } from "vitest";
import { backupName, containsHealth, dailyBackup, expired } from "../src/backup";

const config = { url: "https://db.example", secretKey: "sb_secret_test" };
const now = new Date("2026-10-15T04:30:00Z");
const snapshot = { format: "pitchstone-backup", version: 1, nodes: [{ id: "n1", type: "concept", area: "studio" }], edges: [] };

function storage(snap: unknown, listed: string[] = []) {
  return vi.fn<typeof fetch>(async (input) => {
    const url = String(input);
    if (url.endsWith("/rpc/backup_snapshot")) return Response.json(snap);
    if (url.includes("/object/list/backups")) return Response.json(listed.map((name) => ({ name })));
    return Response.json({ ok: true });
  });
}

describe("backup giornaliero", () => {
  it("salva l'istantanea con la data e cancella i backup oltre 14 giorni", async () => {
    const fetchImpl = storage(snapshot, ["2026-09-30.json", "2026-10-01.json", "2026-10-14.json", "altro.txt"]);
    expect(await dailyBackup(config, now, fetchImpl)).toBe("saved");
    const calls = fetchImpl.mock.calls.map(([input, init]) => [String(input), init?.method, init?.body] as const);
    const upload = calls.find(([url]) => url.endsWith("/object/backups/2026-10-15.json"));
    expect(upload?.[1]).toBe("POST");
    expect(JSON.parse(String(upload?.[2]))).toEqual(snapshot);
    const removal = calls.find(([url, method]) => url.endsWith("/object/backups") && method === "DELETE");
    expect(JSON.parse(String(removal?.[2]))).toEqual({ prefixes: ["2026-09-30.json", "2026-10-01.json"] });
  });

  it("rifiuta un'istantanea con dati di salute", async () => {
    const fetchImpl = storage({ ...snapshot, nodes: [{ id: "x", type: "health", area: "salute" }] });
    expect(await dailyBackup(config, now, fetchImpl)).toBe("refused");
    expect(fetchImpl.mock.calls.some(([input]) => String(input).includes("/object/backups/"))).toBe(false);
  });

  it("non salva se il database non risponde", async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => new Response("errore", { status: 500 }));
    expect(await dailyBackup(config, now, fetchImpl)).toBe("failed");
  });

  it("filtro e nomi", () => {
    expect(containsHealth({ nodes: [{ area: "salute" }] })).toBe(true);
    expect(containsHealth({ nodes: [{ type: "concept", area: "studio" }] })).toBe(false);
    expect(backupName(now)).toBe("2026-10-15.json");
    expect(expired(["2026-10-01.json", "2026-10-02.json", "x.json"], now)).toEqual(["2026-10-01.json"]);
  });
});
