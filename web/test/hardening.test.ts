import { describe, expect, it } from "vitest";
import { nodeFromLink } from "../src/chat";
import { isSafeId, isUuid, markWikiLinks } from "../src/model";
import { MemoryStore } from "../src/store";
import { SyncClient, type Transport } from "../src/sync";

describe("id e link", () => {
  it("riconosce gli id sicuri e gli UUID", () => {
    expect(isSafeId("a1b2")).toBe(true);
    for (const bad of ["__proto__", "constructor", "prototype", "", "x".repeat(101), 3, null, undefined]) expect(isSafeId(bad)).toBe(false);
    expect(isUuid("3f2c1a9e-8b7d-4c6e-9a1b-0123456789ab")).toBe(true);
    expect(isUuid("n1")).toBe(false);
  });

  it("un link di citazione rotto non lancia e un id pericoloso non passa", () => {
    expect(nodeFromLink("#nodo/abc")).toBe("abc");
    expect(nodeFromLink("#nodo/%")).toBeUndefined();
    expect(nodeFromLink("#nodo/%E0%A4%A")).toBeUndefined();
    expect(nodeFromLink("#nodo/__proto__")).toBeUndefined();
    expect(nodeFromLink("https://example.com/x")).toBeUndefined();
  });

  it("la pull ignora record con id __proto__ e non inquina l'archivio", async () => {
    const store = new MemoryStore();
    const transport: Transport = {
      push: async () => ({ results: [] }),
      pull: async () => ({
        changes: [
          { entity: "node", data: JSON.parse('{"id":"__proto__","type":"note","area":"studio","title":"x","body_md":"","tags":[],"version":1,"updated_at":"2026-01-01T00:00:00Z"}') },
          { entity: "node", data: { id: "ok", type: "note", area: "studio", title: "Vero", body_md: "", tags: [], version: 1, updated_at: "2026-01-01T00:00:00Z" } },
        ],
        cursor: 2,
        has_more: false,
      }),
    } as unknown as Transport;
    await new SyncClient(store, transport, "pc").sync();
    expect(store.nodes().map((n) => n.id)).toEqual(["ok"]);
    expect(({} as { title?: string }).title).toBeUndefined();
  });
});

describe("wikilink nell'anteprima", () => {
  it("li segna nel testo ma non nel codice né nei blocchi", () => {
    const out = markWikiLinks("Vedi [[Limiti]] e `[[Codice]]`.\n\n```\n[[Blocco]]\n```\n\n[[A|testo]]");
    expect(out).toContain('data-title="Limiti"');
    expect(out).toContain('data-title="A"');
    expect(out).toContain("`[[Codice]]`");
    expect(out).toContain("[[Blocco]]");
    expect(out).not.toContain('data-title="Codice"');
    expect(out).not.toContain('data-title="Blocco"');
  });

  it("toglie dal titolo virgolette e parentesi angolari", () => {
    const out = markWikiLinks('[[a"><img src=x onerror=1>]]');
    expect(out).not.toContain("<img");
    expect(out).not.toContain('"><');
  });
});
