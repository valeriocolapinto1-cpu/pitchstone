import { afterEach, describe, expect, it, vi } from "vitest";
import { describeFailure, describeStatus, fetchStatus, type ServerStatus } from "../src/status";
import { AuthError, HttpError, OutdatedError } from "../src/sync";

const ok: ServerStatus = { api: 1, gemini: true, database: true, last_backup_at: "2026-10-17T04:30:00Z", backup_age_hours: 5.4 };

afterEach(() => vi.unstubAllGlobals());

describe("stato della connessione", () => {
  it("tutto in ordine", () => {
    const lines = describeStatus(ok, new Date("2026-10-17T10:05:00"), 0);
    expect(lines.every((l) => l.ok)).toBe(true);
    expect(lines.find((l) => l.label === "Backup")?.text).toBe("Ultimo 5 ore fa");
  });

  it("segnala backup vecchio, database giù, Gemini spento e modifiche in attesa", () => {
    const lines = describeStatus({ ...ok, database: false, gemini: false, backup_age_hours: 80 }, undefined, 3);
    expect(lines.filter((l) => !l.ok).map((l) => l.label)).toEqual(["Database", "Gemini", "Backup", "Sincronizzazione"]);
    expect(lines.find((l) => l.label === "Backup")?.text).toBe("Ultimo 3 giorni fa");
    expect(lines.at(-1)?.text).toBe("Ancora nessuna, 3 modifiche in attesa");
  });

  it("nessun backup registrato", () => {
    expect(describeStatus({ ...ok, backup_age_hours: null, last_backup_at: null }, undefined, 0).find((l) => l.label === "Backup"))
      .toEqual({ label: "Backup", ok: false, text: "Nessun backup registrato" });
  });

  it("errori: sessione scaduta, versione vecchia, server, rete", () => {
    expect(describeFailure(new AuthError("x")).text).toContain("Sessione scaduta");
    expect(describeFailure(new OutdatedError()).label).toBe("App");
    expect(describeFailure(new HttpError(503)).text).toBe("Errore 503");
    expect(describeFailure(new TypeError("fetch")).label).toBe("Rete");
  });

  it("fetchStatus legge /status e riconosce il login scaduto", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => Response.json(ok)));
    expect(await fetchStatus()).toEqual(ok);
    vi.stubGlobal("fetch", vi.fn(async () => new Response("", { status: 401 })));
    await expect(fetchStatus()).rejects.toBeInstanceOf(AuthError);
  });
});
