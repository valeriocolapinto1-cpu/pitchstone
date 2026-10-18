import { describe, expect, it } from "vitest";
import { validateChat } from "../src/chat";
import { validateSign } from "../src/storage";
import { BadRequest, PayloadTooLarge, validateErase, validateExport, validatePull, validatePush, validateRedact } from "../src/sync";

/** Generatore pseudocasuale con seme fisso: lo stesso fuzz a ogni esecuzione. */
function rng(seed: number) {
  let x = seed;
  return () => {
    x = (x * 1664525 + 1013904223) % 4294967296;
    return x / 4294967296;
  };
}

function value(random: () => number, depth = 0): unknown {
  const pick = Math.floor(random() * (depth > 2 ? 7 : 10));
  switch (pick) {
    case 0: return null;
    case 1: return undefined;
    case 2: return Math.floor(random() * 2000) - 1000;
    case 3: return random() < 0.5 ? NaN : Infinity;
    case 4: return ["", "x", "__proto__", "constructor", "../etc/passwd", "a".repeat(5000), "\u0000", "💥"][Math.floor(random() * 8)];
    case 5: return random() < 0.5;
    case 6: return { toString: 3 };
    case 7: return Array.from({ length: Math.floor(random() * 4) }, () => value(random, depth + 1));
    case 8: return Object.fromEntries(["id", "entity", "data", "base_version", "role", "text", "cursor", "limit", "device_id", "changes", "action", "path", "messages", "table", "after"]
      .filter(() => random() < 0.4).map((k) => [k, value(random, depth + 1)]));
    default: return JSON.parse('{"__proto__":{"polluted":true},"id":"x"}');
  }
}

const validators: [string, (body: unknown) => unknown][] = [
  ["validatePush", validatePush], ["validatePull", validatePull], ["validateSign", validateSign], ["validateChat", validateChat],
  ["validateRedact", validateRedact], ["validateExport", validateExport], ["validateErase", validateErase],
];

describe("fuzz dei validatori", () => {
  for (const [name, validate] of validators) {
    it(`${name}: accetta o rifiuta con un errore previsto, mai un'eccezione qualunque`, () => {
      const random = rng(name.length * 7919);
      for (let i = 0; i < 400; i++) {
        const body = value(random);
        try {
          validate(body);
        } catch (error) {
          expect(error instanceof BadRequest || error instanceof PayloadTooLarge, `${name}(${JSON.stringify(body)?.slice(0, 80)}): ${String(error)}`).toBe(true);
        }
      }
      expect(({} as { polluted?: boolean }).polluted).toBeUndefined();
    });
  }
});
