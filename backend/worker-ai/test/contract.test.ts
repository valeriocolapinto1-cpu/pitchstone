// Il contratto condiviso (../../contract): schemi e esempi usati anche dall'iPad e dalla PWA.
import Ajv from "ajv/dist/2020";
import { describe, expect, it } from "vitest";
import pullRequestSchema from "../../../contract/schema/pull-request.json";
import pullResponseFixture from "../../../contract/fixtures/pull-response.json";
import pullResponseSchema from "../../../contract/schema/pull-response.json";
import pushRequestFixture from "../../../contract/fixtures/push-request.json";
import pushRequestSchema from "../../../contract/schema/push-request.json";
import pushResponseFixture from "../../../contract/fixtures/push-response.json";
import pushResponseSchema from "../../../contract/schema/push-response.json";
import { API_VERSION, apiVersionCheck, limits, MAX_CHANGES, validatePull, validatePush } from "../src/sync";

const files: Record<string, unknown> = {
  "schema/push-request.json": pushRequestSchema,
  "schema/push-response.json": pushResponseSchema,
  "schema/pull-request.json": pullRequestSchema,
  "schema/pull-response.json": pullResponseSchema,
  "fixtures/push-request.json": pushRequestFixture,
  "fixtures/push-response.json": pushResponseFixture,
  "fixtures/pull-response.json": pullResponseFixture,
};
// Una copia: i test non devono toccare gli esempi condivisi.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const read = (path: string): any => structuredClone(files[path]);
const ajv = new Ajv({ strict: false });

describe("contratto: schemi e esempi", () => {
  it.each([
    ["push-request"], ["push-response"], ["pull-response"],
  ])("l'esempio %s rispetta il suo schema", (name) => {
    const validate = ajv.compile(read(`schema/${name}.json`));
    expect(validate(read(`fixtures/${name}.json`)), JSON.stringify(validate.errors)).toBe(true);
  });

  it("gli schemi rifiutano ciò che il server non accetta", () => {
    const push = ajv.compile(read("schema/push-request.json"));
    const request = read("fixtures/push-request.json");
    expect(push({ ...request, device_id: "../x" })).toBe(false);
    expect(push({ ...request, changes: Array(MAX_CHANGES + 1).fill(request.changes[0]) })).toBe(false);
    expect(push({ ...request, changes: [{ entity: "chat", base_version: null, data: { id: "x" } }] })).toBe(false);
    const response = ajv.compile(read("schema/push-response.json"));
    expect(response({ results: [{ entity: "node", status: "rejected", error: "23514", message: "check constraint violated" }] })).toBe(false);
    expect(response({ results: [{ entity: "node", status: "created" }] })).toBe(false);
  });

  it("le entità dell'esempio di pull hanno i campi richiesti dallo schema", () => {
    const schema = read("schema/pull-response.json");
    const response = read("fixtures/pull-response.json");
    for (const change of response.changes as { entity: string; data: Record<string, unknown> }[]) {
      const definition = schema.$defs[change.entity];
      if (!definition) continue;
      for (const key of definition.required as string[]) {
        if (change.entity === "purged" && key !== "entity" && key !== "id") continue;
        expect(change.data, `${change.entity}.${key}`).toHaveProperty(key);
      }
    }
  });

  it("il Worker accetta la richiesta di esempio e i suoi limiti coincidono con lo schema", () => {
    const request = read("fixtures/push-request.json");
    expect(validatePush(request).changes).toHaveLength(request.changes.length);
    expect(validatePull({ cursor: 0, limit: 1000 })).toEqual({ cursor: 0, limit: 1000 });
    expect(() => validatePull({ cursor: 0, limit: 1001 })).toThrow();
    const schema = read("schema/push-request.json");
    expect(schema.properties.changes.maxItems).toBe(MAX_CHANGES);
    expect(read("schema/pull-request.json").properties.limit.maximum).toBe(limits().max_pull_limit);
  });
});

describe("versione dell'API", () => {
  it("senza intestazione (client precedenti) o con una versione valida passa", () => {
    expect(apiVersionCheck(null)).toBeNull();
    expect(apiVersionCheck(String(API_VERSION))).toBeNull();
    expect(apiVersionCheck("999")).toBeNull();
  });

  it("una versione sotto il minimo o non valida riceve 426", async () => {
    for (const header of ["0", "-1", "x", "1.5", ""]) {
      const response = apiVersionCheck(header);
      expect(response?.status, header).toBe(426);
    }
    expect(await apiVersionCheck("0")?.json()).toMatchObject({ min_api: 1 });
  });

  it("i limiti esposti sono quelli applicati", () => {
    expect(limits()).toMatchObject({ api: API_VERSION, max_changes: 500, max_pull_limit: 1000, default_pull_limit: 500 });
  });
});
