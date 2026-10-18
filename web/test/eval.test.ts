import { describe, expect, it } from "vitest";
import { search, stem, type Chunk, MAX_CHUNKS_PER_NODE } from "../src/chat";
import corpus from "./eval/corpus.json";
import queriesRaw from "./eval/queries.jsonl?raw";

const chunks = corpus as Chunk[];
const queries = queriesRaw.trim().split("\n").map((line) => JSON.parse(line) as { query: string; expected: string });

describe("set di valutazione del retrieval", () => {
  it("il frammento giusto è tra i primi 3 nel 90% delle domande e primo nei tre quarti", () => {
    let top3 = 0;
    let top1 = 0;
    const misses: string[] = [];
    for (const { query, expected } of queries) {
      const ids = search(query, chunks, 3).map((c) => c.nodeId);
      if (ids.includes(expected)) top3++;
      else misses.push(query);
      if (ids[0] === expected) top1++;
    }
    expect(misses).toEqual([]);
    expect(top3 / queries.length).toBeGreaterThanOrEqual(0.9);
    expect(top1 / queries.length).toBeGreaterThanOrEqual(0.75);
  });

  it("lo stemmer unisce le forme di una parola e non scende sotto le 3 lettere", () => {
    expect(stem("limiti")).toBe(stem("limite"));
    expect(stem("derivata")).toBe(stem("derivate"));
    expect(stem("sole").length).toBeGreaterThanOrEqual(3);
  });

  it("un nodo non riempie tutte le fonti", () => {
    const many: Chunk[] = Array.from({ length: 8 }, (_, i) => ({ id: `a|${i}`, nodeId: "a", title: "Derivate", text: `derivata ${i}` }));
    many.push({ id: "b|0", nodeId: "b", title: "Altro", text: "derivata in un altro nodo" });
    const result = search("derivata", many);
    expect(result.filter((c) => c.nodeId === "a")).toHaveLength(MAX_CHUNKS_PER_NODE);
    expect(result.some((c) => c.nodeId === "b")).toBe(true);
  });

  it("nessuna parola utile: nessuna fonte", () => {
    expect(search("cosa è", chunks)).toEqual([]);
  });
});
